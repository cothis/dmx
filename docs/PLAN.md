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
                ├─ Linux VM on dmx's own VMM (Hypervisor.framework, Swift in DMXCore)
                │    guest RAM mapped by dmx; virtio-mmio: console, rng, vsock,
                │    balloon with free page reporting, blk, net, fs
                ├─ memory controller (free page reporting, idle stop, host pressure)
                └─ ~/.dmx/docker.sock ◀── docker CLI / compose
                      │ vsock
Linux guest:  /init ─▶ dmx-agent (Rust) ─▶ dockerd/containerd first, own runtime later

dmx mcp (stdio) ── talks to the daemon over its control socket; started by AI clients
```

- One Swift binary, `dmx`, has three entry points: the CLI, `dmx daemon`, and `dmx mcp`.
  `Sources/DMXCore` holds all logic so every entry point shares it.
- The daemon is not the MCP server. AI clients start `dmx mcp`, which is short lived, so the
  daemon can stop completely when idle.
- Guest side code is Rust (`guest/agent`), cross compiled to static musl.

## Decisions

| Decision | Why |
|---|---|
| Use a VM | macOS has no namespaces/cgroups/Linux syscall ABI. Syscall translation (WSL1 style) failed on compatibility and filesystem speed. |
| Own VMM on Hypervisor.framework, not Virtualization.framework (2026-10-23) | VZ never returns guest memory while the VM runs: ballooned pages stay in the host footprint, there is no free page reporting, and restore backs the whole ceiling (see Findings). With guest RAM mapped by dmx itself, dmx can release freed pages (`hv_vm_unmap` + `madvise(MADV_FREE_REUSABLE)`). Costs: we write the virtio devices, and lose Rosetta. Phase 1 to 2 ran on VZ. |
| The VMM is Swift, in DMXCore (2026-10-23) | One language and one binary for all host code; Hypervisor.framework is a C API Swift calls directly. Maintainer's choice over a Rust VMM process. |
| macOS 15 or later (2026-10-23) | Hypervisor.framework has an in-kernel GICv3 (`hv_gic_create`) from macOS 15, so dmx does not emulate an interrupt controller. |
| x86_64 images through QEMU user mode + binfmt, not Rosetta (2026-10-23) | Rosetta for Linux exists only inside Virtualization.framework. Most images are multi-arch; emulation is a fallback. |
| One long lived VM, not one VM per container | One kernel's overhead instead of N. Revisit per-container VMs for sandboxes (phase 9). |
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

### Phase 3: Own VMM on Hypervisor.framework (done)

Virtualization.framework never gives guest memory back while the VM runs (see Findings), so dmx
runs its own VMM, in Swift in `Sources/DMXCore`, on Hypervisor.framework. Guest RAM is memory dmx
maps itself, so dmx decides when it goes back to macOS. Needs macOS 15 (`hv_gic_create`).
Measure boot time and idle footprint at each step against the VZ numbers (8G: 181 MB, agent up in
~0.3 s).

- [x] Boot to a kernel console (`dmx boot --vmm hvf`, `Sources/DMXCore/HV`): `com.apple.security.hypervisor` entitlement; guest RAM from
      `mmap` mapped with `hv_vm_map`; in-kernel GICv3 (`hv_gic`); a device tree (memory, cpus with
      PSCI, GIC, arch timer, PL011 UART, chosen with bootargs and initrd); the raw Image and the
      initramfs loaded into guest RAM; one thread per vCPU; exits for MMIO data aborts, PSCI over
      HVC (VERSION, CPU_ON, SYSTEM_OFF, SYSTEM_RESET), WFI and the vtimer. Console on a PL011.
      10 vCPUs come up; shell prompt on ttyAMA0 0.18 to 0.57 s after start; idle CPU ~0%.
      WFI waits are capped at 1 ms because SGIs between vCPUs are invisible to us; revisit.
- [x] virtio-mmio transport with split virtqueues, shared by every device. `/init` loads
      `virtio_mmio` (a module in the current kernel config) before the other virtio modules.
- [x] virtio-console (hvc0) for the debug console, and virtio-rng.
- [x] virtio-vsock: the host end of each stream is one end of a Unix socketpair, so
      `AgentConnection` is unchanged. Credit flow control both ways; data the guest sent before
      SHUTDOWN is flushed before the connection closes.
- [x] `hostFootprint()` for the new VMM: `ri_phys_footprint` of the dmx process.
- [x] Switch `Machine` to the new VMM so the selftest passes unchanged, then remove the
      Virtualization.framework backend. Done: `Machine` is the Hypervisor.framework VM, the
      only entitlement is `com.apple.security.hypervisor`, doctor checks `kern.hv_support`.
- [x] virtio-balloon with free page reporting (`VIRTIO_BALLOON_F_REPORTING`): for each reported
      range, `hv_vm_unmap`, `madvise(MADV_FREE_REUSABLE)`, `hv_vm_map` again. Deflate on OOM is
      offered; inflated pages are released the same way. The stats queue is left for the memory
      controller (phase 4). The selftest checks it: 1 GB touched and freed must come back
      within 10 s (`reclaim`).

Done when: the selftest passes on the new VMM, boot time and idle footprint are no worse than on
VZ, and after the guest touches and frees 1 GB the host footprint falls back within 10 s.
Result: agent up in ~0.3 s, idle 172 MB at 8G (VZ 181), 1 GB comes back in 0.5 to 2 s.

### Phase 4: Memory

This is the core feature. Measure before and after every change and log numbers below.

- [x] Host footprint measurement (on VZ): `Machine.hostFootprint()` finds the
      `com.apple.Virtualization.VirtualMachine` XPC process whose responsible pid is us
      (`responsibility_get_pid_responsible_for_pid`; falls back to "appeared after we created the
      VM") and reads `ri_phys_footprint` with `proc_pid_rusage`. Selftest JSON has `host`
      (`pid`, `footprint_mb`, `peak_footprint_mb`), read after drop_caches. Status JSON comes in phase 5.
- [x] Shrink the baseline that scales with the ceiling (was 2G → 170 MB, 8G → 356 MB host
      footprint while the guest used 64 MB). Now 2G → 137 MB, 8G → 181 MB, about 7 MB/GB.
      1. [x] What the kernel touches at boot for the whole ceiling. Host footprint ≈ guest
         "reserved" (dmesg `Memory:` line) + guest used, and reserved explains the whole slope.
         SWIOTLB was sized to the ceiling (64 MB at 8 GB, zeroed by memblock); `swiotlb=noforce`
         is now a default kernel arg (8G: 356 → 291 MB). What scales now is the memmap,
         16 MB/GB (128 MB at 8 GB). `init_on_alloc=0` and `rodata=on` change nothing at idle;
         no page poisoning, KASAN or page_owner in the Alpine config.
      2. [x] A 16K page kernel: `make kernel` (`scripts/build-kernel.py`) builds kernel.org
         6.18.58 with Alpine's virt config, 16K pages, 48-bit VA, no debug info/BTF/module
         signing/GCC plugins, inside a dmx VM booted from the stock Alpine kernel, with a pinned
         offline toolchain (34 Alpine apks). `make guest` uses it. 8G: 291 → 181 MB.
      3. [x] Early balloon inflation: not needed for the baseline. Pages the guest never touches
         are never backed, so there is nothing to give back at boot. The balloon matters for
         memory touched and then freed, which is the balloon controller task.
- [ ] Shrink the fixed part (181 MB at 8G = ~96 MB reserved + ~90 MB used). Leads: slab 22 MB,
      initramfs content 12 MB (shmem), ~50 MB used but in no meminfo counter (driver page
      allocations such as vsock/console rings, per-cpu free lists with 10 vCPUs), kernel image
      ~30 MB, memmap 32 MB at 8G. Measure each before changing it.
- [ ] Trim the kernel config to what dmx and Docker need. The full Alpine module set (887
      modules) took 2 h 21 min to compile under heavy host load.
- [ ] Memory controller in the daemon: free page reporting (phase 3) returns freed memory by
      itself; the controller tunes how much (`page_reporting_order`: reports are whole free
      blocks, 32 MB with 16K pages by default, so ~30 to 80 MB stays behind after the 1 GB test)
      and inflates the balloon (config `num_pages`) only to squeeze the guest under host
      pressure. Agent `stats.memory.balloon` exists. Never inflate with `init_on_alloc=1`: each
      ballooned page gets zeroed, so backed.
- [ ] Guest policy: trim page cache when idle (`drop_caches` or cgroup `memory.reclaim`), zram
      swap with lz4, sensible `vm.*` sysctls.
- [ ] Host pressure: `DispatchSource.makeMemoryPressureSource` shrinks the guest first.

Done when: idle VM host footprint is under 150 MB at an 8 GB ceiling, and after a container that
uses 2 GB exits, footprint falls back within 10 s. Numbers recorded in the log.

### Phase 5: Daemon and lifecycle

- [ ] `dmx daemon`: owns the VM, control socket `~/.dmx/dmx.sock` (JSON requests, same codes as CLI errors).
- [ ] launchd user agent with socket activation (`dmx install` / `dmx uninstall`), so nothing runs until a client connects.
- [ ] `dmx start`, `dmx stop`, `dmx status --json` (state, uptime, cpus, ceiling, guest used, host footprint, containers).
- [ ] Idle stop: no containers and no clients for N minutes → shut down; the next connection boots. (On VZ, restoring a saved state backed the whole ceiling. Snapshots on our own VMM can map the saved memory lazily; measure before adopting.)
- [ ] `dmx shell` and `dmx exec` through the daemon and agent.
- [ ] `dmx config get/set` (max-memory, cpus, idle timeout) stored in `~/.dmx/config.json`.

Done when: after `dmx install`, connecting to the socket boots the VM, and an idle VM disappears and its processes exit.

### Phase 6: Storage, network, file sharing

- [ ] Data disk: sparse raw image `~/.dmx/data.img` on our virtio-blk, ext4 with discard, so deleted data shrinks the file (APFS sparse + TRIM). Mounted at `/var/lib` in the guest.
- [ ] Network: our virtio-net with a user space NAT on the host (vmnet needs root or an entitlement Apple grants). Options: a slirp-like TCP/UDP proxy behind virtio-net, or socket calls forwarded over vsock (libkrun's TSI). DHCP in the guest (udhcpc), DNS, check outbound HTTPS.
- [ ] Port forwarding: host listener → vsock → guest port (no privileged helper).
- [ ] Our virtio-fs device (a FUSE server on the host) sharing the user's home (or configured paths) at the same path in the guest, so bind mounts keep their paths. Measure throughput against native.

Done when: the guest can `wget` from the internet, a guest web server is reachable on `localhost`, and a host directory is readable/writable in the guest.

### Phase 7: Docker compatibility

- [ ] dockerd + containerd in the guest (Alpine packages installed onto the data disk, or a separate pinned layer).
- [ ] `~/.dmx/docker.sock` forwarded to the guest's `/var/run/docker.sock` over vsock.
- [ ] `dmx install` creates and selects a `docker context` named `dmx`.
- [ ] Published ports are forwarded automatically (watch Docker events).
- [ ] Bind mounts of host paths work through virtio-fs.
- [ ] x86_64 images through QEMU user mode registered with binfmt_misc (pinned build). Check which x86 programs mind 16K guest pages.
- [ ] Test suite: `docker run hello-world`, `docker build`, a compose app with a volume and a port.

Done when: the test suite passes with the stock `docker` CLI.

### Phase 8: Own runtime

- [ ] OCI image pull and unpack (registry auth, layers, content store) in Rust.
- [ ] overlayfs snapshotter.
- [ ] Container runtime: namespaces, cgroups v2, seccomp, capabilities (study youki/runc).
- [ ] Serve a subset of the Docker Engine API from dmx itself; replace dockerd piece by piece while the phase 7 suite keeps passing.

### Phase 9: AI native

- [ ] `dmx mcp` (stdio MCP server) on top of DMXCore: status, run, exec, logs, stop, sandbox tools.
- [ ] Sandboxes: disposable environments with a policy (allowed host paths, network egress allowlist, cpu/memory limits, TTL).
- [ ] Checkpoints: snapshot and roll back an environment; fork one to try two approaches.
- [ ] Output limits and summaries so large logs do not flood an agent's context.

### Phase 10: Release

- [ ] CI on GitHub Actions: build and unit tests (hosted macOS runners may not allow nested virtualization; VM tests stay local until proven otherwise).
- [ ] Guest artifacts published as GitHub Releases, downloaded and verified by `dmx`, so users do not need Python.
- [ ] Homebrew tap; Developer ID signing and notarization when distributing binaries.

### Later, maybe

- macOS-native mode without a VM: sandbox profiles + APFS clones to isolate macOS programs (cannot run Linux images; weaker isolation).

## Next up

Phase 4, "Shrink the fixed part": idle is 172 MB at 8G for the whole dmx process (goal: under
150 MB). Measure where it goes first: guest reserved (~96 MB: memmap 32 MB, kernel image ~30 MB),
guest used (~90 MB: slab 22 MB, initramfs 12 MB, ~50 MB in no meminfo counter), and dmx's own
~31 MB. Free page reporting already returns freed boot-time memory, so idle now reflects what is
in use. Then the kernel config trim, which also makes `virtio_mmio` built in.

## Findings and measurements

| Date | What | Result |
|---|---|---|
| 2026-10-23 | Boot to init report | 725 ms (10 vCPU, 8 GB ceiling) |
| 2026-10-23 | Guest memory used after boot | 64 MB |
| 2026-10-23 | Host footprint of the VM process (VZ) | 170 MB at 2 GB ceiling, 354 MB at 8 GB |
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
| 2026-10-23 | 16K page kernel (6.18.58-dmx), selftest `host.footprint_mb` | 2G 137 MB (was 165), 4G 150 MB (was 208), 8G 181 MB (was 291). Guest used 81 to 100 MB (was 64 to 79): 16K pages cost some memory. All selftest checks pass; agent up in 315 to 350 ms. |
| 2026-10-23 | Guest reserved with 16K pages | 59 MB at 2G, 96 MB at 8G: ~6 MB/GB, of which memmap is 4 MB/GB. |
| 2026-10-23 | Guest memory at idle, 16K, 8G | MemTotal - MemFree = 98 MB: slab 22 MB, shmem (initramfs) 12 MB, vmalloc 5.6 MB, kernel stacks 1.9 MB, percpu 1.9 MB, page tables 0.9 MB; ~54 MB in no counter. |
| 2026-10-23 | Kernel build in a dmx VM (8G, 10 vCPU, tmpfs) | 8460 s compile, Image + 887 modules, with host load average 40 to 170 from other work. VM footprint peaked at 4.8 GB and was all returned when the VM exited. 42 MB output tar. |
| 2026-10-23 | Kernel config pitfalls | The 16K default VA size is 52 bits (needs LPA2, trips a fixmap static_assert); keep 48. `MODULE_SIG_KEY` is still used via IMA_APPRAISE_MODSIG, so the build needs the `openssl` CLI. apk needs `--force-non-repository` for offline local packages. |
| 2026-10-23 | Balloon on VZ (macOS 26.6.1, 16K and 4K guests, 8G) | Guest touched 1 GB and freed it: footprint 179 → 1205 MB. Target set to used + 256 MB: guest inflated 7.5 GB in ~1 s, footprint stayed 1205 MB for 40 s and after deflating. `footprint` shows guest RAM as dirty, 0 reclaimable. Resident fell (1234 → 854 MB) only because macOS compressed pages. Same with the stock 4K kernel. Matches [ArcBox](https://arcbox.dev/blog/macos-vm-memory-ratchet), [msl #37](https://github.com/onexay/msl/issues/37), [nagstaku/macos-container-vm-memory](https://github.com/nagstaku/macos-container-vm-memory). |
| 2026-10-23 | Balloon and `init_on_alloc=1` (Alpine default) | Inflating zeroes each page it takes: footprint jumped 1205 → 7826 MB and stayed there. Never inflate with init_on_alloc on, whatever the VMM. |
| 2026-10-23 | Save/restore on VZ (8G) | Save after 1 GB of random data was freed: 1088 MB file in 3.3 s (zero pages are skipped: 63 MB with a zero fill). Restore into a new VM process: 3.5 s, footprint 8301 MB, so the whole ceiling is backed. Restore needs the same `machineIdentifier` and a fixed MAC address (otherwise "invalid argument"). Not a reclaim path. |
| 2026-10-23 | Own VMM (HVF), idle footprint of the dmx process, guest RAM included | 2G 126 MB, 8G 171 MB (VZ: 137 and 181 MB, not counting dmx itself). Shell prompt 0.18 to 0.57 s after start, 10 vCPUs. |
| 2026-10-23 | Measuring an HVF VM | `footprint <pid>` leaves out guest pages dirtied through `hv_vm_map` (it showed 58 MB while the guest held 1 GB); `ri_phys_footprint` from `proc_pid_rusage` counts them and matches the drop in host free memory. Read the kernel and initramfs with `.alwaysMapped`: copies held in malloc cost 27 MB. |
| 2026-10-23 | Hypervisor.framework GIC and MPIDR | The redistributor region is 32 MB (sized for the framework's maximum vCPUs), 128 KB per vCPU, handed out in vCPU creation order. MPIDR_EL1 starts at 0 on every vCPU; set it (Aff0 = index) or the kernel finds no redistributor. Linux traps OSLAR_EL1/OSDLR_EL1 at boot; ignoring them is fine. |
| 2026-10-23 | Selftest on the own VMM (8G, 10 vCPU) | All checks pass. Agent up in 299 to 321 ms (VZ: 252 to 350 ms), shutdown 1 to 5 ms (VZ: 11 to 15), dmx process footprint 172 to 173 MB including guest RAM (VZ service process alone: 181). |
| 2026-10-23 | vsock throughput on the own VMM | 500 MB guest → host in ~2.7 s after boot (~180 MB/s, one stream, 256 KB window, socketpair buffers 1 MB). 50 MB both ways round trip intact. |
| 2026-10-23 | Stock Alpine 4K kernel on the own VMM | Boots and passes the selftest (footprint 287 MB at 8G, the 4K memmap), so `make kernel` bootstraps without VZ. |
| 2026-10-23 | Free page reporting on the own VMM (8G) | 1 GB of random data in tmpfs, then `rm`: footprint 1197 to 1199 MB → 205 to 253 MB in 0.5 to 2 s, 8 to 9 reports. 2G: 1131 → 155 MB in 2 s. Stock 4K kernel: 1310 → 290 MB in 3.5 s, 27 reports (2 MB blocks). A second fill is counted again (1152 MB footprint, 1204 MB resident: ~50 MB of re-dirtied reusable pages go uncounted). |
| 2026-10-23 | Release safety | A 512 MB file kept its md5 across five 1 GB fill/free/report cycles; no kernel warnings. `page_reporting_order` is -1 (pageblock order: 32 MB blocks with 16K pages). |
| 2026-10-23 | Console on a tty | stdin shares a file description with stdout, which the serial attachment makes non-blocking; the stdin reader must handle EAGAIN |

## Progress log

- 2026-10-23: Phase 1 done. Repo published at https://github.com/cothis/dmx (commit e630133).
- 2026-10-23: Phase 2 started. Rust agent cross compiles on macOS and runs in the guest.
- 2026-10-23: Phase 2 done. Host and guest talk over vsock; the selftest runs entirely through the agent.
- 2026-10-23: Phase 3 started. Selftest reports the VM process's host footprint.
- 2026-10-23: Baseline at 8G down from 356 to 181 MB: no SWIOTLB, and a 16K page kernel built inside dmx.
- 2026-10-23: Found that VZ's balloon and save/restore return no host memory. Balloon controller blocked on a VMM decision.
- 2026-10-23: Maintainer decision: own VMM on Hypervisor.framework, written in Swift in DMXCore; macOS 15+; x86 images via QEMU binfmt. New phase 3; later phases renumbered.
- 2026-10-23: dmx's own VMM boots the guest to a shell on 10 vCPUs, smaller than on VZ at idle.
- 2026-10-23: virtio-mmio, console, rng and vsock on the own VMM; the selftest passes on it. Virtualization.framework removed.
- 2026-10-23: Phase 3 done. Free page reporting returns 1 GB the guest freed within 2 s; the selftest checks it.
