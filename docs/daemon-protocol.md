# dmx daemon control protocol

`dmx daemon` owns the VM and listens on a Unix socket, `~/.dmx/dmx.sock` (mode 0600), and on the
Docker API socket `~/.dmx/docker.sock` ([docker.md](docker.md)). The CLI
talks to it, and so does `dmx mcp` (one connection per tool call, see [mcp.md](mcp.md)). The wire format is the [agent protocol](agent-protocol.md)'s:
frames of a 4-byte big-endian length, one kind byte (0 JSON, 1 stdin, 2 stdout, 3 stderr) and
the payload. JSON keys are snake_case.

## Who starts the daemon

- After `dmx install`, launchd holds both sockets (label `io.github.cothis.dmx`, plist in
  `~/Library/LaunchAgents`, `Sockets` `Listeners` and `Docker`) and starts `dmx daemon` on the
  first connection to either.
- Otherwise `dmx start`, `dmx exec` and `dmx shell` start it themselves, detached, when nothing
  answers on the socket. `dmx status` and `dmx stop` never start one.

One daemon runs per `DMX_HOME` (it holds a lock on `daemon.lock`). It logs to
`~/.dmx/logs/daemon.log`; the guest console goes to `~/.dmx/logs/console.log`.

## Lifecycle

- The VM boots when a client first needs it (`start`, `exec`) and stops after `idle_timeout`
  (default 5 minutes, `dmx config set idle_timeout 10m`) with no connection that used it.
  Connections that only ask for `status` do not keep it running.
