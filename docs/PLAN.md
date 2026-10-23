# dmx plan and progress

This is the source of truth for what dmx is, what has been decided, and what to do next.
An agent asked to "continue" (이어서 진행해) starts at [Next up](#next-up), does that work,
then updates this file in the same commit. See [AGENTS.md](../AGENTS.md) for the working rules.

## Goal

A container engine for macOS (Apple Silicon) with three properties:

1. **Memory that comes back.** The VM costs close to nothing when idle and returns memory the
   guest stops using. This is the main reason the project exists: the author rejected tools that
   pin a fixed chunk (for example 8 GB) of a 16 GB Mac.
2. **Docker compatible.** The `docker` CLI and Compose work unchanged against a dmx socket.
3. **AI native.** Agents drive it as easily as people: `--json` on every command, structured
   errors with a hint, no interactive prompts, and later an MCP mode plus sandbox features.

Non-goals for now: a GUI (a menu bar item may come much later), Intel Macs, Windows/Linux hosts.

## Architecture

```
dmx (CLI) ──▶ dmx daemon (launchd agent, socket activated)
                ├─ Linux VM via Virtualization.framework
                │    balloon, vsock, virtio-net (NAT), virtio-fs, virtio-blk
                ├─ memory controller (balloon, idle stop, host pressure)
                └─ ~/.dmx/docker.sock ◀── docker CLI / compose
                      │ vsock
Linux guest:  /init ─▶ dmx-agent (Rust) ─▶ dockerd/containerd first, own runtime later

dmx mcp (stdio) ── talks to the daemon over its control socket; started by AI clients
```

- One Swift binary, `dmx`, has three entry points: the CLI, `dmx daemon`, and `dmx mcp`.
  `Sources/DMXCore` holds all logic so every entry point shares it.
- The daemon is not the MCP server. AI clients start `dmx mcp`, which is short lived, so the
  daemon can stop completely when idle.
- Guest side code is Rust (`guest/agent`, not created yet), cross compiled to static musl.

## Decisions

| Decision | Why |
|---|---|
| Use a VM | macOS has no namespaces/cgroups/Linux syscall ABI. Syscall translation (WSL1 style) failed on compatibility and filesystem speed. |
| Virtualization.framework, not Hypervisor.framework | Gives virtio devices, balloon, vsock, virtio-fs, Rosetta and save/restore for free. |
| One long lived VM, not one VM per container | One kernel's overhead instead of N. Revisit per-container VMs for sandboxes (phase 8). |
| CLI only, no GUI | The work that matters is invisible (memory, sockets). Agents use CLIs. |
| Memory savings are always on | Balloon, idle stop and cache trimming are defaults, not options. The user's standing preference: improvements are not toggles. |
| Docker compatibility first via dockerd in the guest | Gets `docker run` working early; own runtime replaces pieces later. |
| Alpine Linux artifacts, pinned by sha256 | Small, musl, official signed packages. A custom kernel is allowed when needed (see phase 3). |
| Apache-2.0 | Same as Docker/moby and containerd; includes a patent grant. |
| State in `~/.dmx`, override with `DMX_HOME` | Simple for people and agents; easy to sandbox in tests. |

## Phases

Status: `[x]` done, `[ ]` to do. Each phase lists how to tell it is done.

### Phase 1: Boot a Linux VM (done)

- [x] Swift package, `dmx` binary, ad-hoc signed with `com.apple.security.virtualization` (`make build`)
- [x] Guest build from pinned Alpine 3.24 minirootfs + linux-virt 6.18 (`make guest`):
      raw arm64 `Image` extracted from the EFI zboot `vmlinuz`, initramfs with 25 modules
- [x] `guest/init` as PID 1: mounts, cgroup2, loads balloon/vsock/rng modules, shell on hvc0
- [x] `dmx doctor` (host, entitlement, guest files)
- [x] `dmx boot` with an interactive console (raw tty, Ctrl-C goes to the guest, Ctrl-] powers off)
- [x] `dmx boot --selftest --json` (boot, guest reports, power off)

