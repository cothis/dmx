# Review: dmx SSD/log hardening (v0.4.0 → patch)

**Verdict: Request changes.** Two product defects block the release (F1, F2). The rest are Low product issues and test defects that don't block.

I worked read-only from the snapshot and the diff and ran nothing. F1 depends on what I remember of how moby starts containerd. A one-minute check in the VM is given below to confirm it.

---

## Blocking product defects

### F1. [Medium · product] A collector left behind by containerd keeps the flock, so dockerd can't be restarted
- **Code:** `guest/agent/src/docker.rs:79`, `:93-113`, `:128-132`; `guest/agent/src/rotating_log.rs:22-25`
- **Cause:** After `exec 1>&2` (`guest/docker:12`), dockerd's stderr is the agent's pipe. dockerd starts containerd with `cmd.Stdout/Stderr = os.Stdout/os.Stderr` and `Setsid`. containerd therefore holds the pipe's write end in a separate session. The collector thread owns the `RotatingLog`, including `_lock`, until it reads EOF.
- **Failing sequence:**
  1. dockerd starts normally and launches containerd.
  2. dockerd dies, either by crashing or on the timeout path at `:130`, where `kill(-pgid, SIGKILL)` doesn't reach containerd because it is in another session.
  3. containerd survives (moby's "containerd is still running" reuse path expects this) and keeps the pipe open, so the collector never sees EOF and keeps the flock.
  4. The next `docker_start` calls `RotatingLog::new`, `flock(LOCK_NB)` returns EWOULDBLOCK, and `docker_start` fails with `os error 11`. Docker stays unusable until `dmx stop`.
- **Comparison with v0.4.0:** v0.4.0 wrote to the file directly, so re-running the script brought dockerd back. The comment at `:129` ("A retry must not leave … collector alive") doesn't hold for this path.
- **Variant:** In the `try_wait` path, `drained.send(())` runs before `log` is dropped, so an immediate retry can briefly hit the same lock.
- **Verify:** start the test VM, run `docker info`, then `kill -9 $(cat /var/run/docker.pid)`, then `docker info` again. Expect `os error 11`. `ls -l /proc/$(pidof containerd)/fd/2` should show `pipe:`.
- **Suggested fix:** Use a single process-wide `RotatingLog` (`static OnceLock<Mutex<RotatingLog>>`) that every collector writes through. A new start then doesn't need to take the flock again, and the old and new collectors are serialised. If the timeout path really must leave nothing running, `cgroup.kill` on `/sys/fs/cgroup/dmx-docker` would also remove containerd, but the shared log is the core fix.

### F2. [Medium · product] A log setup failure stops the daemon (or Docker) from starting, and the error goes nowhere
- **Code:** `Sources/DMXCore/Daemon/Daemon.swift:60-62`, `Sources/DMXCore/RotatingLog.swift:18-40` and `:90-101`; guest equivalent `docker.rs:79`
- **Failing sequence (a):**
  1. The Mac volume is full. `data.img` is sparse and grows, so this is a realistic state.
  2. Time Machine local snapshots still hold the old blocks of `daemon.log`.
  3. After upgrading, the first start trims the oversize v0.4.0 `daemon.log`: `ftruncate(0)` frees nothing, and writing the 1 MiB tail fails with ENOSPC.
  4. `RotatingLog.init` throws, so `Daemon.init` throws.
  5. stderr is already `/dev/null`, either from the new plist (`Launchd.swift:145-146`) or because `detachLegacyLog` already ran. The error is printed nowhere. launchd fails again on every connection, and the log has already been truncated.
- **Failing sequence (b):** If `daemon.log`, `.1` or `.2` is a symlink or has nlink≥2 (for example after a hard-link backup), the daemon permanently refuses to start with `log_invalid` or `log_unwritable`, again with no output anywhere. v0.4.0 started in both cases.
- The code's own principle at `RotatingLog.swift:50`, that a logging failure must not stop the VM, doesn't hold at init.
- **Suggested fix:** Make log setup best-effort.
  - If the write fails after the trim's `ftruncate`, carry on: the file is already within budget.
  - If a file can't be used, keep the link/special-file refusal but start without that sink (drop the output). Report the problem in `dmx status` or `doctor`.
  - Do the same on the guest: if `RotatingLog::new` fails, drain the output and throw it away.

---

## Low product issues (non-blocking)

- **F3. [Low] Agent restart permanently loses dockerd's log.**
  - The agent is built with `panic = "abort"`, and `guest/init:140-147` restarts it when it dies. When that happens, the pipe has no reader. dockerd ignores SIGPIPE, so it keeps running, but every log write gets EPIPE.
  - The new agent sees `answers()==true` and never starts a new collector, so `dockerd.log` stops updating until the VM restarts. This is a regression from v0.4.0. Documenting it as a known limitation is enough.
- **F4. [Low · docs] The meaning of the console log and `.1` files changed.**
  - `console.log` now accumulates across boots and `dockerd.log.1` is a rotation file. `Paths.swift:30` ("rewritten on every boot") and `docs/docker.md:182-183` ("the previous one `dockerd.log.1`") are now out of date.
- **Note:** Rejecting `"log-opts": null` (`DockerEngineConfig.swift:45-47`) is new compared with v0.4.0, where dockerd accepted it. Rare, so no change needed.

---

## Test defects

1. **`RotatingLogTests.swift:16-21` and `rotating_log.rs:113-114`:** the pre-existing files are filled with a single repeated byte (`97` / `'o'`). A bug that kept the head instead of the tail would still pass, so "pre-existing giant logs keep their newest bytes" isn't actually tested. Use a position-dependent pattern.
2. **`RotatingLogTests.swift:38-52`:** `limit 1024` is a multiple of the 8-byte record, so "whole records" only holds by alignment. The implementation does split records at the limit by design. Rename the test, or use a limit that doesn't divide evenly and check concatenation and non-interleaving instead.
3. **`RotatingLogTests.swift:33-35`:** a regression that reopened with O_TRUNC would still pass. Compare the whole content before and after reopening.
4. **No test for drop-and-retry after a write failure**, although this is a stated claim. Suggestion: make the logs directory 0500 so rotation's rename fails, write past the limit and check that nothing grows or crashes. Restore 0700, write again, and check that rotation succeeds.
5. **The Rust test never runs by default.** It only runs through the optional `DMX_RUST_TEST` harness, so it isn't among the 96 passing tests. Nothing tests the flock or the restart after dockerd dies, which is the F1 scenario.
6. **`DockerTests.swift:100` and the `DockerEngineConfig.swift:42` comment:** dockerd rejects `"max-size":"-1"` because go-units refuses negative sizes, so there's no such thing as an "explicit unlimited" setting. The product only passes the value through, but the test and comment describe a config that doesn't work.
7. **`test-storage.py:47-48`:** `daemon.log` never rotates during the test, and the trim works in place on the same inode. The test would therefore pass even without `detachLegacyLog`. Add a check that `lsof -a -p <pid> -d 1,2` shows `/dev/null`, or force a rotation.
8. **`test-storage.py:73` console marker:**
   - `.rstrip(b'\r\n')` already strips CRLF, so ONLCR alone can't explain the failure if it came from this snapshot. Your separate stty/byte-tail check is the right call.
   - When reading the byte tail:
     - If the marker is present but followed by other console output, the culprit is the fragile `endswith` (a test defect).
     - If the marker isn't in `console.log` or `.1`, it's a product loss.
   - The `wait` lambdas (`read_bytes`, `stat`) also hit an uncaught FileNotFoundError if they run mid-rotation.
9. **Weaker existing tests:** `test-daemon.py:586` and `test-pressure.py:99` grep `console.log` content, which can now match an earlier boot.

---

## Checked and found correct

- **Disk budget and fd handling:** fd ownership and close paths in init, append and rotate are correct, with no double close. After a partial write, reopen resyncs `size` with `fstat`. The disk budget arithmetic holds at ≤3×limit, including oversize pre-existing files.
- **Rotation security:** O_NOFOLLOW, the S_IFREG check and nlink==1 are in place. `rename`/`unlink` don't follow links. A FIFO opened with O_NONBLOCK doesn't hang.
- **Locks:** the lock order PL011.lock → RotatingLog.lock has no reverse path, so no deadlock. VirtioConsole writes outside `transport.lock`. `Diagnostics` releases its lock before writing.
- **Legacy launchd:** fd 1 and 2 are detached by inode comparison. Since only `dmx install` rewrites the plist, this is the normal path after an upgrade, and it works.
- **Docker config:** explicit drivers and options are kept, defaults only fill unset keys, and existing containers keep their settings as stored when they were created.
- **Memory and idle cost:**
  - The guest's tail buffer is a fixed 8 KiB, and the drain logic can't panic.
  - On the host, idle costs no timers or threads, and there is one blocked reader thread in the guest.

**Release conditions:** fix F1 and F2, then add tests for test defects 1, 4, 5 and 7 (plus the F1 scenario), and finish analysing the console marker evidence.