- Once the VM is stopped and no client has been connected for 10 s, the daemon exits. (launchd
  delays relaunching a job that ran less than 10 s.) The next connection starts a new one.
  While any port is forwarded it stays (4 MB with the VM stopped) to listen on the ports; see
  [Port forwarding](#port-forwarding). A daemon the CLI started (not launchd) also stays once a
  Docker client used it, to keep answering on docker.sock, until `dmx stop`.
- A running Docker container counts as using the VM, and so does an open connection on
  docker.sock.
- SIGTERM or SIGINT (also `dmx uninstall`, which unloads the launchd job) powers the guest off
  through the agent, with a 10 s limit, and exits.

## Requests

```json
{"id": 1, "method": "status", "params": {}}
{"id": 1, "ok": true, "result": {...}}
{"id": 1, "ok": false, "error": {"code": "agent_unreachable", "message": "...", "hint": "..."}}
```

Error codes are the CLI's (`DMXError`), passed through unchanged, with a hint naming the next
command to run.

| Method | Params | Result |
|---|---|---|
| `hello` | none | `version`, `protocol` (1), `pid` |
| `status` | none | see below |
| `start` | none | status, once the guest agent answers |
| `stop` | none | status, once the VM is off |
| `quit` | none | `{}`, then the daemon powers the VM off and exits (used by `dmx install`) |
| `exec` | the agent's `exec` params | `pid`, then the connection carries the process's streams |
| `simulate_pressure` | `level`: `normal`, `warning`, `critical`, or null for the host's real level again | status. For tests: the memory controller acts as if macOS reported that level. Does not count as using the VM. |
| `port_add` | `host_port`, `guest_port`, `host_address` (default `127.0.0.1`) | the forward, see below |
| `port_rm` | `host_port`, `host_address` (default: every address) | `forwards`: those removed |
| `port_ls` | none | `forwards` |

`status` fields: `state` (`stopped`, `starting`, `running`, `stopping`), `pid` (the daemon, which
is also the process guest memory is charged to), `version`, `launchd`, `uptime_s`, `cpus`,
`max_memory`, `guest_used_mb`, `host_footprint_mb` and `host_peak_footprint_mb` (the daemon's
`ri_phys_footprint`, guest RAM included), `clients` (other connections), `execs`, `containers`
(running Docker containers; null until a Docker client used the VM since it booted),
`docker_socket`, `idle_timeout_s`, `idle_stop_in_s` (when nothing uses
the VM), `socket`, `console_log`, `memory` (below), and `disk` (the data disk `~/.dmx/data.img`:
`path`, `size_mb` as the guest sees it, `allocated_mb` it takes on the host; null before the first
boot). `dmx status` prints `state: not_running` when no daemon answers.

`memory` fields: `host_pressure` (`normal`, `warning`, `critical`: macOS's level, as the controller
sees it), `pressure_simulated`, `balloon_mb` and `balloon_target_mb` (what the guest gave back on
request, and what was asked), `guest_cache_mb` (clean page cache), `guest_swap_mb` (zram in use),
`reported_mb` (returned by free page reporting since boot), `trims`, and `last_trim` (`reason`,
`seconds_ago`, `freed_mb`, `ms`). VM fields are null while the VM is stopped.

## Memory controller

Free page reporting returns what the guest frees by itself, within about 2 s. The daemon also:

- trims the guest's clean page cache to 16 MB (`memory.reclaim`, file pages only) once the VM has
  been idle for 30 s: no exec started or ended, no forwarded connection opened or closed, and
  under 5 % of one CPU all along;
- at the same moment, sweeps once: free page reporting goes from 512 KB blocks down to single
  16 KB pages (agent `reporting_order`) and the guest's slab caches free their empty slabs
  (`shrink_slabs`). Bursts of connections, processes or small files leave tens of MB free in
  blocks under 512 KB, which reporting at 512 KB never hands back. When the guest is used again,
  reporting goes back to 512 KB blocks. `dmx status` counts these in `memory.sweeps`;
- on macOS memory pressure (`DispatchSource.makeMemoryPressureSource`, and the level read with
  `kern.memorystatus_vm_pressure_level`): at warning, trims at once and after 5 s of idle; at
  critical, also pushes cold anonymous and tmpfs pages into zram and inflates the balloon to cap the
  guest at what it uses plus 256 MB, following its use. After critical the cap loosens to 1 GB at
  warning; at normal the balloon deflates;
- turns zram swap on (agent `swap_on`) the first time the guest is squeezed or uses more than half
  its ceiling, not at boot (it costs ~3.5 MB of guest memory).

Each action is logged to the daemon log with a `memory:` prefix.

## exec

The request and everything after it are the agent's exec ([agent protocol](agent-protocol.md#exec)):
after the `ok` reply the daemon relays bytes between the client and the agent's connection
without parsing them. Stdin and control frames (`resize`, `signal`) go to the process; stdout,
stderr and the final `exit` event come back. If the client goes away, the daemon closes the
agent connection and the agent kills the process group. Each exec needs its own connection.

`dmx exec` passes SIGINT, SIGTERM and SIGHUP on to the process as `signal` messages and exits
with its status (128 + signal if it was killed); `-t` gives it a pty sized like the terminal.

## Port forwarding

`dmx port add [HOST_IP:]HOST_PORT[:GUEST_PORT]` (`port_add`) makes the daemon listen on a host TCP
port, by default on 127.0.0.1 only; `0.0.0.0` lets other machines in. Each accepted connection
gets its own vsock stream to the agent, whose [`connect`](agent-protocol.md#connect) opens a TCP
connection to the guest port on the guest's loopback, then the daemon copies bytes both ways. No
privileged helper is involved, and the guest needs no network device. TCP and IPv4 only.

- Forwards are kept in `~/.dmx/ports.json` until `dmx port rm`. Every daemon listens on them
  when it starts: launchd starts one on the next connection to the control socket (`dmx port ls`
  is enough), and so does any CLI command that starts a daemon.
- The daemon listens with the VM stopped, and the first connection boots it (about 0.2 s before
  the guest answers). A connection that is open counts as using the VM, like an exec, so the VM
  stops for being idle `idle_timeout` after the last forwarded connection closed. While any
  forward exists the daemon does not exit for being idle; `dmx stop` stops only the VM.
- Bytes are copied with at most one 64 KB buffer per direction, held only while bytes are in
  flight, and a side is read only once the other has taken what was read before: a slow reader
  holds the sender back through TCP and vsock flow control. End of stream on one side becomes a
  half close on the other; an error on either closes both.
- If the guest port does not answer, the host connection is closed (or reset if the client had
  sent data) and the daemon log says why.
- Removing a forward stops listening; connections already open stay until either end closes them.

Ports that running containers publish are forwarded too, while they run, and are not saved; see
[docker.md](docker.md#published-ports).

A forward in `port_ls` or `port_add`: `source` (`docker` for a container's port, absent otherwise), `host_address`, `host_port`, `guest_port`, `listening`
(false with `error` when the port could not be listened on, for example taken after a restart),
`connections` (open now) and `total_connections` (since the daemon started).

Errors: `bad_port_spec`, `port_forwarded` (that host port is forwarded already), `port_in_use`
(another program listens there), `port_unavailable` (the address cannot be bound),
`port_not_forwarded` (for `port_rm`).

In code, `DaemonClient.addPort(_:)`, `removePort(hostPort:hostAddress:)` and `ports()` make these
calls; inside the daemon, `PortForwards.add(_:)` and `remove(hostPort:hostAddress:)` do the work.
