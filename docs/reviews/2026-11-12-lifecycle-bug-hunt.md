# Bug hunt: VM and process lifecycle (2026-11-12)

Read-only hunt at `9852647` (v0.4.7). **Original review:** this file was the work list for
the fixing session. The dated repair record below supersedes its original status.
At review time nothing was built or run and no finding was reproduced; each one was derived from
the code and its cited lines were read a second time before it was written down. "Confirmed" below means
the mechanism is in the code as cited, not that the failure was observed. Follow the usual rule when
fixing: reproduce or log the suspected state first, then fix, then show the check fails on the old build.

Scope: `HV/Machine`, `HV/VCPU`, balloon, virtio-mem, plug policy, `Daemon/*`, launchd, memory
controller, guest init/agent, vsock/net/fs/blk devices, port and Docker forwarding. Not covered:
`SelfUpdate`, `GuestStore`, `Sandbox/*`, `MCP/*` beyond `CappedExec`, the menu app.

Suggested order: L1, G1, G4, G3, G2, G5, then the rest.

## Repair record (2026-11-12)

- [x] **L1:** terminal device queue barriers before destroying the VM, weak Machine callbacks,
  an alive fence under the mapping lock, and a synchronized balloon stats handler.
- [x] **L2:** partial initialization destroys the HV VM and RAM mapping; start failures halt and
  join vCPUs and finish teardown before returning an error.
- [x] **L4:** reject cancelled or detached agent completions throughout tick, trim and sweep.
- [x] **G10:** initialize the immutable share root wrapper before workers can see it.
- [ ] **Remaining 13:** G1, G4, G3, G2, G5, G6, L3, G7, G8, G9, L5, G11, L6.

Evidence: the net barrier regression fails on the original code; four independently removed
code repairs fail their entitled Hypervisor tests (stale release, failed init, failed start,
late swap completion). All four tests pass restored. The stale release probe makes a real
successor fail to boot without the alive fence; natural overlap frequency is not measured.
Selftest 23/23, unit tests 120, daemon 63/63, and four same-process 2 GiB free/stop/start cycles
pass. Selftest footprint: 98 -> 97 MiB, a single sample each, not evidence of a memory saving.
Model: 10 reachable states in the repaired bounded safety model; two independent defense
mutations, old behavior and a reachability sanity invariant fail as required.

[Measurements](../measurements/2026-11-12-lifecycle.json),
[reproduction and rerun commands](../../formal/vm-device-lifetime/README.md).
The detailed sections below preserve the original findings, line numbers and proposed checks.

| ID | What | Severity | Confidence |
|---|---|---|---|
| L1 | Device work outlives the VM and calls process-wide Hypervisor APIs | guest memory corruption / daemon crash | confirmed, window unmeasured |
| G1 | exec: a child that does not read stdin blocks control frames and the hang-up kill | hang, leaked guest process | confirmed |
| G4 | `shutdown` queues behind a control call in flight; plug is pulled first | unclean power-off | confirmed |
| G3 | UDP forward blocks its queue; `queue.sync` from the MainActor then deadlocks stop | daemon hang | confirmed chain |
| G2 | A hung host file-system call in a share holds a vCPU and makes stop hang forever | hang | plausible |
| G5 | Unpack markers written before the data is durable | Docker/x86 broken after a hard stop | plausible |
| G6 | Host disk full becomes guest EIO | guest data loss | plausible |
| L2 | `Machine.init` leaks the process's one VM when it throws after `hv_vm_create` | no VM until daemon restart | confirmed |
| L3 | Stop or SIGTERM during boot waits for the whole boot | launchd SIGKILL mid first boot | confirmed |
| G7 | One failed container listing leaves counts and forwards stale | VM never idles / port not forwarded | plausible |
| G8 | NAT flows and forwarded sockets are never reaped | leak, VM pinned awake | plausible |
| G9 | exec control frames act on a reaped pid / closed pty fd | wrong process signalled (rare) | confirmed |
| L4 | A memory-controller tick in flight keeps acting after `detach()` | stale state, stray interrupt | confirmed, low |
| L5 | The CLI spawns the daemon once; losing the lock race costs 15 s and an error | wrong result (rare) | confirmed, low |
| G10 | `FUSEServer.rootDir` is a `lazy var` first touched from several threads | data race | confirmed |
| G11 | Docker socket accept loop spins on `EMFILE` | CPU spin | confirmed |
| L6 | `hv_vcpus_exit` before the vCPU is in `hv_vcpu_run`: latch assumed, not checked | possible stop hang | needs a check |

