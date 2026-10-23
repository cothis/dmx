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

Error codes: `bad_request`, `unknown_method`, `exec_failed`, `io_error`, `internal`.
The host turns them into `DMXError` codes prefixed with `agent_`.

| Method | Params | Result |
|---|---|---|
| `hello` | none | `agent`, `version`, `protocol` (1), `kernel` |
| `stats` | none | `memory` (bytes from /proc/meminfo: `total`, `free`, `available`, `buffers`, `cached`, `shmem`, `swap_total`, `swap_free`, `balloon`), `uptime_s`, `load` [3], `cgroups` [{`path`, `memory_current`}] |
| `drop_caches` | `level` 1, 2 or 3 (default 3) | `available_before`, `available_after` |
| `time_sync` | `unix_ns` (host clock) | `offset_ns`: guest minus host before the change |
| `shutdown` | none | `{}`, then the guest syncs and powers off |
| `exec` | see below | `pid`, then the connection becomes the process's streams |

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

With a tty the process runs in a new session with the pty as its controlling terminal; without
one it runs in its own process group. If the host closes the connection before the process
exits, the agent kills the process group. After the process exits, output still arriving is
forwarded until the streams have been quiet for 500 ms, so a background child holding a stream
open does not delay `exit` forever.

Because an exec takes over its connection, the host opens one connection for control calls and
a new one per exec (`AgentClient` does this).

## Versioning

`hello.protocol` changes only on incompatible changes. The host refuses a mismatched agent with
`agent_version` and the hint to rebuild the guest. New methods and new optional fields do not
change the version.
