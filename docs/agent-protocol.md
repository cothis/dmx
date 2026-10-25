# dmx-agent protocol (version 1)

`dmx-agent` runs in the guest, started and restarted by `/init`. The host reaches it through the
VM's virtio socket device: `VZVirtioSocketDevice.connect(toPort: 1024)`. Host code lives in
`Sources/DMXCore/Agent.swift`, guest code in `guest/agent`.

## Frames

Every frame is:

```
u32 length (big endian, counts kind + payload) | u8 kind | payload
```

| Kind | Payload |
|---|---|
| 0 | JSON message (UTF-8) |
| 1 | stdin bytes, host to guest. An empty payload closes stdin. |
| 2 | stdout bytes, guest to host |
| 3 | stderr bytes, guest to host |

Frames larger than 16 MiB are a protocol error. Output is sent in chunks of at most 32 KiB.

## Requests

A connection carries requests answered in order:

```json
{"id": 1, "method": "stats", "params": {}}
{"id": 1, "ok": true, "result": {...}}
{"id": 1, "ok": false, "error": {"code": "bad_request", "message": "..."}}
```

Error codes: `bad_request`, `unknown_method`, `exec_failed`, `connect_failed`, `docker_failed`, `io_error`, `internal`.
The host turns them into `DMXError` codes prefixed with `agent_`.