---

## L1. Device work outlives the VM and calls process-wide Hypervisor APIs

**Where**
- `Sources/DMXCore/HV/Machine.swift:266-288` (`stop`): halts vCPUs, `memoryPlugPolicy.stop()`,
  `vsock.closeAll()`, `net.stop()`, then after the vCPU threads end: `fs.stop()`, `destroyVM()`,
  `disk.close()`, `stopped = result`.
- `VirtioBalloon.swift:118-120`, `VirtioMem.swift:101-103`: `notify` does `queue.async { drain }`. Neither
  device has a stop; nothing waits for these queues.
- `VirtioNet.swift:105-111`, `VirtioVsock.swift:123-127`: stop is `queue.async`, not waited for.
- `Machine.swift:204-216` (`release`): `hv_vm_unmap` → `madvise` → `hv_vm_map`, with no check that this
  machine's VM still exists. `HostMappings.exclusive` (`HostMappings.swift:60-64`) does not look at `stopped`.
- `Machine.swift:155-166` (`setSPI`): `hv_gic_set_spi`, same.
- `Machine.swift:127,130,146`: the closures are `[unowned self]`. `Machine.swift:173`: `deinit` unmaps guest RAM.
- `Daemon.swift:271-285,487-511`: the same daemon process boots the next VM as soon as `powerOff` returns
  (`running()` waits on `stopping`, then calls `boot()`).

**Why it breaks.** `hv_vm_map`, `hv_vm_unmap` and `hv_gic_set_spi` have no VM handle: they act on
whatever VM the process holds now. Block and virtio-fs are quiesced (`close()` barrier, `inflight.wait()`);
balloon, virtio-mem, net and vsock are not.

**Sequence**
1. The guest frees memory (a container exits); 2 s later free page reports arrive, or virtio-mem unplugs
   a 128 MB block. A balloon `drain` holds up to 32 chains, each buffer one `release` (a few ms under load).
2. `dmx stop` or idle stop lands now; or the guest is stopped hard by the 10 s deadline. vCPU threads end,
   `destroyVM()` runs, `stopped` is set. The balloon queue still has drains queued or half done.
3. A waiting `dmx start`, exec or Docker request boots the next `Machine` in the same process:
   `hv_vm_create`, `hv_vm_map` of the new RAM.
4. The old drain goes on: `hv_vm_unmap(start, size)` removes that range from the **new** VM, `madvise`
   touches the old RAM, `hv_vm_map(oldHost, start, size)` maps the **old** machine's pages into the new guest.
5. The new guest and its devices now disagree about that range (devices use the new host mapping, the
   guest sees old pages). When the old `Machine` is released, `munmap` pulls the pages out from under stage 2.

**Related, same root**
- A late `signalUsed`/`signalConfigChange` from an old device raises an SPI in the new VM (spurious; the
  new guest acks it). `Machine.setBalloonTarget` from L4 does the same.
- If the old `Machine` is deallocated while a drain is queued, the `unowned self` closures trap, and the
  inflate path reads guest RAM that is unmapped. Today `keepClock`'s task (`Daemon.swift:386-394`) holds
  the machine for up to 15 s after stop, which hides this by accident; `dmx boot`, `dmx run` and selftest
  have no such holder.
- After `munmap`, the next machine's `mmap` of the same size is likely to land on the same address, so a
  late net or vsock delivery writes into the new guest's RAM.
- `MemoryPlugPolicy.stop()` writes `balloon.onStats = nil` without the balloon's lock (`MemoryPlugPolicy.swift:75`,
  read under the lock at `VirtioBalloon.swift:185-188`).

**Fix direction.** Give every device a synchronous `stop()` that drains its queue (as `VirtioBlock.close`
and `VirtioFS.stop` do), call them all before `destroyVM()`. Add a per-machine "VM alive" flag, set false
under `hostMappings.exclusive` in `destroyVM`, and check it inside `release` and `setSPI`. Make the device
closures `weak`. Keep guest RAM mapped until every device queue is drained, not until `deinit`.