Done when: `make build guest selftest` passes. Measured: boot 0.7 s, guest uses 64 MB inside.

### Phase 2: Guest agent and control channel (done)

- [x] `guest/agent` Rust crate, built for `aarch64-unknown-linux-musl` from macOS with
      `rustup target add` + the bundled `rust-lld` (no zig or Linux C toolchain needed).
      `make guest` builds it (`cargo build --locked`) and puts it at `/sbin/dmx-agent`.
- [x] Protocol over vsock port 1024, specified in [agent-protocol.md](agent-protocol.md):
      length-prefixed frames carrying JSON or stdin/stdout/stderr bytes, versioned by `hello`.
- [x] Agent calls: `exec` (streams, tty, resize, signal, exit code), `stats` (meminfo,
      per-cgroup `memory.current`), `drop_caches`, `shutdown`, `time_sync`.
- [x] Host side `AgentClient` in DMXCore via `VZVirtioSocketDevice.connect(toPort:)`: one
      connection for control calls, one per exec. Retries until the agent listens.
- [x] `dmx boot --selftest` drives the agent (exec with stdin, stderr, exit code, tty, a missing
      binary; modules; drop_caches; stats) and powers off through it. `/init` no longer has a
      selftest mode.
- [x] The hvc0 console stays as a debug fallback (`dmx boot`); `/init` restarts the agent if it dies.

Done when: the selftest runs `uname -a` through the agent and gets stats as JSON. Measured: agent
answers 0.35 to 0.5 s after `start()`, clean shutdown through the agent takes 15 ms.

### Phase 3: Memory

This is the core feature. Measure before and after every change and log numbers below.

