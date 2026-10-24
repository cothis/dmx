# dmx daemon control protocol

`dmx daemon` owns the VM and listens on a Unix socket, `~/.dmx/dmx.sock` (mode 0600). The CLI
talks to it; `dmx mcp` will too. The wire format is the [agent protocol](agent-protocol.md)'s:
frames of a 4-byte big-endian length, one kind byte (0 JSON, 1 stdin, 2 stdout, 3 stderr) and
the payload. JSON keys are snake_case.

## Who starts the daemon

- After `dmx install`, launchd holds the socket (label `io.github.cothis.dmx`, plist in
  `~/Library/LaunchAgents`) and starts `dmx daemon` on the first connection.
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

`status` fields: `state` (`stopped`, `starting`, `running`, `stopping`), `pid` (the daemon, which
is also the process guest memory is charged to), `version`, `launchd`, `uptime_s`, `cpus`,
`max_memory`, `guest_used_mb`, `host_footprint_mb` and `host_peak_footprint_mb` (the daemon's
`ri_phys_footprint`, guest RAM included), `clients` (other connections), `execs`, `containers`
(null until Docker runs in the guest), `idle_timeout_s`, `idle_stop_in_s` (when nothing uses
the VM), `socket`, `console_log`. `dmx status` prints `state: not_running` when no daemon
answers.

## exec

The request and everything after it are the agent's exec ([agent protocol](agent-protocol.md#exec)):
after the `ok` reply the daemon relays bytes between the client and the agent's connection
without parsing them. Stdin and control frames (`resize`, `signal`) go to the process; stdout,
stderr and the final `exit` event come back. If the client goes away, the daemon closes the
agent connection and the agent kills the process group. Each exec needs its own connection.

`dmx exec` passes SIGINT, SIGTERM and SIGHUP on to the process as `signal` messages and exits
with its status (128 + signal if it was killed); `-t` gives it a pty sized like the terminal.