**Proof.** Unit test: a `VirtioBalloon` with a `release` closure that counts calls; queue many reports,
call the new `stop()`, assert no call arrives afterwards. On the real VM: a loop in `scripts/test-daemon.py`
that frees 2 GB in the guest, then `dmx stop && dmx start` at offsets of 1.5 to 3 s, and checks the new
guest (`dmesg` clean, a memory test pattern survives); log every `release` that runs after `destroyVM` in
a diagnostic build first, to measure the window on the old code.

## G1. exec: a child that stops reading stdin blocks every control frame and the hang-up kill

**Where.** `guest/agent/src/exec.rs:159-176` (one thread does `write_all` to the child's stdin, handles
control frames and does the hang-up `kill(-pid, SIGKILL)`); `Sources/DMXCore/Agent.swift:271-283`
(`writeLock` held across a blocking write), `:594-608` (stdin and `signal` share `writeFrame`);
`MCP/CappedExec.swift:112-118,178-185`; `RunCommand.swift:45-61`.

**Sequence A** (MCP `dmx_exec`): stdin over 64 KiB to a process that does not read it → the agent thread
blocks in `write_all` → timeout fires, the host shuts the stream → nobody reads the EOF → the SIGKILL never
runs; the tool reports `timed_out` and the process lives on.

**Sequence B** (`head -c 8M /dev/zero | dmx exec -- sleep 600`, Ctrl-C): buffers fill end to end,
`pipeStdin` blocks in `writeFrame` holding `writeLock`; the SIGINT source on the main queue calls
`session.signal`, which blocks on the same lock. Only `kill -9` ends the CLI.

**Fix direction.** In the agent, write child stdin from its own thread with a bounded queue (or a
non-blocking fd with poll) so the connection reader always sees control frames and EOF; on EOF kill the
group whatever the backlog. On the host, `signal`/`resize` must not wait behind a blocked stdin write.

**Proof.** Rust unit test (socketpair, child `sleep 30`, 1 MiB of stdin frames, close, child dead within
1 s). `scripts/test-daemon.py`: 1 MiB stdin plus SIGINT exits within 2 s with no `sleep` left in the
guest; `scripts/test-mcp.py`: `dmx_exec` with 200 KB stdin and a 2 s timeout leaves `pgrep` empty.

## G4. `shutdown` queues behind a control call in flight; the plug is pulled first

**Where.** `Agent.swift:545-547` (shared control connection), `guest/agent/src/main.rs:64-116` (a connection
is served in order; `shutdown` at `:102-108` then spends up to 7 s in `docker::stop`); `Daemon.swift:487-499`
(the 10 s timer starts before the request is sent); long control calls: `MemoryController.swift:240,261,274`
(`reclaim`, `shrinkSlabs`, `trimDisk`), `guest/agent/src/sys.rs:121-126,151`.

**Sequence.** The memory controller is inside `reclaim` or the idle `trim_disk` when stop arrives.
`shutdown` waits behind it; dockerd stop, `sync` and `FIFREEZE` no longer fit in what is left of 10 s;
`machine.stop()` halts the vCPUs: no SIGTERM to containers, no sync, journal replay at next boot.

Also: `DockerProxy.swift:131-133` syncs the clock on the same connection, so a slow `reclaim` can delay
`docker start`/`exec` by up to the call timeout.

**Fix direction.** Send `shutdown` on a fresh connection (`AgentClient.open`). Start the 10 s when the
agent acknowledges, with a separate short bound on reaching it.

**Proof.** Unit test with a fake agent whose first call sleeps. `scripts/test-daemon.py`: stop during a
simulated-pressure reclaim; assert no "did not power off within 10 s" in the log and a clean e2fsck next boot.

## G3. UDP forward: blocking write on the relay queue, `queue.sync` from the MainActor

**Where.** `Daemon/UDPForward.swift:142-160` (`send` blocks in `write`; `FrameConnection.init` clears
`O_NONBLOCK`, `Agent.swift:139-140`), `:76` (`counts`) and `:79-87` (`close`) are `queue.sync`;
`Docker.swift:92-107` (`vmStopped` closes listeners); `Daemon.swift:487-493` (`docker.vmStopped()` runs
before the deadline task exists).