- [x] Host footprint measurement: `Machine.hostFootprint()` finds the
      `com.apple.Virtualization.VirtualMachine` XPC process whose responsible pid is us
      (`responsibility_get_pid_responsible_for_pid`; falls back to "appeared after we created the
      VM") and reads `ri_phys_footprint` with `proc_pid_rusage`. Selftest JSON has `host`
      (`pid`, `footprint_mb`, `peak_footprint_mb`), read after drop_caches. Status JSON comes in phase 4.
- [ ] Shrink the baseline that scales with the ceiling (finding: 2G → 170 MB, 8G → 354 MB host
      footprint while the guest used 64 MB). Investigate in this order and record results:
      1. [x] What the kernel touches at boot for the whole ceiling. Host footprint ≈ guest
         "reserved" (dmesg `Memory:` line) + guest used, and reserved explains the whole slope.
         SWIOTLB was sized to the ceiling (64 MB at 8 GB, zeroed by memblock); `swiotlb=noforce`
         is now a default kernel arg (8G: 356 → 291 MB). What scales now is the memmap,
         16 MB/GB (128 MB at 8 GB). `init_on_alloc=0` and `rodata=on` change nothing at idle;
         no page poisoning, KASAN or page_owner in the Alpine config.
      2. A custom kernel with 16K pages (`CONFIG_ARM64_16K_PAGES`), which makes memmap 4x smaller and matches Apple Silicon's native page size. Build it inside a dmx VM.
      3. Inflating the balloon early in boot and deflating on demand, so untouched memory is never backed.
- [ ] Balloon controller in the daemon: target = guest used + headroom, read from agent `stats`;
      return memory after containers exit; react within seconds.
- [ ] Guest policy: trim page cache when idle (`drop_caches` or cgroup `memory.reclaim`), zram
      swap with lz4, sensible `vm.*` sysctls.
- [ ] Host pressure: `DispatchSource.makeMemoryPressureSource` shrinks the guest first.

Done when: idle VM host footprint is under 150 MB at an 8 GB ceiling, and after a container that
uses 2 GB exits, footprint falls back within 10 s. Numbers recorded in the log.

### Phase 4: Daemon and lifecycle

- [ ] `dmx daemon`: owns the VM, control socket `~/.dmx/dmx.sock` (JSON requests, same codes as CLI errors).
- [ ] launchd user agent with socket activation (`dmx install` / `dmx uninstall`), so nothing runs until a client connects.
- [ ] `dmx start`, `dmx stop`, `dmx status --json` (state, uptime, cpus, ceiling, guest used, host footprint, containers).
- [ ] Idle stop: no containers and no clients for N minutes → save state (`saveMachineStateTo`) or shut down; next connection restores/boots. Measure resume time.
- [ ] `dmx shell` and `dmx exec` through the daemon and agent.
- [ ] `dmx config get/set` (max-memory, cpus, idle timeout) stored in `~/.dmx/config.json`.

Done when: after `dmx install`, connecting to the socket boots the VM, and an idle VM disappears and its processes exit.

### Phase 5: Storage, network, file sharing

- [ ] Data disk: sparse raw image `~/.dmx/data.img` on virtio-blk, ext4 with discard, so deleted data shrinks the file (APFS sparse + TRIM). Mounted at `/var/lib` in the guest.
- [ ] Network: virtio-net NAT, DHCP in the guest (udhcpc), DNS, check outbound HTTPS.
- [ ] Port forwarding: host listener → vsock → guest port (no privileged helper).
- [ ] virtio-fs share of the user's home (or configured paths) at the same path in the guest, so bind mounts keep their paths. Measure throughput against native.

Done when: the guest can `wget` from the internet, a guest web server is reachable on `localhost`, and a host directory is readable/writable in the guest.

### Phase 6: Docker compatibility

- [ ] dockerd + containerd in the guest (Alpine packages installed onto the data disk, or a separate pinned layer).
- [ ] `~/.dmx/docker.sock` forwarded to the guest's `/var/run/docker.sock` over vsock.
- [ ] `dmx install` creates and selects a `docker context` named `dmx`.
- [ ] Published ports are forwarded automatically (watch Docker events).
- [ ] Bind mounts of host paths work through virtio-fs.
- [ ] x86_64 images through Rosetta (`VZLinuxRosettaDirectoryShare` + binfmt).
- [ ] Test suite: `docker run hello-world`, `docker build`, a compose app with a volume and a port.

Done when: the test suite passes with the stock `docker` CLI.

### Phase 7: Own runtime

- [ ] OCI image pull and unpack (registry auth, layers, content store) in Rust.
- [ ] overlayfs snapshotter.
- [ ] Container runtime: namespaces, cgroups v2, seccomp, capabilities (study youki/runc).
- [ ] Serve a subset of the Docker Engine API from dmx itself; replace dockerd piece by piece while the phase 6 suite keeps passing.

### Phase 8: AI native

- [ ] `dmx mcp` (stdio MCP server) on top of DMXCore: status, run, exec, logs, stop, sandbox tools.
- [ ] Sandboxes: disposable environments with a policy (allowed host paths, network egress allowlist, cpu/memory limits, TTL).
- [ ] Checkpoints: snapshot and roll back an environment; fork one to try two approaches.
- [ ] Output limits and summaries so large logs do not flood an agent's context.

### Phase 9: Release

- [ ] CI on GitHub Actions: build and unit tests (hosted macOS runners may not allow nested virtualization; VM tests stay local until proven otherwise).
- [ ] Guest artifacts published as GitHub Releases, downloaded and verified by `dmx`, so users do not need Python.
- [ ] Homebrew tap; Developer ID signing and notarization when distributing binaries.

### Later, maybe

- macOS-native mode without a VM: sandbox profiles + APFS clones to isolate macOS programs (cannot run Linux images; weaker isolation).

## Next up

Phase 3, second task, step 2: a 16K page kernel. Memmap is now the only part of the baseline
that scales with the ceiling (16 MB/GB with 4K pages, 4 MB/GB with 16K). Plan: same 6.18.58
source and Alpine's virt config (from the pinned apk) with `CONFIG_ARM64_16K_PAGES=y`, built
inside a dmx VM with a pinned toolchain, and `make guest` taking the kernel and modules from it.

## Findings and measurements

| Date | What | Result |
|---|---|---|
| 2026-10-23 | Boot to init report | 725 ms (10 vCPU, 8 GB ceiling) |
| 2026-10-23 | Guest memory used after boot | 64 MB |
| 2026-10-23 | Host footprint of the VM process | 170 MB at 2 GB ceiling, 354 MB at 8 GB |
| 2026-10-23 | Static aarch64 musl agent (hello world, opt-level s, LTO, stripped) | 330 KB; builds in 3 s with rust-lld |
| 2026-10-23 | Agent built with vsock, exec, stats (libc, serde, serde_json) | 545 KB binary; 448 KB RSS idle, 1 thread |
| 2026-10-23 | Boot to agent `hello` (host clock, 10 vCPU) | 335 to 520 ms at 2 GB and 8 GB ceilings |
| 2026-10-23 | Clean shutdown via agent `shutdown` until `guestDidStop` | 15 ms |
| 2026-10-23 | Guest clock at boot vs host | 0.25 to 0.3 s behind; `time_sync` corrects it |
| 2026-10-23 | Guest used (total - free - buffers - cached + shmem, after drop_caches) | 72 to 86 MB. `total - MemAvailable` reads ~175 MB at 8 GB because MemAvailable subtracts the watermark reserve, so it is not used. |
| 2026-10-23 | Selftest `host.footprint_mb` (after drop_caches, 10 vCPU) | 171 MB at 2G, 274 MB at 4G, 356 MB at 8G; guest used 64 to 79 MB. Matches `footprint <pid>`. Baseline grows ~31 MB per GB of ceiling. |
| 2026-10-23 | Finding the VM process | `proc_name` truncates to 32 bytes, shorter than `com.apple.Virtualization.VirtualMachine`; match on `proc_pidpath`. Other VMs (other apps, stale dmx runs) share the name, so match on responsible pid. |
| 2026-10-23 | Guest "reserved" at boot (dmesg `Memory:`) | 89 MB at 2G, 271 MB at 8G: +182 MB, same as the host footprint's +184 MB. At 8G: memmap 128 MB, SWIOTLB 64 MB, kernel image ~35 MB. |
| 2026-10-23 | `swiotlb=noforce` (default now) | 8G: 356 → 291 MB. 2G 165, 4G 208, 8G 291 MB. Selftest passes. Remaining slope ~21 MB/GB, mostly memmap. |
| 2026-10-23 | `init_on_alloc=0`, `rodata=on` | No change at idle (355 MB, 293 MB). Not adopted. |
| 2026-10-23 | Virtio features VZ offers | Balloon: MUST_TELL_HOST and DEFLATE_ON_OOM only; no free page reporting, no stats queue. No device offers ACCESS_PLATFORM. Returning memory needs the balloon. |
| 2026-10-23 | Boot time vs host load | 240 to 640 ms for the same build; host load average was 17 during the slow runs. Compare boot times only on a quiet host. |
| 2026-10-23 | Console on a tty | stdin shares a file description with stdout, which the serial attachment makes non-blocking; the stdin reader must handle EAGAIN |

## Progress log

- 2026-10-23: Phase 1 done. Repo published at https://github.com/cothis/dmx (commit e630133).
- 2026-10-23: Phase 2 started. Rust agent cross compiles on macOS and runs in the guest.
- 2026-10-23: Phase 2 done. Host and guest talk over vsock; the selftest runs entirely through the agent.
- 2026-10-23: Phase 3 started. Selftest reports the VM process's host footprint.