| Method | Params | Result |
|---|---|---|
| `hello` | none | `agent`, `version`, `protocol` (1), `kernel` |
| `stats` | none | `memory` (bytes from /proc/meminfo: `total`, `free`, `available`, `buffers`, `cached`, `shmem`, `swap_total`, `swap_free`, `balloon`), `uptime_s`, `load` [3], `cgroups` [{`path`, `memory_current`}] |
| `drop_caches` | `level` 1, 2 or 3 (default 3) | `available_before`, `available_after` |
| `reclaim` | `bytes`, `swappiness` (0 to 200; 0 takes only file cache, absent uses `vm.swappiness`) | `free_before`, `free_after` (MemFree), `complete` (false when the kernel found less than `bytes`). Writes the root cgroup's `memory.reclaim`. |
| `swap_on` | none | `size` (bytes), `enabled_now` (false if it was on). zram0 with lz4, a quarter of MemTotal, priority 100; sets `vm.swappiness` 100 and `vm.page-cluster` 0. |
| `reporting_order` | `order`: smallest free block that free page reporting hands to the host, in guest pages (`page_size << order` bytes). Busy reporting is 512 KB (order 7 for 4K, 5 for 16K); idle reporting covers a host page (order 2 for 4K guests on a 16K Mac, 0 for 16K guests). | `previous`. Writes `/sys/module/page_reporting/parameters/page_reporting_order`; the kernel reports about 2 s after the next free, and rejects orders above its largest. |
| `shrink_slabs` | none | `free_before`, `free_after` (MemFree). Writes `1` to every `/sys/kernel/slab/<cache>/shrink`: per-CPU slabs are flushed and empty slabs freed; no object is evicted. |
| `time_sync` | `unix_ns` (host clock) | `offset_ns`: guest minus host before the change |
| `shutdown` | none | `{}`, then the guest stops dockerd if it runs (SIGTERM, at most 7 s, so containers stop cleanly), syncs, freezes the data disk at `/var/lib` (its journal is left clean) and powers off |
| `docker_start` | `config` (optional: dockerd's daemon.json, written to `/run/dmx/daemon.json` mode 0600 before dockerd starts; without it the script writes dmx's keys alone), `ca_certificates` (optional PEM text, written to `/run/dmx/host-ca.pem` and added to dockerd's CA bundle) | `started` (false if dockerd answered already), `ms`, `running` (true). Runs `/sbin/dmx-docker` (`guest/docker`) unless `/var/run/docker.sock` answers and returns once it does (at most 120 s); concurrent calls wait for one start. See [docker.md](docker.md). |
| `docker_autostart` | as `docker_start` | as `docker_start`, plus `restartable` (the containers that would come back), but dockerd is started only if a container would come back by its restart policy and was not stopped with `docker stop`; otherwise `started` and `running` are false. The host calls it after every boot. See [docker.md](docker.md#restart-policies). |
| `exec` | see below | `pid`, then the connection becomes the process's streams |
| `connect` | see below | `{}`, then the connection becomes a TCP or Unix socket stream's raw bytes |

## exec

Params: `argv` (required), `env` (list of `KEY=VALUE` added to the agent's environment), `cwd`,
`tty` (default false), `stdin` (without a tty: whether the host will send stdin; otherwise
/dev/null), `rows` and `cols` (tty size, default 24x80).

After the `ok` reply the connection belongs to the process:

- Guest to host: stdout and stderr frames (with a tty there is only stdout), then
  `{"id": N, "event": "exit", "code": 0, "signal": null}`, then the agent closes the connection.
- Host to guest: stdin frames, and JSON control messages
  `{"method": "resize", "params": {"rows": 50, "cols": 120}}` and
  `{"method": "signal", "params": {"signal": 15}}`.

The process starts with default signal dispositions and an empty signal mask (the agent itself
inherits SIGINT and SIGQUIT ignored from `/init`). With a tty the process runs in a new session with the pty as its controlling terminal; without
one it runs in its own process group. If the host closes the connection before the process
exits, the agent kills the process group. After the process exits, output still arriving is
forwarded until the streams have been quiet for 500 ms, so a background child holding a stream
open does not delay `exit` forever. Output still waiting for a host that reads slowly is not
quiet: it goes out before `exit`.

Because an exec takes over its connection, the host opens one connection for control calls and
a new one per exec (`AgentClient` does this). A control call unanswered after 60 s fails with
`agent_timeout`; the host then shuts that connection down (ending the calls queued on it) and
opens another, so an agent thread that died or hung mid-call (a guest kernel oops did this once)
does not leave every later call waiting. `dmx status` waits at most 2 s for guest memory.

## connect

Params: `port` and `host` (an IP address, default `127.0.0.1`), or `path`; `udp` (default false)
makes `port` a UDP port. The agent opens a TCP
connection to `host:port` in the guest, which is how the daemon forwards a host port
([daemon protocol](daemon-protocol.md#port-forwarding)), or connects to the Unix socket at `path`,
which is how it forwards the Docker socket. Giving both or neither is `bad_request`. A refused or unreachable port answers
`connect_failed`; a target that drops the connection attempt fails after 5 s.

After the `ok` reply there are no more frames: the vsock connection carries the TCP stream's bytes
as they are, both ways. End of stream on one side becomes a half close on the other (a host that
shuts down its sending side still reads the reply); an error on either side closes both. Each
forwarded connection costs the agent two threads and two descriptors; the agent raises its
descriptor limit to the hard limit (4096) at start, which processes it starts inherit.

With `udp`, the agent binds a UDP socket of its own, connects it to `host:port`, and the stream
carries datagrams both ways, each framed as a big-endian u16 length and the bytes (at most 65507).
Datagrams the host sends go out from that socket; datagrams the target sends back come framed to
the host. One stream serves one host peer; it ends when the host closes it (after a quiet minute,
for a forwarded UDP port). A datagram the target refuses is dropped.

## Host services

The other direction: the guest connects to the host. The agent listens on Unix sockets under
`/run/host-services` (mode 0666, as in Docker Desktop's VM) and opens a vsock stream to the host
(CID 2) for each connection; the stream then carries the socket's bytes as `connect` does. The
host listens on these vsock ports (`HostServices.swift`, `VirtioVsock.listen`):

| Guest socket | Host vsock port | On the host |
|---|---|---|
| `/run/host-services/ssh-auth.sock` | 1025 | The Mac's SSH agent: the daemon's `SSH_AUTH_SOCK`, else launchd's (`launchctl getenv`), else the socket of macOS's own `com.openssh.ssh-agent` job |

A connection the host cannot serve (no agent) ends at once; the guest client reads end of stream.

## Versioning

`hello.protocol` changes only on incompatible changes. The host refuses a mismatched agent with
`agent_version` and the hint to rebuild the guest. New methods and new optional fields do not
change the version.