**Sequence.** The guest stops making progress while a peer keeps sending to a published UDP port → about
1.5 MB of buffers fill → `send` blocks on the relay queue → `dmx stop` reaches `powerOff()` → `vmStopped()`
→ `close()` → `queue.sync` on the main thread, forever. The forced stop never fires. `dmx port ls`/`rm`
block the same way.

**Fix direction.** Non-blocking stream fd, drop datagrams on `EAGAIN` (the comment already says they are
dropped); `close()` and `counts` must not wait on the queue synchronously.

**Proof.** Unit test: `connect` returns a `FrameConnection` on a socketpair nobody reads; flood 4 MB;
`close()` and `counts` return within 100 ms.

## G2. A hung host file-system call in a share holds a vCPU and makes stop hang forever

**Where.** `HV/VirtioFS.swift:68-98` (metadata ops run on the vCPU thread), `:106-115` (`stop()` waits on
`inflight` with no bound); `Share.swift:20` (`/Volumes` is shared by default); `Machine.swift:276`
(`threads.notify` waits for every vCPU thread); `VCPU.swift:67-74` (`halt` cannot interrupt a syscall).

**Sequence.** A container stats a path on a dead SMB/NFS mount → the syscall never returns on the vCPU
thread → later `Machine.stop` never sees that thread end → `stopped` is never set → `Daemon.powerOff`
stays in `.stopping`; every `running()` caller waits; only `kill -9` helps.

**Fix direction.** Bound teardown: after a deadline give up on stuck requests and exit the process (a
stuck syscall cannot be cancelled). Consider running ops on non-local volumes off the vCPU threads.

**Proof.** Unit test with a seam in `FUSEServer` that blocks one quick op; `VirtioFS.stop()` and
`Machine.stop` must finish within the deadline.

## G5. Unpack markers are written before the unpacked data is durable

**Where.** `guest/docker:32-46` (`tar -x` → `.version` → `mv` → `mv` → `rm` → `sync`); `guest/init:88-92`
(`unxz | tar -x` → `sha256` → `rm -rf` → `mv` → `sync`).

**Sequence.** A hard stop (SIGKILL of dmx, launchd killing the job, a Mac crash, the 10 s plug-pull)
lands after the marker and renames reach the journal but before delayed-allocation data is written. Next
boot the marker matches, nothing is unpacked again, and `dockerd`/`containerd`/`FEX` is truncated: Docker
or x86 stays broken with no self-heal.

**Fix direction.** `sync` the new tree before writing the marker and renaming, then sync again; or verify
a size manifest when the marker matches.

**Proof.** `scripts/test-storage.py` loop: remove the marker, trigger the unpack, SIGKILL dmx at random
offsets, reboot, assert dockerd starts. It has to fail on the old guest.

## G6. A full host disk becomes guest I/O errors

**Where.** `HV/VirtioBlock.swift:113-121` (sparse image), `:235-238`, `:343-352` (`pwritev` failure →
`ioError`). No free-space check in `Sources`.

**Sequence.** `data.img` grows until APFS is full → ENOSPC → guest EIO → ext4 drops async writes and aborts
its journal → containers fail; the next boot runs `e2fsck -fy` unattended.

