# Fix review and perspective audit (2026-11-20, second audit round)

After the [full audit](2026-11-20-full-audit.md) (609c671) the maintainer asked for one more
pass, done two ways at once:

- **Fix review.** Opus 5.5 and Codex `gpt-6.2-sol` reviewed `25ff416..609c671`, the full
  audit's fixes, against the code around them. Codex reviews diffs without refusing (it
  refused the whole repository three times before). Its report:
  [codex-gpt-6.2-sol-round4.md](2026-11-20-unreleased/codex-gpt-6.2-sol-round4.md).
- **Perspective audit.** Three Opus 5.5 agents read the whole code base, each for one concern
  rather than one area. One took resource lifetimes (descriptors, threads, tasks, buffers and
  files that outlive their use). One took concurrency (interleavings in the host, across
  processes sharing a DMX_HOME, and in the guest agent). The third checked docs against
  behaviour: every doc and help text against the code, and AGENTS.md's rules. Each split its
  work over sub-agents and re-traced the main findings itself.

Opus found no release blockers in any of the four. Codex marked three blockers: the FUSE
`O_TRUNC` ordering, a vsock double drop, and the sandbox fence race. The first two are fixed;
the third is recorded below. Several fixes from the full audit had missed a path. The worst was
`dmx sandbox exec`: a cancelled exec (Ctrl-C, MCP cancel, MCP EOF) never killed its command,
because the kill ran in the cancelled task and `DaemonClient.connect` checks cancellation first.

## Fixed

| Finding | From | Fix |
|---|---|---|
| A share open refused for the handle budget (ENFILE) had already opened the host file with `O_TRUNC`/`O_CREAT`, so a failed open emptied or created the file | Codex | The handle is reserved before any open; a refused open touches nothing (unit test `refusedOpenLeavesTheFileAlone`) |
| A vsock stream reset for overrunning its credit could be dropped twice (the RST's delivery drops it first), resuming a Dispatch source twice and stopping the daemon | Codex | `drop` runs once per stream |
| A cancelled sandbox exec left its command running; the CLI still exited 130 — *released* | Opus ×3 | The kill runs in its own task and is awaited; sandboxtest `exec_cancel_kills` (Ctrl-C on the CLI) fails on v0.4.8 and passes now |
| A sandbox whose fence check threw, or whose stop after a failed fence failed, kept running without its rules | Codex, Opus | A failed check stops it; the stop's status is checked and a failure is reported |
| `dmx sandbox exec --max-output-bytes -1` trapped (CLI only) | docs audit | 0…1 MiB checked as in MCP (`bad_argument`) |
| MCP's 10 s wait at EOF was not bounded: a task group waits for all its children | Codex, Opus | A race on a continuation; the process leaves after 10 s whatever is still running |
| A cancelled `dmx_import` kept its `docker` pipes running up to two hours, orphaned when `dmx mcp` exited; bench's `docker` runs likewise | resources | Cancellation terminates both processes |
| Tool download resume: a mirror that ignores `Range` and sends 200 failed the install, because the old offset still counted against the size bound | Codex, Opus | The bound counts from 0 after a 200 |
| The tools install lock ignored a failure to open or lock it and could not be cancelled while waiting | Codex, Opus | An open failure is an error; the lock is polled, so a cancel ends the wait |
| `guest fetch --force` held the guest lock exclusively for the whole download, blocking boots that had a usable guest; `dmx boot --selftest` and `dmx boot` took no lock | Codex | Fetches serialize on their own lock; the guest lock is exclusive only around the swap; every boot holds it shared until the VM has its files open |
| `config set`/`unset`, the hint for a bad value in config.json, failed on that same value; `try? Config.load` callers dropped the whole file | Codex, Opus | Loading only decodes; a value is checked when the VM is built from it; set and unset write under a lock, so a CLI and an MCP call at once lose nothing |
| `dmx boot --json` let non-DMXError failures out without the envelope; a DMXError without a hint went out without one (78 such sites) | Codex, docs audit | Every failure leaves through the report with a hint (`dmx doctor`'s when it has none); MCP does the same; `internal` and `internal_error` are one code now |
| The update's `.sha256` was read whole into memory before any check | Codex | Read with a 4 KB bound |
| The crash-streak stop came one crash late; a failed recovery boot counted as a crash | Codex, docs audit | Stops at ten; boot failures are retried five times on their own count |
| TCP forwards: connections accepted in one wake all passed the limit check with the old count; no limit across forwards. UDP: dual-stack forwards got two limits; datagrams waiting for a boot could reach about 2 GB | Codex, resources | Counted at accept; 4096 TCP connections and 2048 UDP peers across forwards; 1 MiB of waiting datagrams per relay |
| A standalone `dmx daemon` beside an installed launchd job unlinked launchd's sockets | concurrency | Refused (`daemon_running`) when launchd serves this DMX_HOME |
| docker.sock and the control socket had no connection limit; the control socket's accept spun on EMFILE and its descriptors lacked CLOEXEC | resources | 1024 and 256 connections; accept pauses on EMFILE; CLOEXEC |
| Local names: a connection had no limit once its head was read; a late-failing TLS backend could drop its replacement from the table, leaking its listener; hints named `dmx names status`, which does not exist | resources, docs audit | 1024 connections; only the failing backend is removed; hints name `dmx names ls` |
| NAT TCP flows to a far end that vanished (sleep, Wi-Fi or VPN change) were never reaped | resources | Keepalive on the Mac's sockets, as forwards have |
| `ByteQueue` kept up to 1 MB of capacity once empty, per connection | resources | Keeps at most 64 KB |
| Download work directories named by pid were never removed after a kill | resources | Stale ones are removed at the next download or update |
| Guarded-port files outlived a crashed daemon and matched a reused pid | resources | Named by pid and process start time |
| The sandbox reaper's Docker calls had no deadline | resources | 60 s |
| An interrupted `dmx bench` left its 2 GiB tmpfs container | resources | Containers carry a label; a dead run's are removed at the next start |
| The names CA's key and certificate could mismatch when two setups ran at once | concurrency | Made under a lock |
| MCP `mounts` without `path` defaulted to the unexpanded `~/x` and was refused | docs audit | Defaults to the expanded host path |
| Guest agent: a failed thread spawn aborted the whole agent (`panic = "abort"`), cutting every exec and forward and orphaning their processes; `host_services` spun on an accept error | concurrency | `Builder::spawn`; a failure ends that one request and kills its process group; accept errors back off 100 ms |
| Docs: README uninstall steps, MCP tool list, sandbox example (wrote to a read-only mount), share wording; `menu_release` described a side effect it lacks; `menu_state`, `menu_docker(_read)`, `hello.menu_control`, `exec.stdin_window`, `status.disk_error`, agent `trim_disk` and the idle disk trim undocumented; shutdown limit (10 s documented, about 23 s at most); retry counts; the clock deadline; sandbox error codes; `config --help` without `shares`; names without the sandbox exclusion; dockerd's version; release.py's version file | docs audit | Corrected |

## Not changed

Each needs a narrow interleaving or a misbehaving client, and none loses data:

- **Sandbox fence vs a restart** (Codex blocker). The marker is checked, then Docker restarts
  the same container ID, then the exec runs in the new instance before its rules are set. Only
  `docker restart` on a sandbox from outside dmx opens this window. A sandbox never restarts by
  itself (no restart policy). Closing it needs the exec to check the marker atomically inside
  the container, which the next sandbox change can do.
- Two execs at once on an unfenced sandbox run the fence twice. The second flush drops the
  ESTABLISHED rule for a moment; the policy stays DROP.
- Two rollbacks of one sandbox at once can leave the other's checkpoint.
- Guest agent: `openpty` sets CLOEXEC after opening, so a fork in that window inherits the pty.
  A `shutdown` during a Docker start finds no pidfile and powers off without a clean container
  stop (`sync` and the freeze keep ext4 consistent). `sync` follows the up-to-7 s Docker stop,
  so a large writeback can meet the host's deadline (a journal replay at the next boot).
- A relative clock adjust that reaches a slow guest after the host gave up (2 s) can be applied
  after the next sync's correction; the following sync corrects it.
- A listing sent before a start answered can close that container's ports for one listing.
- Another DMX_HOME's guarded ports are cached for 1 s.
- `~/.docker/config.json` vs a `docker login` at the same moment; the `.atomic` write exists
  briefly with umask mode before 0600.
- A reused MCP request id orphans the first call (a client breaking JSON-RPC).
- `VirtioBlock` and `VirtioMMIO` reference each other: a few KB per boot without a device reset.
- `docker.rs` still uses `std::thread::spawn` for dockerd's collectors (one per start).
- `AgentClient.call` leaves a sleeping 60 s timer task per call (bounded by calls in flight).
- A standalone daemon keeps its listener while it powers off (up to about 30 s); a client that
  connects then waits out its 15 s `hello`.
- The install window between quitting a standalone daemon and `launchctl bootstrap`.

## Checks after the fixes (this Mac, rebuilt guest in a separate DMX_HOME)

Unit 174 (the new FUSE test); agent tests 8/8 in the VM. Real VM, all passing: namestest 37/37
(HTTPS 100 MB in 0.45 s, so the 64 KB `ByteQueue` cap costs nothing), crashtest 40/40,
daemontest 63/63, sandboxtest 45/45 (44/45 with v0.4.8: the new cancel check), mcptest 39/39, dockertest 81/81, soaktest 28/28 (footprint
214 → 255 MB after 300 runs and 50 Compose cycles; daemon fds 19 → 19, threads 21 → 21),
launchdtest 10/10, importtest 29/29 (from the installed v0.4.8 dmx), selftest 23/23 twice at
96 MB.