**Fix direction.** On ENOSPC hold the request and surface `disk_full` in `dmx status`, retry when space
returns (QEMU's `werror=enospc`); warn at a low-water mark.

**Proof.** `scripts/test-storage.py` with `DMX_HOME` on a small `hdiutil` volume.

## L2. `Machine.init` leaks the process's one VM when it throws after `hv_vm_create`

**Where.** `Machine.swift:96` (`hv_vm_create`), `:105-106` (`hv_vm_map`), `:113-115` (GIC), all `try check(...)`.
`uart` and `console` are assigned only at `:117-121`, so a throw before that leaves the object partly
initialized and Swift does not run `deinit`: `hv_vm_destroy` is never called and the `mmap` at `:98` is
never unmapped. Only the `mmap` failure path (`:100`) destroys the VM by hand.

**Effect.** A process holds one VM, so every later boot in this daemon fails in `hv_vm_create` until the
daemon exits (it lingers while clients keep connecting).

**Also.** `RunCommand.swift:11-12` and `DMX.swift:193-197`: when `start()` throws (`loadGuest`), the
machine is dropped without `stop()`; `deinit` then calls `destroyVM()` with vCPU threads still parked in
`waitForPowerOn`. Harmless only because those processes exit.

**Fix direction.** A `defer`/`do-catch` in `init` that destroys the VM and unmaps on any throw after
`hv_vm_create`; make `start()` stop the machine on every failure path.

**Proof.** Unit test with a seam that fails the GIC step, then creates a second `Machine` in the same process.

## L3. Stop or SIGTERM during boot waits for the whole boot

**Where.** `Daemon.swift:470-474` (`.starting` with a machine: `await booting.value`), `:318`
(`connectAgent(timeout: 120 s)`), `:546-554` (`shutdown` → `stopVM`); `Launchd.swift:135-151` (no
`ExitTimeOut`, so launchd's default applies).

**Sequence.** Logout, `launchctl bootout` or `dmx install` sends SIGTERM during a slow first boot (the
data disk is being formatted). `shutdown()` waits for the boot; launchd kills the job when its exit
timeout passes: the format the wait was meant to protect is cut anyway, and `dmx stop` blocks meanwhile.

**Fix direction.** Decide the bound on purpose: set `ExitTimeOut` in the plist to cover it, and give
`stopVM` during `.starting` a deadline after which it powers off through the normal path.

**Proof.** `scripts/test-daemon.py`: SIGTERM 1 s into a first boot with a fresh `data.img`; the daemon
exits within the bound and the next boot finds a usable disk.

## G7. One failed container listing leaves `containers` and forwards stale

**Where.** `Daemon/Docker.swift:400-416` (an error only logs, `:407-409`), `:56` (`busy`).
**Sequence.** The listing after the last `die` fails → `containers` stays above 0 → the VM never
idle-stops. Or the listing after a `start` fails → the published port is never forwarded.
**Fix direction.** Retry with backoff while the epoch matches; treat the count as unknown meanwhile.
**Proof.** Unit test with an injected listing failure asserting a later resync.

## G8. NAT TCP flows and forwarded sockets are never reaped

**Where.** `HV/UserNetTCP.swift:132-136,308-310,318-353`; `UserNet.swift:30` (2048 flows);
`Daemon/PortForward.swift:354-358` (no `SO_KEEPALIVE`).
**Sequence.** The guest closes, the remote never sends FIN: the flow and its fd stay until the VM stops;
2048 of them and new guest connections are reset. A LAN client of a `0.0.0.0` forward that vanishes
without FIN keeps `using(true)` held, so the VM never idle-stops.
**Fix direction.** Idle timeout for half-closed flows; `SO_KEEPALIVE` with a short `TCP_KEEPALIVE`.
**Proof.** Unit test driving `UserNet` against a local server that never closes, advancing the tick clock.

## G9. exec control frames act on a reaped pid and a closed pty fd

**Where.** `guest/agent/src/exec.rs:158` (raw `master_fd`), `:168`, `:179-200` (`wait` reaps, `drop(master)`
at the end; the reader thread lives on until the connection is shut).
**Sequence.** Between `child.wait()` and the connection shutdown a `signal` frame calls `kill(pid, sig)`
on a pid that may be reused; a `resize` after `drop(master)` hits a reused fd number.
**Fix direction.** Check `exited` under a lock taken around `wait()` (or use a pidfd); share the pty as `Arc<OwnedFd>`.
**Proof.** Rust unit test: `signal` after exit issues no `kill`.

## L4. A memory-controller tick in flight keeps acting after `detach()`

**Where.** `Daemon/MemoryController.swift:117-123` (`detach` cancels and clears), `:171-230` (`tick` awaits
`swapOn`, `trim`, `sweep`, then at `:217-229` uses its captured `machine` with no cancellation check).
**Sequence.** `powerOff` detaches while a tick awaits the agent. When the call fails or returns, the tick
writes `swapOn`, `diskTrims`, `swept`, `trims` (controller state the next `attach` may already have reset
for a new VM) and, without virtio-mem, calls `machine.setBalloonTarget` on the stopped machine, which
raises an SPI through L1's path.
**Fix direction.** After every `await` in `tick`/`sweep`, return if the task is cancelled or
`self.machine !== machine`.
**Proof.** Unit test with a fake agent that completes after `detach()` + `attach(new)`; the new VM's flags are untouched.

## L5. The CLI spawns the daemon once

**Where.** `Daemon/DaemonClient.swift:40-46` (`spawned` is never reset); `Daemon.swift:546-561` (a standalone
daemon unlinks and closes its socket, then exits, holding `daemon.lock` until exit), `:566-574`.
**Sequence.** A client connects while the old standalone daemon is between closing its socket and exiting:
its queued connection is reset, the retry finds no socket, it spawns a daemon, that daemon fails
`takeLock` and exits, and the client never spawns again: `daemon_unreachable` after 15 s. The 20 ms retry
sleep usually hides it.
**Fix direction.** Reset `spawned` when the spawned pid has exited (`DaemonChildren` already watches it);
or release the lock before closing the socket.
**Proof.** Unit test with a helper holding `daemon.lock` for 200 ms after its socket is gone.

## G10. `FUSEServer.rootDir` is a `lazy var`

**Where.** `HV/FUSEServer.swift:128`, used at `:357`, `:397` from vCPU threads and workers without the lock.
**Fix direction.** A `let` built in `init`. **Proof.** TSan run of `FUSEServerTests` with parallel first lookups.

## G11. Docker socket accept loop spins on `EMFILE`

**Where.** `Daemon/Docker.swift:111-120` returns on any accept error; the level-triggered source refires at
once. `PortForward.swift:341-352` already pauses and retries. **Fix direction.** Reuse that.

## L6. `hv_vcpus_exit` before the vCPU is in `hv_vcpu_run` (needs a check, not a finding)

**Where.** `HV/VCPU.swift:67-74` (`halt`), `:131-133` (`while !isHalted { hv_vcpu_run }`).
`halt` can run between the `isHalted` check and `hv_vcpu_run`. The code relies on the exit request being
remembered for the next `hv_vcpu_run`. If it is not, a guest that spins with interrupts masked never
leaves the run and stop hangs. Also `halt` on a vCPU whose `id` is still 0 (not created yet) kicks vCPU 0.
**Check.** A 20-line test: call `hv_vcpus_exit` on an idle vCPU, then `hv_vcpu_run` on a guest loop;
it must return `HV_EXIT_REASON_CANCELED` at once. Record the answer in PLAN.md either way.

---

## Decisions rather than bugs

- NAT resets every flow with unacked data after about 32 s of guest silence (`UserNetTCP.swift:343-352`,
  `retries > 10`): a guest stalled that long loses connections a real stack would keep for minutes.
- `VirtioMem.handle` holds the device lock across `release` of whole blocks (`VirtioMem.swift:144-172`), so a
  vCPU reading the config waits for the `madvise`. Performance only.

## Checked and found sound

- Daemon state machine (`running`/`boot`/`stopVM`/`powerOff`/`watch`): no state with a nil task that would
  spin the MainActor; the idle check sets `.stopping` in the same turn as it tests `users == 0`; `finished`
  cannot be resumed before `run()` suspends; a boot cancelled while the guest downloads cannot interleave
  with machine creation.
- `connectAgent` ends early when the machine stops during boot.
- `VCPU` WFI wake (`woken` cannot be lost), PSCI CPU_ON/OFF hand-off, `waitUntilStopped` continuations.
- `HostMappings` remap/stop locking; `MemoryPlugPolicy` serialisation on its queue and its `stop()`.
- Virtqueue descriptor validation; virtio-blk bounds, discard ranges, flush barrier, `close()`.
- vsock credit accounting, RST/SHUTDOWN, fd lifetime, `closeAll` waking readers.
- `Splice`, the daemon `relay`, `DockerProxy` end-of-stream paths.
- FUSE path confinement, handle duplication against RELEASE, lookup/forget counts, the read-only gate.
- Guest power-off order (`sync` → `FIFREEZE` → `reboot`), init's fsck and format logic, zombie reaping.
- `RotatingLog`, `HostDNS` lookup lifetime, `ExecKiller`/`StreamKiller` fd-reuse guards.
