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
   errors with a hint, no interactive prompts, MCP tools and disposable sandboxes.

Non-goals for now: a GUI (a menu bar item may come much later), Intel Macs, Windows/Linux hosts.

## Architecture

```
dmx (CLI) ──▶ dmx daemon (launchd agent, socket activated)
                ├─ Linux VM on dmx's own VMM (Hypervisor.framework, Swift in DMXCore)
                │    guest RAM mapped by dmx; virtio-mmio: console, rng, vsock,
                │    balloon with free page reporting, mem (hotplug), blk, net, fs
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
| Own VMM on Hypervisor.framework, not Virtualization.framework (2026-10-23) | VZ never returns guest memory while the VM runs: ballooned pages stay in the host footprint, there is no free page reporting, and restore backs the whole ceiling (see Findings). With guest RAM mapped by dmx itself, dmx can release freed pages (`hv_vm_unmap` + `madvise(MADV_ZERO)`, with a REUSABLE fallback). Costs: we write the virtio devices, and lose Rosetta. Phase 1 to 2 ran on VZ. |
| The VMM is Swift, in DMXCore (2026-10-23) | One language and one binary for all host code; Hypervisor.framework is a C API Swift calls directly. Maintainer's choice over a Rust VMM process. |
| macOS 15 or later (2026-10-23) | Hypervisor.framework has an in-kernel GICv3 (`hv_gic_create`) from macOS 15, so dmx does not emulate an interrupt controller. |
| x86_64 images through QEMU user mode + binfmt, not Rosetta (2026-10-23) | Rosetta for Linux exists only inside Virtualization.framework. Most images are multi-arch; emulation is a fallback. FEX-Emu replaced QEMU as the default on 2026-10-26 (below). |
| x86_64 images through FEX-Emu with hardware TSO, QEMU as a setting (2026-10-26) | Same image matrix (9/9 amd64 either way), but FEX runs CPU-bound x86 code 2.5–9× faster than QEMU (python loop 1663 → 193 ms, 100 MB sha256 3.3× → 1.3× native, postgres workload 5.2 → 2.8 s), because the Apple CPU's TSO mode, which the guest can set through Hypervisor.framework on macOS 15, removes the barriers x86 memory ordering otherwise needs. Docker Desktop likewise defaults to Rosetta and keeps QEMU as an option: `x86_emulator` (fex, qemu). Node's slow start was fixed by capping a translated block at 150 x86 instructions (260 ms now). Costs: a static musl build of FEX with a dmx patch (no FEXServer, four glibc assumptions), Asahi Linux's out-of-tree TSO kernel patches, and +1 MB in docker.img. |
| Hardware TSO's model switches stay unoptimised (2026-10-26) | Each `ACTLR_EL1` write traps to Hypervisor.framework, so every switch between a TSO thread and a plain one costs 0.78 µs. On one vCPU an x86 program piping 80 MB to a native reader pays it 38,000 times: 69 ms against 39 ms with TSO off. With vCPUs free the same workload shows no difference (33–34 ms either way), because each process stays on its own vCPU and switches 6× less, and two x86 processes never pay it. The alternative, leaving TSO on for native threads, would slow all native code ([measurements](measurements/2026-10-26-tso-switch-and-unpack.json)). |
| selftest's idle number includes the first boot's unpack (2026-10-26) | selftest boots a fresh data disk, so /init unpacks the emulator and the pages it frees are in blocks free page reporting cannot hand back: 99 MB at boot, 85–87 MB five seconds later when the first idle sweep runs. The memory is not lost and a user's disk unpacks once per version, so the FEX number (94–100 MB) sits a few MB above the qemu-only one (88–91) in that window only. Compaction in /init does nothing there (the pages are not in the allocator's lists yet) and compaction in the idle sweep buys 0–2 MB for a 4 ms call, so neither is adopted. |
| First release choices (maintainer, 2026-10-25) | `v0.1.0`, SemVer, an ordinary GitHub release; GPL source attached to every release as `dmx-sources-<version>.tar` (3a) instead of a three-year written offer; ad-hoc signing for v0.1.0, Developer ID signing and notarization from the next release (maintainer, 2026-10-25); the name stays "dmx", described as Docker-compatible, with a trademark notice. See [release.md](release.md#decisions-maintainer-2026-10-25). |
| dmx builds its own qemu-x86_64 with a 2^47 guest base (2026-10-25) | Upstream QEMU gives a 64-bit guest any host address; on the 48-bit aarch64 guest kernel that includes addresses above x86-64's 47-bit user space, and jemalloc (Redis) crashed. A default in the binfmt interpreter covers run, exec, fork and chroots; an environment variable would leak into containers and a wrapper breaks binfmt's `F`/`O`/`C`. Same pinned source, Alpine patches and configure line, one small patch; `QEMU_GUEST_BASE` still overrides. |
| Shared-file ownership stored in a host xattr; guests see only `user.*` xattrs (2026-10-25) | virtio-fs always mounts with default_permissions, so the guest kernel checks the owner it is told: with every host file shown as root's, non-root container users could not write to bind mounts or even to directories they had just made (postgres's initdb failed). chown and non-root creations store `uid:gid` in `com.dmx.owner`, as Docker's osxfs did with `com.docker.owner`; the host still checks access as the host user. Only `user.*` xattrs pass, so the guest cannot clear `com.apple.quarantine` or plant `security.capability`. |
| Data disk flushes stay `F_BARRIERFSYNC` (maintainer, 2026-10-25) | Plain `fsync`, as Lima/Colima use, makes warm `docker run` 125 → 76 ms, but the SSD may reorder writes across a power cut and corrupt the ext4 data disk (images, volumes); with the barrier a power cut loses only the last writes. See [benchmark.md](benchmark.md#warm-docker-run-profile-2026-10-25). |
| One long lived VM, not one VM per container | One kernel's overhead instead of N. Revisit per-container VMs for sandboxes (phase 9). |
| The daemon exits when idle; the CLI starts it if launchd does not (2026-10-24) | An idle dmx should cost nothing, not even a 4 MB daemon. `dmx install` is optional: without it `dmx exec` still just works, which matters for agents. One daemon per `DMX_HOME`, enforced by a lock file. |
| Docker from a read-only image unpacked onto the data disk, started on first use (2026-10-24) | Docker is ~170 MB unpacked: in the initramfs it would sit in guest RAM. A pinned image on a read-only disk is unpacked only when its sha256 changes, and dockerd starts only when `docker.sock` is first used, so a VM nobody runs Docker in costs nothing extra. |
| Drop dmx's own mappings of guest RAM after device traffic (2026-10-24) | macOS charges a page to `ri_phys_footprint` once per mapping; guest RAM is mapped by dmx and by stage 2, so pages a device filled counted twice (1 GB read = +2 GB). Remapping dmx's view onto itself (`mach_vm_remap` overwrite) after traffic leaves one mapping; devices fault pages back in. |
| Transparent huge pages off in the guest (2026-10-24) | With 16K pages a huge page is 32 MB. `madvise` (2026-10-23) still let qemu's 128 MB code buffer take 32 MB per x86 process (`sleep` 38 MB RSS, 5.4 MB without); nothing in dmx needs huge pages. Replaces the `madvise` choice. |
| Guest network is a user space NAT inside dmx, not vmnet (2026-10-24) | vmnet needs root or `com.apple.vm.networking`, which Apple grants on request (verified: an ad-hoc process gets VMNET_FAILURE, the entitlement gets it killed). Guest flows map onto host sockets like passt: no TCP stack, no second process, bounded buffers, and traffic is dmx's own so VPNs and firewalls apply. Costs: IPv4 only, no ICMP errors; inbound goes through vsock port forwarding. |
| Guest IPv6 is a unique local prefix behind dmx's NAT (2026-10-25) | The guest cannot have the Mac's own prefix without a bridge (vmnet, which needs root). With fd64:646d:7800::/64 the guest's resolvers keep IPv4 first for names with both families (RFC 6724 label matching), so IPv6 adds IPv6-only destinations without making anything that works over IPv4 depend on the Mac's IPv6. AAAA records the Mac cannot route to are left out, as Docker Desktop does on a Mac without IPv6. |
| No host file I/O directly on guest RAM (2026-10-26) | Direct I/O (`F_NOCACHE`) between the disk image and guest pages corrupted guest memory while macOS was short of memory: zeroed page tables, stacks and lists crashed the guest kernel, and files were lost (18 of 28 fsck boots under swap, 0 of 36 after). macOS presumably moves or copies a page under a direct transfer, and the guest's stage-2 mapping then sees another page than the one it wrote once the page is compressed and comes back. virtio-blk copies through a buffer of its own (reads got faster: 0.9 → 1.8 GB/s for 1 MB reads); virtio-fs no longer passes the guest's O_DIRECT on as `F_NOCACHE`. `make pressuretest` reproduces the old bug. |
| Defaults and security follow Docker Desktop (2026-10-24) | Maintainer's rule: Docker must just work, and security choices match standard tools. So: host directories shared read-write at the same path (/Users, /Volumes, /private, /tmp, /var/folders), containers reach host services through `host.docker.internal` (`host.dmx.internal` also works), dmx port forwards bind 127.0.0.1 unless asked (Docker published ports follow their bindings), host user ↔ guest root on shares, `init_on_alloc` on as in stock kernels, no TLS tools in the base guest (dockerd does its own TLS). Port forwards persist and keep the 4 MB daemon up while they exist. MCP tools are `dmx_*`, argv-based, 8 KiB/120 s defaults. |
| No GitHub CI, no Homebrew dependency (2026-10-24) | Maintainer's choice: GitHub is only for distribution (source and releases). Checks run locally before a release (`make build`, `swift test`, selftest, daemontest, dockertest). dmx ships its own pinned Docker CLI tools instead of relying on Homebrew. |
| dmx ships the docker CLI, Compose, Buildx and the keychain credential helper (2026-10-24) | Docker Desktop does, and users should not need Homebrew. Pinned upstream darwin-arm64 builds (the static CLI is trust-on-first-download: Docker publishes no checksum for it). Plugins through `cliPluginsExtraDirs`; no shell rc files edited. All Apache-2.0. |
| Sandboxes are containers in the one VM (2026-10-24) | No state of dmx's own to clean up (labels), egress rules inside each sandbox's namespace cover every protocol. Isolation is Docker's: a guest kernel exploit reaches the whole guest and its shares; per-sandbox VMs are a possible later step for hostile code. |
| Guest memory beyond 1 GB is hotplugged with virtio-mem (2026-10-24) | The memmap (struct page) costs ~16 MB/GB with 4K pages (about 4.7 MB/GB with the earlier 16K kernel) even for unused RAM known to Linux. Plugging on demand makes the ceiling free until used. Under host pressure, unplug spare RAM first; the balloon squeezes boot RAM and blocks that cannot be removed. |
| 4K Linux pages for x86 compatibility (2026-10-25) | The image matrix exposed Python shared-library mapping and Java partial msync failures on the previous 16K kernel. A 4K control resolved them for the same image digests and QEMU. At 2 CPUs/4G, idle rose from 64–66 to 77–78 MB; virtio-mem limits the memmap cost to present RAM. Default kernel is now 6.18.58-dmx-4k. A bounded whole-free-list reporting pass replaces the upstream 1/16 budget, which took 8–10 s to return 1 GB on 4K; reporting remains idle when no pages are freed. Redis amd64 still has a separate QEMU address-layout issue (compatibility.md). |
| `dmx install` links `~/.docker/run/docker.sock` to dmx's socket, not `/var/run/docker.sock` (2026-10-27) | A user hit a tool that ignores docker contexts and tries only Docker Desktop's paths (`/var/run/docker.sock`, `~/.docker/run/docker.sock`, `~/.docker/desktop/docker.sock`). The second is in the user's home, so a symlink needs no sudo; one Docker Desktop serves stays. `/var/run` needs root (Docker Desktop's privileged helper, OrbStack's admin prompt) and dmx does not prompt, so README points those tools at `DOCKER_HOST`. |
| CLI only, no GUI | The work that matters is invisible (memory, sockets). Agents use CLIs. |
| Kernel hardening over a few MB (2026-10-24) | Maintainer's choice: `rodata=noalias` would save 4 MB at 8G (page tables of a page-by-page linear map) but leaves the linear alias of kernel text writable, so the default stays `rodata=full`. |
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

### Phase 4: Memory (done)

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
      2. [x] A custom kernel: initially 16K pages; now 4K for image compatibility (2026-10-25 decision).
         `make kernel` (`scripts/build-kernel.py`) builds kernel.org
         6.18.58 with Alpine's trimmed virt config, 48-bit VA, no debug info/BTF/module
         signing/GCC plugins, inside a dmx VM booted from the stock Alpine kernel, with a pinned
         offline toolchain (34 Alpine apks). `make guest` uses it. 8G: 291 → 181 MB.
      3. [x] Early balloon inflation: not needed for the baseline. Pages the guest never touches
         are never backed, so there is nothing to give back at boot. The balloon matters for
         memory touched and then freed, which is the balloon controller task.
- [x] Shrink the fixed part: 8G 173 → 145 MB, 2G 126 → 114 MB. Measured by host page
      (`mincore` on guest RAM) against guest `/proc/kpageflags`. Now default kernel args:
      fixed dentry/inode/TCP hash sizes (−15 MB; the kernel sized them to the ceiling), free page
      reporting from order 5 (512 KB), per-CPU free lists capped at ~1 MB per vCPU (they could hold
      38 MB each, unreported). The dmx guest drops apk and OpenSSL from the initramfs (−6 MB of
      shmem; the `make kernel` bootstrap guest keeps them). What is left at 145 MB: guest pages
      121 MB (memmap 32, kernel image 29, slab 23, unattributed page allocations 20, reserved
      other 7, shmem 5), dmx's own memory 5 MB, and ~24 MB that `ri_phys_footprint` charges to
      the process but that is neither a guest page nor a dmx region (see Findings).
- [x] dmx's own memory when streaming: 100 MB of guest stdout through `dmx boot --` peaked at
      349 MB and left 90 MB behind. Two causes: each vsock connection queued bytes in a `Data`
      whose `removeFirst` keeps the consumed front allocated, so it grew by everything that
      passed (500 MB streamed: 637 MB); and exec output went into an unbounded
      `AsyncThrowingStream`. Now a `ByteQueue` that reuses consumed space, and exec output is
      read from the socket only as the caller consumes it, so the guest waits on vsock credit.
      500 MB out: peak 157 MB (idle 145). 500 MB in: peak 151 MB.
- [x] Memmap scales with the ceiling: the guest boots with 1 GB and our virtio-mem device
      (`HV/VirtioMem.swift`, policy `HV/MemoryPlugPolicy.swift`) plugs the rest of the ceiling in
      32 MB blocks as needed, from the balloon's stats queue: keep 1 GB available plus 0.5 s of
      current growth, unplug after 5 s with more than 1.5 GB available (was 30 s before 4K
      memmap costs made it miss the 10 s return goal); poll at least once per second during that
      countdown. The guest onlines plugged
      memory as movable (`memhp_default_state=online`, `online_policy=auto-movable`). Idle footprint
      ~80 MB on the earlier 16K kernel at any ceiling. `CONFIG_VIRTIO_MEM` is built in on the
      current 4K kernel; it no longer needs a module.
- [x] Each vCPU costs ~2.3 MB of guest memory at idle (1 vCPU 125 MB, 10: 147 at 8G before the
      kernel trim). `slub_max_order=1` (default now) took 10 vCPUs to 141 MB. Taking 9 vCPUs
      offline at idle gives back only 2 to 5 MB (121 → 116 to 119 MB with the trimmed kernel):
      per-CPU areas and parked kthreads stay. Not worth an idle policy. Trying it found that a
      vCPU turned off and on again crashed the guest (fixed, and the selftest checks it).
- [x] Trim the kernel config to what dmx and Docker need (`CONFIG` in `scripts/build-kernel.py`,
      checked after olddefconfig by `MUST`; `--config-only` writes the resulting .config in ~30 s).
      Built in: virtio-mmio, balloon, vsock, rng, blk, net, fs, ext4, overlay, zram. Out: ACPI,
      EFI, PCI, NUMA, 32-bit user space, other platforms, real hardware, KVM, sleep, kexec, audit,
      IMA, KFENCE; NR_CPUS 4096 → 64; THP default madvise. Built-in symbols 1579 → 1179, modules
      894 → 653. Build 2 h 21 min → 19 min. 8G 141 → 120 MB, 2G 109 → 87 MB, agent up in 140 to
      180 ms. Netfilter, bridge, veth, overlay, namespaces and all cgroup v2 controllers still work.
- [x] Memory controller in the daemon (`Daemon/MemoryController.swift`, [daemon-protocol.md](daemon-protocol.md)):
      host pressure from `DispatchSource.makeMemoryPressureSource`. Normal: after 30 s with no exec
      and the guest under 5 % of a CPU, trim clean page cache to 16 MB (`memory.reclaim` with
      swappiness 0). Warning: trim at once, then after 5 s idle. Critical: also push cold anonymous
      and tmpfs pages to zram and reduce free headroom to 256 MB; unplug spare RAM before using
      the balloon for boot RAM and blocks that cannot be removed. After critical, warning
      restores 1 GB headroom; normal restores the usual policy and deflates the balloon.
      `dmx status` shows a `memory` object; actions are logged with `memory:`.
- [x] Guest policy: zram swap (lz4, a quarter of the ceiling) turned on by the agent the first time
      the guest is squeezed or passes half its ceiling (its empty metadata costs memory;
      the earlier 16K measurement was ~3.5 MB for 2G swap);
      `vm.swappiness=100` and `vm.page-cluster=0` with it. Transparent huge pages off (`never`; was `madvise` until qemu's code buffer took 32 MB per x86 process).
      `init_on_alloc` stays on: on dmx's VMM inflating costs CPU (~1.5 s for 7.8 GB), not memory.
- [x] Freed guest blocks under 512 KB (after connection bursts, small-file work): when idle, the
      controller lowers free page reporting to 16 KB (order 2 at 4K, order 0 at 16K) and has every
      slab cache free its empty slabs (agent `reporting_order`, `shrink_slabs`); 512 KB reporting
      returns on the next use (order 7 at 4K, order 5 at 16K).
      Footprint returns to idle + 1 to 6 MB; idle CPU unchanged. ~10 MB after network traffic stays
      (probably virtio-net rx buffers).
- [x] Host pressure drives the controller above. `memory_pressure -S` needs root, so tests use the
      daemon's `simulate_pressure` method.
- [x] Expose virtio-mem state in `dmx status` (text and JSON, also MCP): `memory.plug` has boot,
      requested and plugged MB and plug/unplug request counts. Requested/plugged cover only the
      added region; present RAM is boot + plugged, independent of the configured ceiling.
- [x] Coordinate hotplug and pressure: remove spare RAM immediately at critical (no normal delay),
      leaving 256 MB plus growth-rate headroom. Keep the balloon deflated during unplug progress;
      after 5 s without progress, use it for blocks that remain. Boot-only guests retain the
      balloon fallback. `make daemontest` verifies growth, removal, allocations under critical,
      warning/normal recovery and the no-hotplug fallback on the real VM.

Done when: idle VM host footprint is under 150 MB at an 8 GB ceiling, and after a container that
uses 2 GB exits, footprint falls back within 10 s. Numbers recorded in the log.

### Phase 5: Daemon and lifecycle (done)

- [x] `dmx daemon` (`Sources/DMXCore/Daemon`): owns the VM, control socket `~/.dmx/dmx.sock`
      speaking the agent protocol's framing ([daemon-protocol.md](daemon-protocol.md)), errors with
      the CLI's codes. An exec is relayed byte for byte between the client and the agent. One
      daemon per `DMX_HOME` (flock); without launchd, `start`/`exec`/`shell` spawn it detached
      when nothing answers, so dmx works without installing anything. `Machine` now waits for its
      vCPU threads and destroys the VM on stop, so one process can boot again after a stop.
- [x] launchd user agent with socket activation (`dmx install` / `dmx uninstall`, label
      `io.github.cothis.dmx`, `ThrottleInterval` 1, `ProcessType` Interactive). Install asks a
      CLI-started daemon to quit first; uninstall's SIGTERM powers the guest off cleanly.
- [x] `dmx start`, `dmx stop`, `dmx status --json` (state, uptime, cpus, ceiling, guest used, host
      footprint, clients, execs, idle timeout and time left). `containers` is null until phase 7.
- [x] Idle stop: no connection that used the VM for `idle_timeout` (default 5 min) → power off
      through the agent; VM stopped and no client for 10 s → the daemon exits; the next
      connection starts one. `status` calls do not count as use. No snapshots: a cold boot is
      0.15 to 0.25 s, so restoring one has nothing to win.
- [x] `dmx exec [-t] [-e K=V] [-w dir] -- cmd` and `dmx shell` through the daemon and agent:
      stdin, exit status, pty with window size changes, SIGINT/SIGTERM/SIGHUP passed on, and a
      killed client kills its guest process. Fixed on the way: every guest process started with
      SIGINT and SIGQUIT ignored (inherited from `/init`'s background subshell), so Ctrl-C did
      nothing; the agent now resets signal dispositions before exec.
- [x] `dmx config get/set/unset` (cpus, memory, idle_timeout) stored in `~/.dmx/config.json`,
      read at each boot.
- [x] `make daemontest` (`scripts/test-daemon.py`): all of the above on the real VM in a
      throwaway `DMX_HOME`, about 45 s.

Done when: after `dmx install`, connecting to the socket boots the VM, and an idle VM disappears and its processes exit.
Result: verified with launchd and without; see Findings for timings and memory.

### Phase 6: Storage, network, file sharing (done)

- [x] Data disk: `$DMX_HOME/data.img` (sparse, `disk_size` default 64G, applies at creation) on our
      virtio-blk (`HV/VirtioBlock.swift`: `F_NOCACHE` through a bounce buffer, never direct I/O on
      guest pages (2026-10-26, see Decisions), flush = `F_BARRIERFSYNC`, discard and
      write-zeroes punch holes, requests off the vCPU thread, image locked against a second VM).
      `/init` formats a blank disk with pinned e2fsprogs (deleted after mount), ext4 at /var/lib
      with discard; the agent freezes it before power-off. Checked at every boot (e2fsck -p, then -fy
      if that cannot repair it; 2026-10-25), and grown when `disk_size` is raised. The idle sweep
      also trims it (FITRIM, 2026-10-27): online discard misses blocks freed by a journal replay
      or e2fsck, or whose discard a killed VM lost, and one Mac's data.img held 5.9 GB for 260 MB
      of data until a manual fstrim.
- [x] Network: our virtio-net (MTU 65520, mergeable rx buffers, no checksums) with a passt-like
      user space NAT in dmx ([network.md](network.md)): guest TCP/UDP/ICMP echo flows mapped onto
      host sockets, no TCP stack of our own; DNS on the gateway forwarded to the host's first
      nameserver; static guest config 192.168.127.2, gateway .1, `host.dmx.internal` =
      192.168.127.254 = host loopback. HTTP from the internet works. HTTPS in the guest needs
      OpenSSL and the CA bundle (+12 MB idle), not adopted. Left: IPv6, ICMP errors, split DNS.
- [x] Port forwarding: `dmx port add/rm/ls` ([daemon-protocol.md](daemon-protocol.md)): a daemon
      listener (127.0.0.1 unless given) → a vsock stream per connection → agent `connect` to the
      guest's loopback. Saved in `$DMX_HOME/ports.json`; while forwards exist the daemon stays up
      (4 MB with the VM stopped) and the first connection boots the VM; open connections count as
      use. Half close both ways (vsock now answers host EOF with SHUTDOWN, not RST). Callable from
      code for phase 7. Found on the way: two exec data-loss bugs (agent sent `exit` before output
      stuck behind a slow host; the relay discarded a finished peer's output when a write failed).
- [x] Our virtio-fs device (`HV/VirtioFS.swift`, FUSE server `HV/FUSEServer.swift`): `shares` config
      (default `~` read-write; `path:ro`, `none`) mounted at the same path by `/init`. Containment:
      every lookup is relative to the share root's descriptor with `O_NOFOLLOW_ANY`, host symlinks
      are returned as links, never followed; read-only enforced on the host; setuid/setgid dropped.
      Host user ↔ guest root, others nobody, unless an owner is stored (below). 1 s attribute cache
      (like virtiofsd cache=auto) plus a re-lookup when opening a file the host changed. `make test`
      covers hostile requests. Left: ACLs, DAX.

Done when: the guest can `wget` from the internet, a guest web server is reachable on `localhost`, and a host directory is readable/writable in the guest.

Follow-ups beyond the completed acceptance criteria:

- [x] Storage: fsck at boot (2026-10-25): `e2fsck -p`, and `e2fsck -fy` when preen mode cannot
      repair the disk; output kept in `/var/lib/dmx/log/fsck.log` unless the disk was clean;
      `broken_system_clock` because the guest has no real-time clock until the host sets it.
- [x] Storage: growing the data disk (2026-10-25): a raised `disk_size` grows `data.img`
      (sparse `ftruncate`) before the next boot, and the agent grows ext4 online
      (`EXT4_IOC_RESIZE_FS`) before it answers the host. A smaller `disk_size` is ignored with a
      log line: disks do not shrink.
- [x] Network: split DNS (2026-10-25): guest DNS over UDP is answered by macOS's resolver
      (`DNSServiceQueryRecord`, `HostDNS.swift`): VPN per-domain servers, `.local` names, network
      changes. Missing names get an empty NOERROR (mDNSResponder does not tell them apart).
- [x] Network: IPv6 (2026-10-25): the guest has fd64:646d:7800::2/64 next to its IPv4 address;
      the gateway answers neighbor solicitations and ping on ::1, DNS on ::1 port 53, and ::254 is
      the Mac's ::1. TCP, UDP and ICMPv6 echo map onto the Mac's IPv6 sockets. AAAA records the
      Mac has no route to are left out. dockerd keeps Docker's default `ip6tables` (no longer
      forced off), so `docker network create --ipv6` networks reach out through NAT66.
- [x] Network: ICMP errors to the guest (2026-10-25): destination unreachable when the Mac
      cannot reach a TCP or UDP destination (network, host, prohibited) or a UDP port is closed,
      so connects fail with the real reason and UDP clients do not wait. Time exceeded and
      packet too big are not generated (see network.md).
- [x] Port forwarding on the Mac's IPv6 too (2026-10-25): `-p 8080:80` listens on `::` as well as
      0.0.0.0, and 127.0.0.1 forwards (`dmx port add`'s default) on ::1, as Docker Desktop does;
      TCP and UDP. The IPv6 socket is best effort (logged if taken).
- [x] File sharing: Unix sockets, xattrs and stored ownership (2026-10-25). A guest `bind()` in a
      share leaves a host socket file (bound with `pthread_fchdir_np`, as macOS has no bindat) and
      guest programs connect through the guest kernel. `user.*` xattrs only, stored under the same
      names; host namespaces (quarantine, provenance) stay hidden and unchangeable. chown by guest
      root, and files a non-root guest user creates, store `uid:gid` in the host xattr
      `com.dmx.owner`; virtio-fs mounts with default_permissions, so this is what lets a non-root
      container user write to a bind mount it was given (postgres's data directory). Owner reads
      are cached per node by ctime. FUSE 7.33 with `HANDLE_KILLPRIV_V2`: dmx clears setuid/setgid
      on write, truncate and chown, and the guest stops asking for `security.capability` before
      every write.
- [x] The Mac's SSH agent in containers (2026-10-25), as on Docker Desktop: the agent listens on
      `/run/host-services/ssh-auth.sock` (0666) and opens a vsock stream to host port 1025 per
      connection; the vsock device now accepts guest-initiated connections on ports the host
      listens on (`VirtioVsock.listen`, `HostServices.swift`). The host side uses the daemon's
      `SSH_AUTH_SOCK`, else launchd's, else macOS's own `com.openssh.ssh-agent` socket.
- [ ] File sharing: ACLs and DAX; other host Unix sockets reachable from containers.

### Phase 7: Docker compatibility (done)

- [x] dockerd 29.9.2, containerd 2.3.7, runc 1.4.3, tini, iptables (nf_tables), libseccomp and the CA
      bundle from pinned Alpine apks in `docker.img` ([docker.md](docker.md)): a read-only virtio-blk
      disk (header + gzip'd tar, 52 MB) that `guest/docker` unpacks onto the data disk when its
      sha256 changes; the initramfs grows by 3 KB. dockerd starts on the first `docker.sock`
      connection after a boot (agent `docker_start`), in its own mount namespace on a
      switch_root-style root so runc keeps `pivot_root`. Running containers and open Docker
      connections count as use; `containers` in `dmx status`.
- [x] `~/.dmx/docker.sock` (0600) forwarded to the guest's `/var/run/docker.sock` over vsock (agent
      `connect` takes a Unix path); a second launchd socket `Docker` activates the daemon.
- [x] `dmx install` creates and selects a `docker context` named `dmx`; `dmx uninstall` removes it.
- [x] Published ports follow Docker's start/die events like Docker Desktop: `-p 8080:80` on 0.0.0.0,
      `-p 127.0.0.1:...` on loopback; shown as `(docker)` in `dmx port ls`, never persisted.
      UDP published ports too (one vsock stream per peer, datagrams framed). A taken host port fails
      `docker run`/`compose up` with Docker Desktop's error: every docker.sock connection goes through
      a proxy (`DockerProxy.swift`) that takes the ports before dockerd starts the container.
- [x] Bind mounts through virtio-fs; default shares are Docker Desktop's (`/Users`, `/Volumes`,
      `/private`; dockerd sees `/tmp` and `/var/folders` as the Mac's). `host.docker.internal` and
      `gateway.docker.internal` answered by the NAT's DNS; `host-gateway` is the Mac.
- [x] x86_64 binaries through QEMU user mode: a static `qemu-x86_64` 11.0.3 (since 2026-10-25 built
      by `make qemu` from pinned source like Alpine's, plus a guest-base patch) registered with binfmt_misc, flags `POCF` (Docker Desktop uses `CF`; `P` keeps
      argv[0]). Carried at the end of docker.img and unpacked onto the data disk on first boot
      or a version change, so qemu uses guest RAM only while x86 code runs (initramfs 3.1 → 2.1 MB).
      The current 4K kernel restores partial-page mappings, msync, zeroing and guard-page
      semantics; `make x86test` now requires the 4K probes to pass. The 16K limitations remain
      in Findings as historical measurements. x86_64 programs only see addresses below 2^47, which
      jemalloc needs ([compatibility.md](compatibility.md)).
- [x] `make dockertest` (`scripts/test-docker.py`, 57 checks in the current run): hello-world, `run -it`, BuildKit,
      compose with a volume, published TCP/UDP ports and a bind mount, taken-port errors, restart
      policies, amd64, idle stop with Docker and the context, using only dmx's bundled tools.

Done when: the test suite passes with the stock `docker` CLI.
Result: passes with dmx's docker 29.9.2, Compose 5.6.1 and Buildx 0.38.1. Containers with a restart policy
come back at boot (agent `docker_autostart` reads dockerd's records; no dockerd otherwise); dmx
does not start at login, so after a Mac reboot they wait for the VM to boot. `docker build` uses
BuildKit through dmx's Buildx; the deprecated legacy builder remains available through Docker's
`DOCKER_BUILDKIT=0` setting.

### Phase 8: Own runtime

- [ ] OCI image pull and unpack (registry auth, layers, content store) in Rust.
- [ ] overlayfs snapshotter.
- [ ] Container runtime: namespaces, cgroups v2, seccomp, capabilities (study youki/runc).
- [ ] Serve a subset of the Docker Engine API from dmx itself; replace dockerd piece by piece while the phase 7 suite keeps passing.

### Phase 9: AI native (done)

- [x] `dmx mcp` (`Sources/DMXCore/MCP`, [mcp.md](mcp.md)): stdio JSON-RPC serving MCP 2026-07-28
      (`server/discover`, per-request `_meta`) and the `initialize` revisions 2024-11-05 to
      2025-11-25. Tools `dmx_exec`, `dmx_status`, `dmx_start`, `dmx_stop`, `dmx_config_get`,
      `dmx_config_set`. One daemon connection per call, so idle stop still works. `make mcptest`.
      Sandbox and logs tools are implemented below.
- [x] Sandboxes ([sandbox.md](sandbox.md)): containers in the guest with a policy: network none / all /
      IPv4 allowlist (iptables in the sandbox's own network namespace, `NET_RAW` dropped), host paths
      read-only unless granted and only under the shares, cpu/memory/pids limits, TTL enforced by
      the daemon's `SandboxReaper` even after the client left. State lives in container labels.
      CLI `dmx sandbox …`, MCP `dmx_sandbox_*`, `make sandboxtest`. Isolation is Docker's.
- [x] Checkpoints: `docker commit` (filesystem only); rollback and fork from a checkpoint or the
      current state.
- [x] Output limits: head and tail per stream (default 8 KiB, at most 1 MiB), cut on UTF-8
      boundaries, with a marker giving the bytes left out and totals; bounded memory while reading.
      Timeout and cancellation kill the guest process group. `dmx_logs` reads container logs with
      the same caps and a pattern-based summary (counts, first and last error-looking lines).

### Phase 10: Release

- [x] `make install`: copies dmx to `~/.local/bin` (`PREFIX` to change), no sudo, and repoints the
      launchd agent if it is installed. Building from source still needs Xcode, Python and Rust.
- [x] `dmx tools install` (also part of `dmx install`): the docker CLI 29.9.2, Compose 5.6.1, Buildx
      0.38.1 and the keychain credential helper from upstream, pinned by sha256, in `~/.dmx/bin` and
      `~/.dmx/cli-plugins` (through `cliPluginsExtraDirs`, as Docker Desktop does), `docker` linked
      into `~/.local/bin` when that is on PATH. `docker build` uses BuildKit. No Homebrew.
- [x] Guest downloaded and verified by dmx (`GuestStore`): `dmx-guest-<v>.tar.gz` from
      `<base>/<tag>/` (`DMX_RELEASE_URL`, default the GitHub releases) when the guest is missing or
      from another release, checked against sha256s compiled in (`GuestPin.swift`). A local
      `make guest` build is left alone. `dmx guest [fetch]`; doctor reports the guest's origin.
- [x] `make release VERSION=x` (`scripts/release.py`, [release.md](release.md)): binary tarball, guest
      archive, SHA256SUMS, kernel config, third-party list with licenses, `install.sh` with the
      version and sha256 baked in (installs to `~/.local/bin`, no sudo, no Homebrew).
- [x] Digest-pinned popular-image matrix on arm64/amd64 ([compatibility.md](compatibility.md),
      `make imagetest`): nine images, real SQL/WAL, HTTP, persistence, Java/JIT and mmap work.
      16K control 15/18; 4K control 17/18. Python and Java failures resolved by 4K pages.
- [x] Default-layout amd64 Redis allocator failure fixed: dmx builds qemu-x86_64 (`make qemu`,
      pinned QEMU 11.0.3, Alpine's patches and configure line) with a 2^47 x86_64 guest base, so
      guest addresses stay in x86-64's 47-bit user space. Default matrix 18/18 without any
      setting; `make x86test` checks the address range (with an upstream-layout control) and
      Python with jemalloc and mimalloc preloaded.
- [x] Comparison with Docker Desktop 4.96.3, OrbStack 2.2.5 and Colima 0.10.3 at 2 CPUs/4 GiB,
      three alternating rounds, host load 2–6 ([benchmark.md](benchmark.md#results-2026-10-25)):
      idle 180 / 528 / 1097 / 1176 MB (dmx / OrbStack / Colima / Docker Desktop); after freeing
      2 GiB dmx and OrbStack return within seconds, the VZ engines keep it. dmx's warm `docker run`
      (118 ms) trails Colima (73) and Docker Desktop (99). Quiet-Mac rerun 2026-10-26
      ([benchmark.md](benchmark.md#results-2026-10-26-quiet-mac)): idle 198 / 530 / 1093 / 1053 MB,
      the same picture with narrow ranges; `docker run` 101 / 95 / 52 / 67 ms.
- [x] dmx's idle CPU, 1.4 % of one core at 2 CPUs (other engines 0.4–0.6 %): the idle trim
      repeated every 5 s, because `memory.reclaim` took dockerd's and containerd's file pages,
      which they read back. Trimming once per idle spell: 0.57 % (benchmark, three runs).
- [x] An idle footprint that reads ~100 MB higher in some runs (2026-10-26): the reading fell
      before the idle trim, which takes ~70 MB back 30 s after the last activity. `benchmark.py`
      samples the whole idle window now (floor and steady state), so the number cannot land on
      the edge of the trim again.
- [x] 32-bit x86 images (2026-10-26): `linux/386` runs under FEX. `/init` registers a second
      binfmt entry for `EM_386` with FEX, and dmx's patch makes the page a 32-bit program enters
      the kernel through executable. Image matrix 24/24 across arm64, amd64 and 386.
- [x] x86_64 images faster than QEMU (maintainer, 2026-10-26): FEX-Emu (FEX-2610, MIT) is the
      default binfmt handler, built by `make fex` as a static musl PIE from pinned sources with a
      dmx patch; the guest kernel carries Asahi's `PR_SET_MEM_MODEL` patches, so FEX runs x86
      code with the CPU's TSO mode instead of barriers. QEMU stays as `x86_emulator qemu`. x86test
      runs both (36/36): sha256 1.3× native (QEMU 3.3×), python loop 8.6× faster. Image matrix
      amd64 9/9 with each ([compatibility.md](compatibility.md#amd64-through-fex-emu-2026-10-26)).
- [x] Node started slower under FEX (2026-10-26): multiblock compiled superblocks of up to 5000
      x86 instructions out of code that runs once. A translated block now holds 150, so
      `node -e 0` takes 260 ms against QEMU's 386 and nothing measured got slower.
- [x] Release decisions (2026-10-25): `v0.1.0`, attached sources, ad-hoc signing, name "dmx".
      `release.py` builds `dmx-sources-<version>.tar` (467 MiB, byte-identical for the same
      inputs): aports directories and sha512-checked distfiles of all 21 Alpine source packages,
      kernel and QEMU tarballs, patches, config and recipes. No written offer.
- [x] First public release [v0.1.0](https://github.com/cothis/dmx/releases/tag/v0.1.0)
      (2026-10-25): binary, guest archive and source bundle on GitHub Releases, downloaded and
      verified by `dmx`, so users need no Xcode, Python or Rust. Verified from GitHub: all assets
      match SHA256SUMS; `curl … | sh` installs 0.1.0 without quarantine; a fresh `DMX_HOME`
      fetched the guest in 5.4 s and passed the selftest (idle 90 MB). dmx stays Apache-2.0: the
      GPL programs run as separate programs in the guest.
- [x] Profiled warm `docker run` (118 ms vs Colima 73): the gap is the data disk's ~80 flushes per
      run (bolt DB fdatasyncs in containerd and dockerd), each an `F_BARRIERFSYNC`. Plain `fsync`
      matches Colima (75–78 ms) but loses write ordering on a power cut; kept the barrier
      (maintainer). Found on the way: dockerd ran in the root cgroup, so every `--memory` warned
      "no swap limit support" and swap stayed unlimited; dockerd now has its own cgroup.
- [x] Release [v0.2.0](https://github.com/cothis/dmx/releases/tag/v0.2.0) (2026-10-25): the first signed and
      notarized one, with phase 11. Verified from GitHub: assets match SHA256SUMS, `curl … | sh`
      installs a notarized 0.2.0, a fresh `DMX_HOME` fetched the v0.2.0 guest and passed the
      selftest (91 MB).
- [x] Release [v0.2.1](https://github.com/cothis/dmx/releases/tag/v0.2.1) (2026-10-25): shared-file
      sockets, xattrs and ownership, the Mac's SSH agent, DNS through macOS's resolver, boot-time
      e2fsck, disk growth. Verified from GitHub: assets match SHA256SUMS (sources by size),
      `curl … | sh` installs a notarized 0.2.1, a fresh `DMX_HOME` fetched the v0.2.1 guest and
      passed the selftest (96 MB).
- [x] Developer ID signing and notarization (2026-10-25, applies from the next release): `release.py`
      signs a copy with "Developer ID Application: MINHO YUN (V4YA23448U)", hardened runtime and
      secure timestamp, and submits it to `notarytool`; settings live in `~/.dmx-signing/release.json`.
      The hardened-runtime binary passes the selftest and daemontest.

- [x] Pre-announcement review (2026-10-27): fixed FUSE handle lifetime and read-only mutation,
      virtqueue address overflow, malformed sandbox CIDRs, signed-size and MCP TTL conversion
      crashes; ten unit regressions and six additional MCP/sandbox checks. Updated public docs
      and the handoff. Full results in [review-2026-10-27.md](review-2026-10-27.md).
      Fixes are on main, pending a patch release; this does not mark the announcement complete.

### Phase 11: Work Macs

Company Macs differ from personal ones: proxies, TLS inspection, internal registries and
mirrors, managed software policies, and an open-source review before adoption.

- [x] README for users and reviewers (comparison, quick start, "Using dmx at work": licensing,
      what dmx contacts, data, security model, signing, known gaps, uninstalling), `SECURITY.md`
      with GitHub private vulnerability reporting (enabled 2026-10-25), repository topics.
- [x] The user's Docker Engine settings (`registry-mirrors`, `insecure-registries`, `proxies`,
      ...) from `~/.docker/daemon.json` (`$DOCKER_CONFIG`), where Docker Desktop keeps them,
      merged under dmx's keys (`DockerEngineConfig.swift`) and passed with agent `docker_start`;
      keys dmx owns are ignored with a log line, an invalid file fails the client with
      `docker_config_invalid`. dockertest checks both.
- [x] HTTP(S) proxy: the Mac's system proxy (`CFNetworkCopySystemProxySettings`) becomes dockerd's
      `proxies` unless daemon.json sets them; a loopback proxy is given as 192.168.127.254; the
      Mac's exceptions join `no-proxy` in Go's syntax. PAC files and proxy passwords: not yet.
- [x] Certificates with trust settings in the keychain's admin/user domains, plus
      `$DMX_HOME/ca-certificates.pem`, appended to dockerd's CA bundle (`HostCertificates.swift`).
- [x] Mirrors for dmx's own downloads: settings `release_url` (the guest, GitHub's layout) and
      `tools_url` (the docker CLI tools under their upstream file names), so they also reach a
      launchd-started daemon; `DMX_RELEASE_URL`/`DMX_TOOLS_URL` override them. Downloads are still
      checked against the pinned sha256; `dmx tools ls --json` lists each URL for whoever fills the
      mirror.
- [x] Developer ID signing and notarization (phase 10), so managed Macs that allow only
      notarized software can run dmx; first signed binary ships with the next release.

Done when: on a Mac whose only way out is an HTTP proxy (no authentication) with TLS inspection,
`docker pull` and `docker build` work after `dmx install`, with no file edited by hand.

### Later, maybe

- macOS-native mode without a VM: sandbox profiles + APFS clones to isolate macOS programs (cannot run Linux images; weaker isolation).

## Next up

For a new session told only "이어서 진행해", first read [HANDOFF.md](HANDOFF.md).

**v0.3.4 is published** (signed and notarized, 2026-10-27; all 14 assets checked after download,
fresh installation and update from 0.3.3 verified with running-VM/data preservation). It ships
the pre-announcement review fixes and the FEX signal/Java fixes. It also includes `dmx update`,
and [WORKORDER.md](WORKORDER.md) — the maintainer's bugs-and-regressions list — is finished:
B1 `AT_SECURE` for setuid x86 programs, B2 FEX without `/proc`, B3 the three unrun checks (which
found a broken `make release`), R1 node's slow start (256 ms in the final 0.3.4 suite, faster than QEMU), R2 FEX's
extra memory (gone with R1), R3 the TSO switch cost (0.78 µs, invisible unless vCPUs are
oversubscribed: accepted), R4 the first-boot unpack (returned by the first idle sweep: accepted),
O1 the ~100 MB high idle readings (measurements taken before the idle trim; the harness now
samples the window), I1 32-bit x86 images and I2 Cephes' exact licence terms. The four-engine
comparison was re-measured with 0.3.0 and README and benchmark.md carry those numbers.

The 2026-10-27 pre-announcement review found additional host/guest boundary and invalid-input
bugs in 0.3.3. They are fixed and shipped in 0.3.4, with regression tests; see
[review-2026-10-27.md](review-2026-10-27.md). The maintainer authorized releasing them after
finishing the documentation (2026-10-27). Release qualification exposed an intermittent amd64 Java crash
with FEX: 39/40 passes on both the candidate and published 0.3.3; QEMU passed 20/20.
The maintainer chose to fix Java before releasing (2026-10-27). The final `fex-2610-dmx9`
guest restores signal-return state and snapshots aligned instruction words during decoding.
It passed the 100-run Java gate and all release suites; the decoder-only candidate passed
150/150. See [the diagnosis and controls](fex-java-2026-10-27.md) and
[release measurements](measurements/2026-10-27-release-0.3.4.json). The published guest was also
verified to load dmx9 after an update, preserving the existing data disk.

The follow-up investigation (2026-10-27) confirmed the Java cause: the crash reports' registers
and fault addresses are exactly what a decode mixing HotSpot's old and new method-entry bytes
produces, and a new fixture fails 18/20 on the old FEX and passes on dmx9. It also found stale
translations: code rewritten while a block was being translated kept running after the new
bytes were published, on every FEX build including the shipped dmx9. `fex-2610-dmx11` fixes it
without slowing compiles (dmx10, the first fix, cost 19 % in a compile storm) and ships in v0.3.5.
**v0.3.5 is published** (2026-10-27, signed and notarized, tag commit `610c3c5`): all 14 assets
checked after download, fresh installation and an update from a running 0.3.4 verified (VM and
data kept, dmx11 loaded at the next boot), arm64/amd64/386 containers ran.
**v0.3.6 is published** (2026-10-27, tag commit `14d7866`): the idle sweep also trims the data
disk. Same checks as 0.3.5, from a running 0.3.5, plus an idle trim in the updated VM.
**v0.3.7 is published** (2026-10-27, tag commit `b4f9da0`): a dangling `docker` link is replaced,
README documents signing. Same checks from a running 0.3.6 (unchanged guest kept, not
downloaded again), plus the published binary replacing a dangling link in a throwaway HOME. See [the follow-up](fex-java-2026-10-27.md#follow-up-cause-confirmed-and-a-second-defect-2026-10-27).
**v0.3.8 is published** (2026-10-27, tag commit `7f32e3f`): `dmx install` waits for launchd.
Same published checks from a running 0.3.7, and the published binary installed 5/5 with the VM up
(0.3.7: 5/10).
**v0.3.9 is published** (2026-10-27, tag commit `1051460`): guest MTU 49126 against the receive
deadlock. Same published checks from a running 0.3.8, and the published binary started 300 fresh
VMs with a download each without a stall (0.3.8: 3 in 300).
**v0.3.10 is published** (2026-10-27, tag commit `aa061fc`): `dmx install` links
`~/.docker/run/docker.sock` to dmx's socket. Same published checks from a running 0.3.9, plus
the published binary's `dmx install` creating the link on a free path and over a dangling one.
Found while verifying, not new in 0.3.10: when the boot files were unchanged, a boot never
rewrote the guest receipt (`release.json`), so `dmx guest` on this Mac named v0.3.6 under 0.3.10.
Fixed on main after the release (`GuestStore.ensure` now also runs `fetch` for a renamed
release, which downloads nothing and records the tag); not released yet.

In order:

1. Measure Apple's `container` (and a Container Machine) with the engine comparison's protocol
   when the Mac is quiet (maintainer, 2026-10-27: worth adding, not now). It runs on
   Virtualization.framework and its docs give a machine half the host's memory by default; HN's
   Container Machines thread (1269 points) argued about exactly this. Install Apple's signed
   package, record idle, 2 GiB held/returned, `docker run` equivalent, then uninstall and undo
   what it changed (see docs/memory.md). The announcement drafts say it was not measured yet.
2. Community announcement (Show HN, Reddit, GeekNews) is now the maintainer’s next decision.
   The requested review, documentation and v0.3.4 release are complete; no community post was
   sent by this release work.
3. Phase 11's acceptance on a real corporate network (inspecting proxy), when one is at hand.
4. Open, not blocking: `qemu-x86_64` cannot run 32-bit programs, so `linux/386` needs
   `x86_emulator fex` (the default); adding qemu-i386 would be a separate build. Warm `docker run`
   (~100 ms on a quiet Mac) stays behind Colima by choice (data disk barrier flushes, see
   Decisions). FEX's emulated `uname -m` says `x86_64` even for a 32-bit process.

Phase 8 (own runtime) remains unstarted; Docker uses dockerd/containerd/runc. Storage, network and
sharing extensions are tracked under phase 6. None is silently marked complete by the finished
acceptance suites.

## Findings and measurements

### v0.3.4 qualification (2026-10-27)

The final FEX guest passed unit 59, selftest 23, daemon 57, MCP 33, x86 49, Docker 69, sandbox
44, image matrix 24 and repeated amd64 Java 100. Idle footprint was 97 MiB (before: 95);
reclaim was 1125 → 105 MiB in 105 ms (before: 1123 → 102 in 320 ms). These are local samples,
not a fresh cross-engine comparison. The old FEX failed one in 40 Java runs on both host versions;
the signal-only fix still failed one in 100, while the decoder-only candidate passed 150/150.
Early experiments that packaged the wrong emulator are classified as baseline, not candidate
proof. Full artifact hashes, commands and evidence limits are in
[the release measurements](measurements/2026-10-27-release-0.3.4.json).

Publication: 14 uploaded assets matched their local hashes and were downloaded and checked again.
The installer fetched the signed/notarized binary, and its guest selftest passed (97 MiB idle).
Updating a running 0.3.3
kept the old VM alive, retained its data, then loaded the new guest/FEX at the next boot. The
published binary ran arm64, amd64 and 386 containers. Tag: `v0.3.4`, commit: `04ef90d`.

### FEX code patching (2026-10-27, after v0.3.4)

The six Java crash reports are reproduced byte for byte by decoding the first one or two bytes of
HotSpot's verified-entry word from the old version and the rest from the patched `jmp`. That
includes three fault addresses, a register truncated by the mixed `mov ebx, edi`, and the
SIGILL/#GP offsets. `entry-patch` fixture, 20 runs each: dmx8 2/20, signal-only 2/20,
decoder-only 20/20, dmx9 20/20, dmx10 20/20, QEMU 20/20. `code-stale` fixture: dmx9 0/20 and dmx8
0/10 (every run still executed an old version), QEMU 30/30, dmx10 20/20 and the candidate 15/15.
dmx10 suites: selftest (idle 96 MiB, reclaim 1121 → 102 MiB in 217 ms; dmx9: 97, 1125 → 105 in
105 ms), x86 53/53 (node 256 ms, python loop 193 ms, both unchanged), image matrix 24/24, Java 100/100 with javac's
median 2.08 s (dmx9 2.09). A compile storm (262,144 new blocks) exposed dmx10's cost: 318–324 ms
against dmx9's 268–270, from re-protecting protected pages. dmx11 skips pages it protected since
their last invalidation: 248–259 ms. dmx11 passed every suite: unit 59, selftest 23 (idle 97 MiB,
1123 → 104 MiB in 320 ms), daemon 57, MCP 33, x86 53 (node 270 ms, python loop 200 ms), Docker
69, sandbox 44, images 24 and Java 100 (median 2.08 s). Details, hashes and excluded runs:
[measurements](measurements/2026-10-27-fex-code-patching.json).

### Data disk idle trim (2026-10-27)

One Mac's `data.img` held 5.9 GB on the host while the guest used 260 MB; `fstrim` gave back
5.4 GB. Reproduced: 2 GB deleted with online discard off left the host file at 2059 MB, one
FITRIM returned it to 11 MB. The idle sweep now trims the disk: 10 ms after boot on a 64 GB disk,
0 ms when nothing was freed since, 0.24 s right after deleting 3 GB, 40 ms in a fresh daemon.
daemontest's new `disk_idle_trim` (256 MB freed without discard) fails on the v0.3.5 guest
(266 → 266 MB) and passes with the new agent (266 → 10 MB), 58/58. Selftest unchanged: idle
97 MiB, 1123 → 102–103 MiB in 217–322 ms (v0.3.5: 97, 1123 → 104 in 320 ms). Unit 59/59.

### Earlier measurements

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
| 2026-10-23 | Where the 8G idle footprint goes (173 MB, before the changes below) | `mincore` over guest RAM: 144.5 MB resident guest pages. By kpageflags: reserved 79 MB (kernel 29, memmap 32, dentry+inode hash 12, rest 6), slab 21, pages with no flags 31 (freed initrd and init memory parked on per-CPU lists, hash tables allocated after boot), shmem 12, free buddy pages 0. dmx's own regions 5 MB (`footprint` tool). ~24 MB more is charged to the process but is neither. |
| 2026-10-23 | The ~24 MB nobody owns | `task_info(TASK_VM_INFO)`: all of `phys_footprint` is `internal`; nothing compressed, reusable or tagged. Constant across ceilings (2G, 8G) and vCPU counts (1, 2, 10), absent before the first vCPU runs, appears within 50 ms of boot. Likely Hypervisor.framework state charged to the process; unexplained. |
| 2026-10-23 | Per-CPU free page lists (pcp) | 2200 to 2900 pages (35 to 45 MB) on pcp lists after boot at 8G, 10 vCPUs; `high_min` 1055 and `high_max` 2428 pages per CPU. Free page reporting sees only the buddy lists, and idle CPUs never run the vmstat work that would drain them. `vm.percpu_pagelist_high_fraction=100000` caps them at 60 pages. |
| 2026-10-23 | Kernel arg experiments, 8G, three runs each | Baseline 172 to 174 MB. `kfence.sample_interval=0`: 171 to 172 (not adopted). `page_reporting_order` 9/7/5 alone: no change at idle. `dhash_entries=131072 ihash_entries=65536 thash_entries=16384`: 155 to 160. With twice those: 161 to 162. Plus pcp cap: 158 to 160, residue after the 1 GB test 176 to 192 (was 196 to 272). Plus order 5: residue 162 to 164 MB, back in 0.3 to 0.5 s (order 7: 168 to 262). |
| 2026-10-23 | Initramfs without apk, OpenSSL, CA bundle, zlib | 5.6 → 2.5 MB compressed, shmem 12 → 5 MB. |
| 2026-10-23 | Selftest with all of the above (16K kernel, 10 vCPU) | 8G 144 to 145 MB, 4G 125, 2G 114 (were 172, 150, 126). Agent up in 220 to 270 ms (was ~300). 1 GB fill then free: back to idle + 4 to 5 MB in 1.0 to 1.3 s at 8G, ~2 s at 2G and 4G. The selftest `reclaim` check now requires idle + 32 MB (was 128). Stock 4K bootstrap guest: 273 MB (was 287), apk still present. |
| 2026-10-23 | Streaming guest stdout through the agent | `dmx boot -- sh -c 'head -c 100000000 /dev/zero; sleep 8'`: footprint peaks at 349 MB and stays at 235 MB after the stream (idle 174): 44 MB MALLOC_SMALL and 10 MB MALLOC_LARGE dirty in the `footprint` tool. |
| 2026-10-23 | Streaming through vsock, before and after `ByteQueue` and pull-based exec output | Guest stdout 100 MB: peak 349 → 151 MB; 500 MB: 637 → 157 MB, ~130 MB/s with a kernel build running beside it. Host stdin 500 MB into `md5sum`: peak 151 MB, 2.5 s, checksum matches. `malloc_history` pinned the growth on `Data.append` in `VirtioVsock.receiveFromGuest` (2 buffers, 119 MB). |
| 2026-10-23 | Transparent huge pages with 16K pages (32 MB each), 8G | A 1 GB anonymous mapping with one byte touched per 32 MB: `always` (Alpine's default) RssAnon 1048640 kB, `madvise` 576 kB. One byte per 1 MB: 1 GB vs 16 MB. `transparent_hugepage=madvise` is now a default kernel arg; idle footprint unchanged (146 MB with a kernel build running beside it). |
| 2026-10-24 | Per-vCPU cost and slab order, 8G | Footprint by vCPU count: 1: 125, 2: 129, 4: 133, 10: 146 to 148 MB. `slub_max_order=0`: 10 vCPUs 139 to 142; `=1`: 141 to 142, 1 vCPU unchanged (125). Shrinking slabs and `cpu_partial=0` at runtime: no gain. Adopted order 1 (order 0 would put one kmalloc-16k object per slab). 2G 109 MB (was 114). |
| 2026-10-24 | Trimmed kernel config (6.18.58-dmx), 10 vCPU | Compile 1130 s with host load ~25 (was 8460 s). Image 22.4 → 17.4 MB, initramfs 2.5 → 1.6 MB (6 modules left). dmesg: kernel code 13.3 → 11.4 MB, bss 9.3 MB → 463 KB (NR_CPUS), reserved 82 → 59 MB. Slab 11 MB, shmem 3.6 MB. Selftest 8G 120 to 121 MB (was 141), 2G 87 (was 109); agent up in 140 to 180 ms; after the 1 GB test 122 to 124 MB in 0.2 to 0.3 s. |
| 2026-10-24 | vCPU offline at idle (trimmed kernel, 8G) | 1 vCPU booted: 104 MB; 10 vCPUs: 118 to 121 MB; 9 of 10 taken offline: 116 to 119 MB. Bringing one back online crashed the guest ("kernel stack overflow"): CPU_ON reused the old EL1 state, so the CPU entered the kernel with the MMU on. Now the vCPU's EL1 registers as created are restored on every CPU_ON. |
| 2026-10-24 | Selftest hangs under host load ~40 | 1 of 5 runs hung forever before any change today. Cause found in code: the virtio-mmio ack path lowered the interrupt line after releasing the lock, so a buffer used in between could leave the line low with work pending. Lowered under the lock now. Also a timed-out selftest never returned: stopping the VM did not close vsock streams, so agent reads blocked; they get EOF now. After both: 29 of 30 runs pass (the other hit the 30 s selftest timeout while host load was 40 to 76); 12 of 12 with an 80 s timeout. |
| 2026-10-24 | The "~24 MB nobody owns" was a measuring error | A 112-byte test guest that writes one word per 16K page with the MMU off: touching 0 MB gives a footprint of 3 MB, 100 MB → 103 to 104, 1000 MB → 1003 to 1004, with 1 or 10 vCPUs. `mincore` reported 0 MB for all of it. So Hypervisor.framework plus dmx cost ~3 MB, stage-2 tables under 1 MB per GB touched, and `mincore` misses guest pages: the 24 MB were guest pages. Guest accounting has to come from inside the guest (reserved + MemTotal - MemFree ≈ footprint - 4 MB). |
| 2026-10-24 | Reserved memory by caller (`memblock=debug`, trimmed kernel, 8G) | memmap 32 MB, kernel image 17.3, linear map page tables 4.0 (258 tables of 16 KB: RAM mapped page by page), hash tables 1.5, percpu first chunk 1.3. `rodata=on` is the same as full on 6.18; `rodata=noalias` maps the linear map in 32 MB blocks: 3 tables, footprint 119-120 → 114-117 MB. |
| 2026-10-24 | Guest MemTotal - MemFree at idle (48 MB) | per-CPU free lists 11.3 MB (722 pages over 20 lists: DMA and Normal zone per vCPU), slab 10, vmalloc ~5 (3 MB of it the atomic DMA pools), shmem 3.6, kernel stacks 2, page tables 1.8, percpu 1.8, the rest driver buffers. `coherent_pool=64K` (pools of 1 MB per zone otherwise): 112 to 113 MB. |
| 2026-10-24 | Kernel without the lockdown LSM | `MODULE_SIG` off; modprobe no longer taints the kernel. Compiled in 7423 s at host load 30 to 76. Selftest with `rodata=noalias coherent_pool=64K`: 112 MB at 8G (3 runs), back to 113 to 118 MB after the 1 GB test. |
| 2026-10-24 | Kernel without ZONE_DMA/ZONE_DMA32 (one Normal zone) | Compiled in 933 s at host load ~10 to 25. Per-CPU free lists 20 → 10, but they hold the same in total (776 pages, 12 MB): each list's high mark grows with its zone. Selftest 8G 111 to 112 MB (was 112), 2G 87; after the 1 GB test 113 MB in 0.3 s. Kept: nothing in dmx needs memory below 4 GB. |
| 2026-10-24 | Back to `rodata=full` (maintainer's choice) | Selftest 8G 115 to 116 MB (was 111 to 112 with `rodata=noalias`), after the 1 GB test 116 to 118 MB in 0.3 s; agent up in 140 to 170 ms. |
| 2026-10-24 | Daemon (8G, 10 vCPU, standalone and launchd) | Cold `dmx exec -- uname -r` with no daemon running: 0.22 to 0.29 s end to end (spawn or launchd start, boot, exec); warm exec 14 ms; VM up in 140 to 240 ms, stopped through the agent in 6 to 13 ms. Daemon footprint: VM running and idle 114 to 116 MB (same as the selftest), VM stopped 4 MB. 8 concurrent cold `dmx exec`: one daemon, the other 7 exit on the lock. |
| 2026-10-24 | Streams through the daemon relay | 500 MB guest stdout into `wc -c`: 2.1 s (~240 MB/s); 300 MB stdin into `md5sum`: 0.95 s, checksum matches. Footprint after both 123 to 127 MB (idle 116), guest used unchanged: the same +11 MB of guest pages as streaming through `dmx boot --` (see the vsock rows); the daemon's own malloc 5.5 MB. |
| 2026-10-24 | launchd socket activation | With `ThrottleInterval` 1 and the daemon lingering 10 s, relaunch on the next connection is immediate (`dmx status` 33 ms including the start). `launch_activate_socket` is missing from Swift's Darwin module; it is looked up with `dlsym`. |
| 2026-10-24 | Signals in the guest | `/proc/<pid>/status` SigIgn 0x6 for every exec'd process: `/init` starts the agent in `( ... ) &`, and POSIX shells start background jobs with SIGINT and SIGQUIT ignored, which survives exec. Ctrl-C reached the pty but killed nothing. |
| 2026-10-24 | Idle footprint with the memory controller | 112 to 116 MB over 8 boots (113 to 115 before); selftest 115 to 116 MB. |
| 2026-10-24 | Idle trim of 1.5 GB clean page cache | Before: stayed at 1653 MB until idle stop. Now trimmed 33 s after the last exec; reclaim 10 ms; footprint 1653 → 134 MB within 3 s. Under warning: 512 MB trimmed in 2.0 to 2.2 s, idle trim 7.5 to 8.2 s after the exec. |
| 2026-10-24 | Simulated critical, guest holding 1 GB tmpfs + 512 MB cache | Footprint 1639 → 1147 MB in 1 s, then 1010 MB; 525 MB of tmpfs into zram (lz4 1.3x on copied binaries). Balloon took 6.9 GB in under 2 s and gave it back in under 2 s at normal, footprint unchanged by either. 1.5 GB more into tmpfs under the cap: no OOM kill, the balloon target followed use. |
| 2026-10-24 | Balloon and `init_on_alloc` on dmx's VMM | Inflating 7.8 GB with init_on_alloc on: ~1.5 s CPU, ~2 s wall, peak +2 MB, nothing lasting (each 1 MB batch is released as it arrives); off: ~0.3 s CPU. The VZ rule "never inflate with init_on_alloc" does not apply here. |
| 2026-10-24 | zram swap at idle | 2 GB disksize costs 3.7 MB of guest memory (table and swap maps), +1 to 3 MB footprint: turned on on demand. |
| 2026-10-24 | Footprint under real host pressure | At critical one reading was 217 MB while the guest held 1.6 GB: macOS swapped guest pages out and `ri_phys_footprint` drops them. Compare footprints only at normal or simulated pressure. |
| 2026-10-24 | vmnet without root (macOS 26.6.1, ad-hoc signed) | `vmnet_start_interface` shared and host mode: VMNET_FAILURE (1001); macOS 26 `vmnet_network_create`: 1002; adding `com.apple.vm.networking` to an ad-hoc signature: killed at launch. |
| 2026-10-24 | Guest network (user space NAT), load 7 to 20 | Idle selftest 115 to 118 MB (114 to 117 before). 500 MB host → guest over HTTP 0.25 to 0.5 s (1 to 2 GB/s; 16 s before publishing each frame's rx buffers at once, the guest dropped partial frames). 500 MB guest → host 0.9 to 1.4 s. 394 MB from the Alpine CDN: 32.1 s in the guest, 32.07 s with curl on the host. DNS through exec 70 to 100 ms; ping gateway 0.2 to 0.3 ms. Footprint +15 to 17 MB after traffic, then flat: freed guest blocks under 512 KB that reporting skips; dmx's own heap 2.8 MB after 1 GB. |
| 2026-10-24 | Port forwarding, load 8 to 17 | Guest → host 500 MB at 1.0 to 1.1 GB/s; host → guest into busybox `nc` 252 MiB/s; 4 parallel 250 MB 1.18 GB/s. 1000 GETs at 100 concurrent in 0.39 s; 500 slow requests at once all OK. A connection with the VM stopped boots it: 0.22 to 0.36 s until the guest answers. Footprint 116 → 150 to 152 MB after 500 MB each way (guest pages); +76 MB after a burst of 500 connections: freed guest blocks of 32 to 256 KB, under the 512 KB reporting order. |
| 2026-10-24 | Exec data loss with a slow reader | `dmx exec -- head -c 8000000 /dev/zero` into a slow reader lost 205,900 bytes and exited 0: the agent sent `exit` while an output pump was still blocked on the host. 0 of 20 after the fix. "Connection closed before the process exited" in 1 of 5 to 10 daemontest cold-start rounds: the relay shut both sockets when the client's last stdin write failed, discarding the guest's output. 0 of 960 after. |
| 2026-10-24 | Device interrupts waited out the 1 ms WFI cap | `VCPU.wake()` was never called, so a vCPU in WFI noticed a device interrupt only at the cap. Raising a line now wakes the vCPU it is routed to: over virtio-fs `find` 1.69 → 0.28 s, reading 9,200 files 75 → 10 s. The selftest's 1 GB reclaim now returns in ~0.4 s. |
| 2026-10-24 | virtio-fs throughput, load 7 to 18 | 1 GB write with fsync 0.81 to 0.91 GB/s (host ~1 GB/s without fsync); read 1.4 to 1.5 GB/s (host 2.3 warm); O_DIRECT read 3.1 GB/s. 9,200 kernel source files (106 MB), share / guest tmpfs / host: untar 20 to 23 / 0.6 / 10 s; find 0.32 / 0.03 / 0.07; ls -lR 0.33 / 0.03 / 0.16; read all 5.8 / 0.5 / 0.36; rm -rf 4.1 / 0.07 / 1.4. Server time 20 to 70 µs per request; the rest is round trips. |
| 2026-10-24 | virtio-fs memory (before the mapping fix) | Idle with a share 113 to 121 MB (116 to 121 without, noise). dmx's heap ~11 MB after repeated traffic. Reading 1 GB through the guest page cache cost 2 GB of footprint, all returned when the guest dropped its cache; writes showed the same. Resolved by dropping dmx's duplicate mappings (the later "Pages counted twice" measurement). |
| 2026-10-24 | Data disk (virtio-blk), load 6 to 25 | Initramfs 1.63 → 2.02 MB (mke2fs, deleted after mount; shmem unchanged). Idle footprint ~115 MB, unchanged within ~1 MB (118 without `no_prefetch_block_bitmaps`). Write 2 GB 1.1 to 1.2 GB/s, read 2.1 to 2.2 GB/s. Through the host cache: 323 MB/s write and +2 GB footprint (host cache charged to dmx), hence `F_NOCACHE`. 2 GB deleted: host allocation 1.9 GB → 11 to 22 MB in 0.08 to 0.17 s. Online discard costs 1.28 vs 0.48 s per GB deleted; without it nothing comes back until fstrim. 4K write + fsync 2.8 to 6.6 ms with barrier flush, 9.8 to 16.7 ms with `F_FULLFSYNC`. SIGKILL mid-write ×3: journal replayed, e2fsck clean. First boot formats in 0.3 to 0.9 s. |
| 2026-10-24 | Selftest under host load ~29 (several agents' VMs) | Agent up after 5 to 11 s instead of ~0.2 s; the 30 s and even 60 s selftest timeouts are hit, `--timeout 180` passes. Compare timings only on a quiet host. |
| 2026-10-24 | Fragmented free memory and the idle sweep, load 25 to 85 | Before: 500 forwarded connections 119 → 163 MB (free blocks of order 0 to 4 hold ~33 MB, slab +7 MB); untar/rm of 9,200 files in tmpfs 122 → 151 MB; 500 MB wget 117 → 136 MB. `page_reporting_order` is writable at runtime (0644): writing 0 gave 163 → 128 MB in ~10 s, then shrinking slabs 133 → 115 MB. With the sweep: connections 161 → 112 MB, untar/rm 150 → 113 MB, wget 134 → 125 MB (idle 107 to 112). A sweep takes 40 to 1050 ms wall, under 0.1 s daemon CPU. Idle daemon CPU per 60 s: 0.05 to 0.06 s (0.06 to 0.07 before). Order 0 always on showed no cost while busy, but the host was too loaded to be sure; not adopted. |
| 2026-10-24 | Guest soft lockup at host load 80 to 86 | Once, right after an untar/rm workload: `soft lockup - CPU#N stuck for 140s` in ksoftirqd/rcu_preempt on 6 vCPUs, daemon at ~40 % CPU. Not reproduced in 24 stress rounds. Suspected vCPU starvation on an overloaded host rather than the sweep; open. |
| 2026-10-24 | daemontest at host load 40 to 61 | The 500 MB stdout check took over 60 s (6 MB/s; 90 to 240 MB/s on a quieter host) for old and new builds alike. Test timeouts are now 300 s and a timeout fails its check instead of the script. |
| 2026-10-24 | x86_64 through qemu-x86_64, load 25 to 90 | Initramfs 2.03 → 3.09 MB. Idle +~2 MB (115 to 117 → 117 to 119), guest used unchanged; first-boot unpack leaves +4 to 8 MB of freed pages. x86 process RSS with THP madvise / never: `sleep` 38 / 5.4 MB, python3 43 to 47 / 15.7 MB, node 23.5 MB; x86 `true` 201 → 49 ms. Rough speed (loaded host): `true` 22 to 62 ms vs 1 to 6 native, sha256 1.8 to 4.5x native. Static, dynamic (chroot), python3 (ssl, sqlite, threads), node 24 (JIT, wasm) work. |
| 2026-10-24 | x86 programs on 16K guest pages | x86 code sees 4096-byte pages. Works: brk, MAP_PRIVATE at 4K offsets (copied, not shared), MAP_SHARED at 4K offsets without MAP_FIXED. EINVAL on a 4K page inside a 16K page: msync (Python `mmap.flush()`), mincore, MADV_DONTNEED (page not zeroed), MAP_FIXED|MAP_SHARED misaligned to 16K. Not enforced: mprotect and munmap of a single 4K page (guard pages fail silently). Likely victims: stack guards, LMDB-style msync databases, the JVM's 4K polling page (untested). |
| 2026-10-24 | binfmt `C` flag | As `nobody`, a setuid-root x86 binary with `QEMU_LOG_FILENAME=/root/x` creates a root-owned file: qemu honours `QEMU_*` while privileged. Docker Desktop's `CF` has the same exposure; kept to match it. |
| 2026-10-24 | Pages counted twice | Standalone test: 512 MB touched by host and guest = 1026 MB footprint whichever side goes first; a second mapping in one process without a VM (`mach_vm_remap` alias) does the same; the VM object held 512 MB. Dropping either mapping halves it. Fix: 1 GB virtio-fs read +2046 → +1024 MB; selftest idle 115 to 117 → 97 to 99 MB (the host's copies of kernel and initramfs had counted twice); idle footprint now equals the guest's own count (reserved + used). ~30 remaps per GB, 0.3 to 3 ms each. Side effect: a page only a device filled and the guest never touched is uncounted until touched (small with init_on_alloc on). |
| 2026-10-24 | Reusable pages re-dirtied by the guest (before MADV_ZERO) | After `MADV_FREE_REUSABLE` and a full guest rewrite, footprint stayed 2 MB with 512 MB dirty, counted only once macOS paged them out. Real VM: a 500 MB refill came in ~50 MB short. Resolved with `MADV_ZERO`; see "Reused pages after free page reporting" below for the final fix and the fault-driven alternative. |
| 2026-10-24 | Docker (stock CLI 29.9.1, Compose 5.6.0), load 16 to 50 | Idle without Docker 99 MB (with the double-count fix). dockerd + containerd idle: guest +52 MB (RSS 37 + 25); footprint 305 MB right after start, 210 MB after the idle trim and sweep (guest used 91, cache 45). One `busybox sleep` container: guest +10 to 12 MB. First Docker use (unpack + start) 10 to 35 s; dockerd start on a later boot 1.5 to 4.7 s. hello-world with pull 6.6 to 27 s, warm 2.0 to 3.2 s, cold from a stopped VM 7.5 s; pull alpine 5.3 to 8.9 s; small build 3 to 24 s; compose up 2 to 21 s. Bind mount write with fsync 30 MB/s in a container. |
| 2026-10-24 | Interrupted first-boot format | The daemon gave up on a boot after 30 s; on a loaded Mac that cut `mke2fs` short, and since `/init` formatted only an all-zero first MB, the disk was never formatted again. Now it formats a disk without an ext4 superblock (mke2fs writes it last) and the daemon waits 120 s; checked with a disk whose first MB is random. |
| 2026-10-24 | dmx's Docker tools, load 15 to 20 | Download 112 MB in 10 to 11 s, 137 MB on disk (docker 41, buildx 62, compose 29, credential helper 2.3); resumes with HTTP ranges; re-checking all present 0.17 to 0.3 s. BuildKit build (FROM alpine, RUN, COPY) 1.2 to 2.0 s, `--no-cache` 0.5 to 1.1 s; multi-stage with a cache mount 3.3 to 3.8 s; `compose build` 0.8 to 1.6 s. |
| 2026-10-24 | Guest download | Release guest archive 61.7 MB; download, check and unpack from a local server 0.3 to 0.6 s. Hashing with `FileHandle.read` left ~130 MB in the daemon (autoreleased chunks, no pool drains); one 1 MB buffer now. Daemon after a download: 10 MB with the VM stopped (4 MB otherwise), until it exits idle. |
| 2026-10-24 | Sandboxes, load 10 to 28 | First create on a new data disk (boot, dockerd, pull) 6.2 to 6.9 s; create with the image present 0.21 to 0.53 s; exec `true` 35 to 52 ms; checkpoint 0.17 to 0.27 s (1.0 s with 3 MB changed, +3.8 MB per 4 MB written); rollback 0.25 to 0.36 s; fork 0.19 to 0.69 s; remove 0.09 to 0.14 s; a 10 s TTL removes it after 10.3 to 10.5 s with the client gone. Guest memory per idle sandbox 7 to 8 MB. Allowlist sandboxes still resolve any name (Docker's resolver runs outside the sandbox). |
| 2026-10-24 | virtio-mem, load 8 to 50 | Idle footprint by ceiling, all memory at boot → virtio-mem: 2G 79 → 80, 4G 88 → 80, 8G 107 → 79, 16G 145 → 83 MB; guest reserved 32/41/59/95 → 27.5 MB. Idle: 1 GB boot + 256 MB plugged. Burst of 4 × 512 MB into tmpfs in 0.5 to 0.7 s: no OOM, lowest MemAvailable 425 MB, 1.9 GB plugged 60 ms after the request (~32 ms/GB); back to 1.25 GB present 30 s after deleting, footprint 79 to 90 MB. 10 × 200 MB: a fixed 1 GB headroom gave 7 OOM kills (plugging needs memory for its memmap and CPU from a guest busy reclaiming, ~700 ms); the rate-based step none. Idle CPU 0.12 % of a core (0.08 % before). Coordinator's run after merging: selftest 81 MB, daemontest 83, x86test 81, dockertest idle without Docker 67, dockerd idle 274. |
| 2026-10-24 | Docker gaps, load 5 to 14 | qemu moved into docker.img: initramfs 3.10 → 2.06 MB; idle without Docker 92 to 94 vs 91 to 95 MB (no measurable difference). UDP: first reply 0.14 to 0.19 s after `docker run -d`; 2000 round trips at 190 to 300 µs; 200 new peers at once all answered. Restart policy: the container answers 1.0 to 1.2 s after `dmx start` returns, dockerd up in 170 to 190 ms. Proxy integrity: 50 MB through `docker run -i` and `docker exec -i`, checksums match. |
| 2026-10-24 | Reused pages after free page reporting | `MADV_FREE_REUSABLE` pages the guest writes again stay uncounted until macOS reclaims them. Release now uses `MADV_ZERO` (after `hv_vm_unmap`; with stage 2 mapped it only zeroes in place), falling back to REUSABLE: 1 GB tmpfs refills 12 of 12 counted (1125 to 1128 MB) vs 5 of 12 up to 220 MB short; standalone 512 MB rewrite 514 MB vs 2 MB. Refill 0.26 to 0.44 s per GB (0.23 to 0.33), release of 512 MB 13 to 25 ms (7 to 16). A fault-driven alternative (`MADV_FREE_REUSE` on stage-2 abort) worked but cost 4 to 14 µs per exit. |
| 2026-10-24 | Memory left after network traffic | Linux sizes mergeable rx buffers by the average frame: after bulk traffic each takes a 32 KB fragment, 256 posted = 8 MB with no meminfo counter. Receive ring 256 → 64: after 3 × 500 MB +5 to 6 MB footprint instead of +11 to 12; host → guest median 1.3 → 1.7 GB/s. |
| 2026-10-24 | macOS loses the EOF wakeup of a blocking read on a socketpair | A thread blocked in `read()` on one end of a Unix socketpair can sleep forever after the other end writes and then `shutdown(SHUT_WR)`, though a non-blocking peek returns 0 at once (C repro: hangs within 2,000 to 80,000 rounds on macOS 26.6.1; `poll()` first: 4 million rounds, no hang; `close()` instead of shutdown never hung). vsock streams are such socketpairs, and the docker.sock proxy made blocking reads common: sandboxtest failed 2 of 3 runs (stuck inspections held starts, a stuck listing froze the container count). Every blocking socket read now waits in `poll()` first (`readSocket`): 6,000 hammer cycles (~25,000 connections) without a hang, sandboxtest 5 of 5 and 3 of 3 after merging. Coordinator re-ran the C repro: blocking read hung after ~51,600 and ~56,300 rounds (data + shutdown) and ~4,600 (shutdown only); poll first, 2,000,000 rounds clean. Reported to Apple as FB25307646 (2026-10-24, with the repro). |
| 2026-10-24 | `dmx mcp` (stdio MCP), load 5 to 6 | `make mcptest` 5.3 to 6.3 s, 30 of 30 checks. Cold `dmx_exec uname -a` with no daemon 215 to 376 ms end to end; warm 0 to 2 ms. 200 MB of stdout capped to 8 KiB in 0.65 to 1.41 s; `dmx mcp` RSS 8 to 9 MB, 10 MB at peak. A 2 s timeout returns in 2.01 to 2.13 s with the guest processes gone. `tools/list` is 4.6 KB (3.8 KB without `outputSchema`). |
| 2026-10-24 | Truncated exec output after a boot | `dmx stop`, an exec, then 200 MB of stdout: 5 to 6 of 40 runs ended with "daemon closed the connection mid-frame" (load 9 to 15); logging the shutdown path hid it. The guest sometimes sends RST right after its SHUTDOWN, and the host dropped the connection with up to 200 KB from the guest still unwritten to the full host socket. Now an RST on an open stream delivers what the guest sent, then closes: 0 of 50. Found by the `dmx mcp` tests. |
| 2026-10-24 | Pressure unplug and status, host load ~5, 8G ceiling, 10 vCPU | Selftest before/after: idle 80/81 MB, 1 GB freed returned in 2115/1065 ms (single runs, not a timing claim). Same separate 2 GB tmpfs fill/free scenario: before, MemTotal stayed 5096 MB with a 4778 MB balloon and 94 MB host footprint at 2 s of simulated critical; after, MemTotal fell from 6376 to 1000 MB, hotplug 5376 → 0 MB, balloon 698 MB, footprint 76 MB at 2 s (88/67 MB at 20 s). Initial hotplug sizes differ because growth-rate lookahead follows each run; idle was 76 MB in both. Daemontest separately removed 4480 MB of hotplug RAM in 0.9 s, allocated 1536 MB of incompressible tmpfs under critical without OOM, restored warning/normal headroom, and passed the 1G no-hotplug balloon fallback. 40/40 daemon checks; 32 unit tests, including rejecting late pressure callbacks after VM teardown. Pressure was simulated, not real macOS memory exhaustion. |
| 2026-10-24 | Regression suites after pressure/status changes | Selftest 21/21, daemon 40/40, MCP 30/30, Docker 57/57, sandbox 41/41, x86 13/13, unit tests 32/32. Docker settled footprints: 65 MB unused, 273 MB dockerd idle, 305 MB one container. The x86 suite still observes the known 4K msync, guard-page and MADV_DONTNEED failures as expected probe results; passing it does not close the popular-image compatibility matrix. |
| 2026-10-24 | Final lifecycle verification | After guarding queued pressure/stat callbacks at VM teardown, `make build && make guest && make selftest` and `make daemontest` passed again: idle 81 MB in both, 1 GB returned in 2198 ms, 2944 MB hotplug removed in 1.2 s, critical footprint 88 MB. Growth-rate lookahead varies the transient hotplug size between runs. |
| 2026-10-25 | Image matrix and 4K default | Nine digest-pinned images × arm64/amd64. Previous 16K: 15/18; current 4K: 17/18 (all 9 native images). Python's libpython mapping and Java's partial msync now work. Redis amd64 still fails with default QEMU layout; its full BGSAVE/AOF/restart workload passes with QEMU_GUEST_BASE=0x800000000000, recorded separately. Pin hashes, guest hashes and raw results are in compatibility.md and docs/measurements. No default failures are skipped. |
| 2026-10-25 | Reporting budget, matched 2-CPU/4G profiles | Three runs each: 16K idle 64–66 MB / 1 GB return 411–2156 ms; 4K with upstream 1/16 budget 77–78 MB / 8289–9998 ms; 4K with a whole bounded free-list pass 78 MB / 317–2114 ms. The source retains its 2 s scheduling delay but no longer spreads the initial list over sixteen passes. Current kernel 6.18.58-dmx-4k built in 737 s (compile 719); artifact sha256 afd14657b5ec43272dc2fdb9919cda7956bfd602645e09be1ef1864604cbc9e4. Recipe/source-patch notices now accompany release assets. |
| 2026-10-25 | 2 GB container return, including 4K memmap | Data reporting alone left the default 10-CPU/8G profile 78.86 MB above baseline after 10.08 s: normal unplug still waited 30 s. Normal surplus now waits 5 s and gets stats at least once per second during that countdown; already-pending unplug does not restart it. Same profile: held 2425.77 MB → 236.60 MB vs pre-workload 300.60 MB in 6.14 s. 2-CPU/4G profile: held 2368.69 → 328.78 MB vs 272.08 MB, within the +64 MB goal in 1.50 s. Host pressure was normal (1) throughout. Daemontest independently returned RAM and footprint in 7.0 s at normal, unplugged after critical in 0.8 s. This is local acceptance evidence, not a cross-engine benchmark. |
| 2026-10-25 | Final 4K validation | Selftest 21/21 (default 8G, 10 CPU idle 89–90 MB); daemon 41/41 including the new normal-unplug deadline; Docker 57/57; MCP 30/30; sandbox 41/41; x86 13/13 with all ten 4K syscall probes true; unit tests 33/33. Daemon and Docker repeated after the 5 s policy change. Final image run has no module-verification, BUG or soft-lockup messages. The default image matrix remains 17/18 until Redis's QEMU layout is fixed. |
| 2026-10-25 | amd64 Redis and QEMU's guest address layout | QEMU 11.0.3 gives a 64-bit guest any host address (`guest_addr_max = ~0` without `-R`); with a taken hint the 48-bit guest kernel searches top-down from just below 2^48, so x86_64 code got `0x0000ffff...`, above its 47-bit user space, and jemalloc's sign-extended pointers faulted. dmx's qemu-x86_64 (2^47 guest base): Redis amd64 passes in 3.6 s; default matrix 18/18, no kernel problems ([report](measurements/2026-10-25-images-guest-base.json)). Before switching, all nine amd64 images passed with the base set via `QEMU_GUEST_BASE`. x86test 16/16: probe addresses below 2^47 (upstream layout control: above); python3 with jemalloc preloaded exits 139 under the upstream layout and passes with dmx's; mimalloc passes both. `make qemu` 23–27 s (compile 8–10 s), two builds same sha256, 3.85 MB (Alpine's 3.78 MB). |
| 2026-10-25 | qemu-x86_64 before/after, x86test twice each, load ~2–6 | Alpine → dmx build: x86 `sleep` RSS 5 → 5 MB; `true` 2–4 ms both; python3 start 126 → 120–123 ms; node 403–420 → 396–400 ms; 100 MB sha256 x86 1040–1050 → 1020 ms; footprint after x86 work 216–221 → 215–223 MB, after cleanup 122–123 → 117–121 MB. No regression ([raw](measurements/2026-10-25-qemu-guest-base.json)). |
| 2026-10-25 | Gates after the QEMU change, load 4–6 | Selftest 21/21 (8G/10 CPU idle 92 MB, 1 GiB back in 634 ms), daemon 41/41, Docker 57/57, MCP 30/30, sandbox 41/41, x86 16/16, unit tests 33/33. Benchmark (native arm64, so qemu is not on its path): 2 CPU/4G idle 180–292 MB over three runs (recorded 193; the 292 MB run is the outlier), 2 GiB returned to baseline +64 MB in 1.6–6.5 s; 10 CPU/8G back below its baseline in 6.6 s. |
| 2026-10-25 | Engine comparison, 2 CPUs/4 GiB, three alternating rounds, load 2.4–6.4 | Median idle: dmx 180, OrbStack 528, Colima 1097, Docker Desktop 1176 MB. Holding 2 GiB: 2373 / 2621 / 3172 / 3373 MB. 10 s after freeing: 332 / 618 / 3180 / 3362 MB; dmx back in 5.9 s, OrbStack 4.2 s; Docker Desktop fell to 365 MB only when Resource Saver stopped its VM (2–5 min), Colima still 3394 MB at 6 min. Warm `docker run` 118 / 123 / 73 / 99 ms; SHA-256 of 256 MiB 954 / 1469 / 912 / 1739 ms ([raw](measurements/2026-10-25-engine-comparison.json)). Engines installed temporarily and removed. |
| 2026-10-25 | Warm `docker run` profile, 2 CPUs/4 GiB, load 3–8 | Create 35–38 ms, start 48–54, exit to `wait` reply ~16; proxy/vsock round trips ~0.3 ms; WFI cap 100 µs or 20 ms: no change. ~80 guest flushes per run + rm (containerd meta.db 24 fdatasyncs, dockerd local-kv.db 14, snapshotter metadata.db 12, ~11 files). Host flush: `F_BARRIERFSYNC` ~0.35 ms, `fsync` 15 µs, `F_FULLFSYNC` 3.7 ms; guest fsync of 4 KB 2.1 ms vs 0.46 ms with flushes skipped. Medians, three alternating rounds: barrier 122–137 ms, early answer + barrier 115–130, plain fsync 75–78, no flush 69. Barrier kept ([benchmark.md](benchmark.md#warm-docker-run-profile-2026-10-25)). |
| 2026-10-25 | dockerd in its own cgroup | `--memory 256m` now sets `memory.swap.max` 256 MB (was `max`, with the "no swap limit support" warning); `docker info` SwapLimit true. Warm `docker run` at load ~17, dockerd/containerd moved between cgroups live, three rounds: 200–218 vs 210–231 ms in the root (no cost). Idle after a container and 45 s: 144–154 MB vs 145 before (single runs). dockertest 58/58 (dockerd idle 289 MB, one container 266), daemontest 41/41, sandboxtest 41/41, selftest ok (92 MB). |
| 2026-10-25 | User daemon.json | Labels and an insecure registry from `$DOCKER_CONFIG/daemon.json` show in `docker info`; its `hosts` is ignored; a truncated file fails `docker version` with the path and hint. dockertest 60/60 at load ~12 (idle without Docker 75 MB, dockerd idle 270, one container 252), sandboxtest 41/41, selftest 22/22 checks ok, unit tests 34/34. |
| 2026-10-25 | The Mac's proxy and certificates for dockerd | dockertest 63/63 at load ~4.5: a CONNECT proxy on the Mac's loopback named in daemon.json carried `registry-1.docker.io:443` and `auth.docker.io:443`; a registry stub with a self-signed CA on the Mac failed with `x509: certificate signed by unknown authority`, then answered `not found` (TLS accepted) after the CA went into `DMX_HOME/ca-certificates.pem` and `dmx stop`. Changing the Mac's system proxy needs admin rights and changes the whole Mac's network, so `HostProxy.parse` is unit-tested instead (36 unit tests). Footprints: idle without Docker 75 MB, dockerd idle 275, one container 404 (other runs today 252–460; noisy at this step). |
| 2026-10-25 | Guest kernel oops (once) | dockertest, ~31 s after boot (idle sweep time): `Unable to handle kernel NULL pointer dereference` in `sysfs_kf_seq_show+0x50` from `dmx-agent` reading a sysfs file (`kobj->ktype->sysfs_ops` NULL). The agent stopped answering and `dmx status` waited 120 s. Not reproduced by 20,000 reads of `page_reporting_order`. `dmx status` now gives up on guest memory after 2 s. Resolved 2026-10-26: guest memory corrupted by direct I/O while the Mac swapped (see "cause and fix"). |
| 2026-10-25 | Developer ID signing and notarization | New "Developer ID Application" certificate (G2, until 2027-11-24) from a CSR made on this Mac, in a signing keychain. Signed with hardened runtime + timestamp; `notarytool` accepted in 29 s. Gatekeeper: `spctl` said "Unnotarized" for the first minute, then "valid but not an app" (normal for a tool); a quarantined copy then asked "downloaded from the Internet … Open?" instead of refusing. Hardened-runtime binary: selftest ok (88 MB), daemontest 41/41. |
| 2026-10-25 | Download mirrors | `release_url` set to a local server: `dmx guest fetch` took `/v0.1.0/dmx-guest-0.1.0.tar.gz` from it; `tools_url` lists and installs from `<url>/<upstream name>` (unit test with an unreachable upstream, 37 unit tests); a non-http URL is refused with `bad_config_value`. Selftest ok. |
| 2026-10-25 | 0.2.0 release checks, load 2.6–3.4 | Unit 37/37, selftest ok, daemon 41/41, MCP 30/30, x86 16/16, Docker 63/63 (idle without Docker 75 MB, dockerd idle 283, one container 257; warm hello-world 195 ms), sandbox 41/41. Oops reproduction: 25 rounds of boot, first Docker use and the idle sweep at load 2.3–27, no oops, `dmx status` always answered. Release directory: guest 61.7 MB, binary tarball 1.7 MB (signed, notarized), sources 467 MiB. |
| 2026-10-25 | Stuck agent | Control calls time out after 60 s (`agent_timeout`) and the connection is shut down and replaced. With the agent paused 75 s by SIGSTOP from inside the guest: `dmx status` answered in at most 2.1 s, the daemon logged the reconnect, and exec and guest stats worked once the agent ran again. Now a daemontest check (42/42). Selftest ok, MCP 30/30, Docker 63/63, sandbox 41/41, unit 37/37 at load 1.3–3. |
| 2026-10-25 | Boot-time e2fsck | Initramfs 2.06 → 2.19 MB (e2fsck and its config, deleted after mount with mke2fs). Selftest before/after, three runs each: footprint 87–89 / 89–90 MB, boot 231–248 / 227–247 ms (load ~1.3). An error recorded with `trigger_fs_error` forced a check at the next boot that cleared it; a superblock with a bad checksum made `e2fsck -p` give up (exit 8) and `e2fsck -fy` repaired it from a backup in a 1.07 s boot, files intact. Without `broken_system_clock` every boot would force a full check: the guest clock reads 1970 until the host sets it. daemontest 44/44. |
| 2026-10-25 | Growing the data disk | 2G → 64G with a file on it: grown at boot, file kept, `df` 64,367 MB, host allocation 8 MB, boot + first exec 190 ms (120 without growth). Growing in a thread let the first command still see the old size, so the agent grows before it listens. daemontest 46/46 (64G → 80G; 16G afterwards leaves 80G). Selftest 88–90 MB, boot 231–250 ms. |
| 2026-10-25 | Guest DNS through macOS's resolver | The Mac's own `cothis-mac.local` (multicast DNS only) resolves in the guest to its LAN address and 192.168.127.254 (its loopback, translated); `www.github.com` returns the CNAME and the address; glibc (debian:13-slim `getent`) and musl containers resolve both. A name that does not exist: empty NOERROR (`getent` exit 2). 20 lookups in one exec: 1.7 ms each for github.com, 2.2 ms for a two-CNAME chain (cached by mDNSResponder). daemontest 48/48, Docker 63/63, sandbox 41/41, MCP 30/30, unit 38/38, selftest 89 MB. A VPN's per-domain resolver could not be created without admin rights; mDNS names exercise the same path (answers only mDNSResponder has). |
| 2026-10-25 | Sockets, xattrs and stored ownership on shares | Host costs (C, APFS): fstatat 1.0 µs; `listxattr` 1.6 µs; `getxattr` ~8 µs whether the attribute exists or not; open + `fsetxattr` + close 50 µs. So the owner is looked for with `listxattr` first (lookup in the server 1.8 → 3.6 µs, 2.3 µs once cached by ctime) and stored only when it differs from the default. A first version mapped the host group separately, so in `/tmp` (group wheel) tar's chown to 0:0 stored an xattr on every file: untar 3.1 → 4.0 s, `find` 0.06 → 0.19 s. With the host user's files always 0:0 and the cache: 9,200 files in a share, old / new, load 4: untar 2.5–4.1 / 2.5–3.7 s, `find` 0.07–0.08 / 0.06–0.08, `ls -lR` 0.09–0.10 / 0.08–0.09, read all 0.9–1.4 / 0.8–1.4, rm 0.7–1.5 / 0.7–1.0; cold (caches dropped) `find` 0.05–0.12 / 0.07–0.10. Answering GETXATTR made the guest ask for `security.capability` before every write (2 extra round trips per file); `HANDLE_KILLPRIV_V2` removes them (untar 3.5 → 3.0 s). postgres:17-alpine with its data directory in a share: before, `initdb: could not access directory: Permission denied`; after, starts and serves queries. Selftest 89 MB, daemontest 48/48 (one earlier run had 3 network timeouts that did not recur), dockertest 65/65 (2 new), unit 42/42. |
| 2026-10-25 | The Mac's SSH agent in containers | A non-root container user (`-u 1000`) lists the keys of an agent the daemon's `SSH_AUTH_SOCK` names; with no `SSH_AUTH_SOCK` and `launchctl getenv` empty (a shell outside the login session), the socket of macOS's `com.openssh.ssh-agent` job answers ("The agent has no identities"). Old / new guest, same host binary, three rounds after one exec: host 82/82, 79/79, 84/84 MB, guest used 37/36, 33/34, 39/44 MB (noise); selftest 86–93 MB. dockertest 66/66 (new `ssh_agent`), daemontest 48/48. |
| 2026-10-25 | CNAME answers without the address | daemontest's `dns_cname_chain` failed once: `www.github.com` came back with its CNAME and no address, for A and AAAA alike. After a CNAME, HostDNS waited only 1.5 s for the record it leads to, so a slow uncached target was answered with the chain alone. On a working network mDNSResponder sends the target's record, or that it has none, at once (A, AAAA and NXDOMAIN all 0.00 s in the guest), so the grace bought nothing: a CNAME now waits up to the query's 5 s timeout. Also: dockertest's `one_container` footprint read 478–530 MB with the new bind and SSH checks running just before it; measured before them again it is 270 MB (0.2.0: 257). |
| 2026-10-25 | 0.2.1 release checks, load 1.2–3.3 | Unit 42/42, selftest ok (86 MB), daemon 48/48 (one run before the CNAME fix failed `dns_cname_chain`; after it 48/48), MCP 30/30, x86 16/16, Docker 66/66 (idle without Docker 79 MB, dockerd idle 285, one container 270; warm hello-world 180 ms), sandbox 41/41. Release directory: guest 61.8 MB, binary tarball 1.8 MB (signed, notarized), sources 467 MiB (21 packages). |
| 2026-10-25 | IPv6 in the guest network, load 5–6.5 | On this Mac (no IPv6 default route, a Tailscale ULA only): ping fd64:646d:7800::1 0.12 ms, ::254 0.15 ms, the Mac's Tailscale address 0.35 ms; 64 MB over HTTP from the Mac's ::1 at 250–528 MB/s (IPv4 the same run 434–540); UDP echo and AAAA lookups over the gateway's IPv6 address; google.com's AAAA left out (no route). Neighbor entries for ::1 and ::254 REACHABLE. Containers: on a `--ipv6` network a container reaches the Mac's ::1 through dockerd's NAT66 (`ip6tables` on by default now), `getent ahosts host.docker.internal` lists IPv4 first; default-bridge containers unchanged. The first UDP replies were dropped by the guest (Udp6InCsumErrors): IPv6 forbids a zero UDP checksum, so dmx now computes it for UDP over IPv6. Memory: selftest 88–92 MB (86–93 before); dockerd idle 267/266 MB with `ip6tables` on, 267/266 with it off, guest used 79–85 vs 82–84 MB: no cost. Unit 42/42, daemon 50/50 (one earlier run failed with its output lost; three runs after it passed), MCP 30/30, x86 16/16, Docker 67/67, sandbox 41/41. |
| 2026-10-25 | ICMP errors to the guest, load 6–10 | A TCP connect to 2001:4860:4860::8888 (no IPv6 route on this Mac) and to 240.0.0.1 fails in the guest at once with "Host is unreachable" (before: "Connection refused"); a closed port on the Mac's 127.0.0.1 and ::1 over connected UDP raises ConnectionRefusedError in 0.0 s in a python:3-alpine container on an IPv6 network (through Docker's NAT and NAT66), instead of the 3 s timeout. TCP to a closed port is still refused by reset. Unit 42/42, selftest 87 MB, daemon 52/52 (new `icmp_errors`, `tcp_unreachable`), MCP 30/30, x86 16/16, Docker 67/67 (idle without Docker 78 MB, dockerd idle 214, one container 284), sandbox 41/41. |
| 2026-10-25 | IPv6 port forwarding | `dmx port add 18780:80` answers on ::1 (daemontest `portfwd_ipv6_loopback`); `-p 20081:80` and `-p 127.0.0.1:20082:80` answer on [::1] (`published_ipv6`); a published UDP port echoes over ::1 (`udp_ipv6_loopback`). Port forward throughput 289 MB/s guest to host, 338 MB/s host to guest (load ~8). Docker 69/69, daemon 52/53: `fsck_repaired` failed, see the next row. |
| 2026-10-25 | Guest kernel stack overflow, reproduced | The boot that runs `e2fsck -fy` after a corrupted superblock (daemontest `fsck_repaired`) hung: "Insufficient stack space to handle exception", `kworker/6:1` (`mm_percpu_wq`), pc `el1h_64_sync`, lr `__switch_to+0xe0`, sp at the bottom of the task stack while the frame pointer is at its top: a synchronous exception taken over and over in a context switch until the stack ran out. A loop of corrupt-and-boot (throwaway `DMX_HOME`, shares off) hit it on the second boot. Likely the unexplained daemontest failure earlier the same day. Not caused by the network work (no network code runs there). Resolved: see "cause and fix" below. |
| 2026-10-26 | Guest memory corruption under host memory pressure: cause and fix | The kernel stack overflow and the other oopses (NULL `list_head`s in `anon_vma_clone`, `free_pgtables`, `page_vma_mapped_walk`, a zero PTE under a vmalloc'd stack, two CPUs overflowing at once) were guest memory read back as zeros. They came only while the Mac swapped: 0 of 44 fsck boots under busy loops, an 8 GB compressible hog or heavy disk writes; 10 of 10 with an 11 GB incompressible hog (14 % free, 10 GB swap), files on the data disk lost too. Ruled out one by one under pressure: free page reporting and balloon releases (still 4 of 8 with them and the mapping remap off), the `HostMappings` remap, virtio-mem (5 of 10 at `memory=1G`), MMIO misrouting (no unhandled accesses logged). Turning off `F_NOCACHE` on the data disk: 0 of 18 against 18 of 28 with it. Fix: a bounce buffer in virtio-blk: 0 of 36 under pressure. 1 GB in the guest with direct I/O, clean main against the fix (load 4–12): writes 2.0–2.5 → 2.1 GB/s, 1 MB reads 0.91–1.0 → 1.8 GB/s, 4K reads 70–86 → 91–95 MB/s. virtio-fs O_DIRECT reads now come from the Mac's cache: 6.2–6.4 GB/s (3.1 before), writes 2.1 GB/s. A false lead on the way: reads past the used part of the disk differed from zeros, but those were ext4's bitmaps and backup superblocks, not corruption. Checks after the fix: unit 42/42, selftest 91 MB, daemon 53/53, MCP 30/30, x86 16/16, Docker 69/69 (dockerd idle 288 MB, one container 287, warm hello-world 159–176 ms), sandbox 41/41, `make pressuretest` passes (the old build fails it: 3 of 12 rounds). |
| 2026-10-23 | Console on a tty | stdin shares a file description with stdout, which the serial attachment makes non-blocking; the stdin reader must handle EAGAIN |
| 2026-10-26 | 0.2.2 release checks, load 1.2–2.0 | Unit 42/42, selftest ok (91 MB), daemon 53/53, MCP 30/30, x86 16/16, Docker 69/69 (idle without Docker 79 MB, dockerd idle 293, one container 267), sandbox 41/41. daemon's `portfwd_footprint_after_streams_mb` read 1671 MB: the memory checks' 1.5 GB was still coming back (766 → 119 MB within 2 s when sampled); the test now waits for it, 123 → 127 MB across 400 MB of port forward streams. Release directory: guest 61.8 MB, binary tarball 1.8 MB (signed, notarized), sources 467 MiB (21 packages). |
| 2026-10-26 | 0.2.2 as a user gets it | `make pressuretest` with the release binary: 12 of 12 rounds intact (12 GB hog, 34 % free, 3.4 GB swap used). From a local server: guest download and selftest (94 MB), install.sh, `spctl` accepts it as Notarized Developer ID. From GitHub: `curl … install.sh \| sh` installs 0.2.2, the first boot downloads the v0.2.2 guest, selftest ok (97 MB). 13 assets. Release notes gained a "Changes since 0.2.1" section (SHA256SUMS updated for NOTES.md). |
| 2026-10-26 | Engine comparison on a quiet Mac (load 1.0–1.6), 2 CPUs/4 GiB, three rounds | Median idle: dmx 198, OrbStack 530, Colima 1093, Docker Desktop 1053 MB. Holding 2 GiB: 2380 / 2614 / 3132 / 3225 MB. After freeing: 342 / 546 / 3138 / 3223 MB; dmx back in 1.9 s, OrbStack 5.4 s, the VZ engines not within 10 s. Warm `docker run` 101 / 95 / 52 / 67 ms; SHA-256 of 256 MiB 853 / 1261 / 806 / 818 ms. Idle CPU 1.4 / 0.6 / 0.6 / 0.4 % of one core. dmx v0.2.1 against v0.2.2 alternating, three each: idle 182–297 vs 187–284 MB, CPU 1.4–1.6 vs 1.3–1.9 %, so neither the idle CPU nor the occasional ~100 MB higher idle is new in 0.2.2 ([raw](measurements/2026-10-26-engine-comparison.json)). Engines installed temporarily and removed. |
| 2026-10-26 | What a dmx VM does at idle, 2 CPUs, dockerd up | Process CPU 1.0–1.5 % of one core with dockerd, 0.23 % without. In the guest (`/proc/*/task/*/schedstat`, 30 s): 110 ms of CPU over both vCPUs, dockerd and containerd ~60 ms; timer interrupts 40/s, IPIs 11/s. The vCPUs never leave `hv_vcpu_run` for WFI or the vtimer on macOS 26.6 with the in-kernel GIC (0 such exits counted; Hypervisor.framework waits in the kernel), so the 1 ms WFI cap is never reached: caps of 1, 10 and 100 ms gave the same CPU. MMIO exits ~50/s (data disk, balloon stats, vsock). `HostMappings` remaps 0.3/s, 0.6–6 ms per 10 s; turning them off changed nothing measurable. The cost was the idle trim repeating: 124 MB at the first trim, then 33–51 MB every 5–20 s, which dockerd and containerd read back (35 MB of disk reads in 30 s). |
| 2026-10-26 | Idle trim once per idle spell | Alternating with 0.2.2, four rounds, CPU from 35 to 65 s after `docker info`: 1.05–1.23 % → 0.77–0.83 %, trims in that window 4 → 1, footprint 181–205 → 193–199 MB. `benchmark.py`, three runs: idle CPU 0.57 % (0.55–0.72; 1.4 % before), idle 195–200 MB, `docker run` 95–106 ms, 2 GiB held 2391 MB, 353 MB after freeing it (342 before) in 2.0–5.4 s. Unit 42/42, selftest 90 MB, daemon 53/53 (`memory_idle_trim_s` 10.1), Docker 69/69 ([raw](measurements/2026-10-26-idle-cpu.json)). |
| 2026-10-26 | FEX-Emu first try (FEX-2610, glibc build in an Ubuntu container, software TSO), best of 3 | Same x86 Alpine root, ms, QEMU → FEX: busybox sha256 of 100 MB 1027 → 496, gzip -1 100 MB 6617 → 1576, python3 start 114 → 74, python3 loop 4446 → 680, node start 385 → 658, node JIT loop ~3400 → ~3900. With TSO emulation off (the ceiling hardware TSO can reach): sha256 403, python loop 410. RSS: `sleep` 8.7 vs 5.8 MB, python 21 vs 23 MB. |
| 2026-10-26 | Hardware TSO in a Hypervisor.framework guest (M4, macOS 26.6.1) | The guest sees MIDR implementer 0x61 (Apple). With Asahi's four TSO patches the kernel detects "TSO memory model (Apple)" and `PR_SET_MEM_MODEL` works with no VMM change. Message-passing litmus (2 threads): 18–52 reorderings per run in the default model, 0 in TSO, five runs each ([raw](measurements/2026-10-26-hardware-tso.json)). Each guest ACTLR_EL1 access traps (~0.7 µs): the patches as written read and write it on every context switch, pipe round trip 950 → 3850 ns. Writing it only when the next thread's value differs: 994–1019 vs 1001–1027 ns without the patches at the same load; TSO↔TSO 1125 ns, TSO↔plain alternating 2670 ns. |
| 2026-10-26 | FEX as a static musl binary | glibc-only assumptions found by running it: a rwlock re-locked to check ownership (glibc returns EDEADLK, musl waits forever: every x86 program hung), `PTHREAD_STACK_MIN` 2 KB before FEX's stack pivot and a second `pthread_detach` of an exiting thread (both crashed threaded programs), the `getdents64` prototype (compile error). FEXServer cannot run in containers (no binary there, its abstract socket is per network namespace); dmx runs FEX without it. FEX needs `/proc`: without it (a bare chroot) it cannot reserve the address space above 2^47, x86 programs get `0xffff...` addresses and `ldd` fails; containers always have `/proc`. `make fex` 62–70 s (compile 65 s alone; 184 s with a kernel build beside it), 5.7 MB, two builds same sha256. |
| 2026-10-26 | x86test with both emulators, load 2–6 | 36/36. FEX / QEMU: 100 MB sha256 390–400 / 1000–1010 ms (native 310: 1.3× / 3.0–3.3×), python loop 190–193 / 1663–1696 ms, python3 start 66–70 / 110–116 ms, node start 650–660 / 366–373 ms, `true` 3 / 2–3 ms, x86 `sleep` RSS 5 / 5 MB, idle 96–99 / 92–97 MB, footprint after the x86 work 275–292 / 227–231 MB, after cleanup 115–138 / 126–127 MB. FEX's hardware TSO check: `PR_GET_MEM_MODEL` 1 in an x86 process ([raw](measurements/2026-10-26-x86test-fex-qemu.json)). |
| 2026-10-26 | Image matrix amd64, FEX and QEMU | 9/9 with each; workload FEX / QEMU: python 0.40 / 1.06 s, postgres 2.84 / 5.17 s, Temurin 2.65 / 3.91 s, node 1.05 / 0.97 s, the rest within 0.05 s. arm64 9/9 on the TSO kernel; no kernel problems ([compatibility.md](compatibility.md#amd64-through-fex-emu-2026-10-26)). |
| 2026-10-26 | Unpacking the x86 emulators at boot | selftest boots a fresh data disk, so it pays the unpack each time: idle 78 MB without docker.img, 88–91 with qemu alone, 105 with both emulators unpacked (dropping the page cache afterwards changed nothing: freed pages, not cache), 94–97 unpacking only FEX. The daemon's data disk keeps the unpacked copy, so this happens once per version. docker.img 53.3 → 54.3 MB (x86 tar 2.1 MB xz). |
| 2026-10-26 | Gates with FEX, the TSO kernel and the ACTLR fix | Unit tests pass, selftest 94 MB, daemon 53/53 (`dns_host_resolver` now compares with the Mac's own answer: on a LAN macOS answers its `.local` name with the LAN address, not loopback), x86 36/36, Docker 69/69, MCP 30/30, sandbox 41/41, image matrix 18/18. Kernel alone 315 s (3110 s with a FEX build in the daemon VM at the same time). |
| 2026-10-26 | FEX and setuid x86 programs (WORKORDER B1) | Confirmed, then fixed. binfmt's `C` flag runs FEX with the x86 file's credentials, and FEX read the caller's configuration for such an exec: as `nobody`, `FEX_OUTPUTLOG` made a setuid-root x86 program create a root-owned file at a path the caller chose, and a `FEX_APP_CONFIG` file the caller owned was parsed. The configuration also chooses the rootfs x86 libraries load from, so this was worse than QEMU's accepted `QEMU_LOG_FILENAME`. dmx's FEX now checks `AT_SECURE`: it drops every `FEX_*` variable from the environment and keeps only the built-in defaults and the system-wide config (no `$HOME/.fex-emu`, `FEX_APP_CONFIG`, Steam layers). x86test gained `fex.setuid_ignores_caller_config` and a control that shows the same program without setuid still writes the log: 38/38, selftest 96 MB, idle 100 MB (FEX), footprint after the x86 work 273 MB. FEX is `fex-2610-dmx2`. |
| 2026-10-26 | FEX without `/proc` (WORKORDER B2) | Fixed. FEX reserves [2^47, 2^48) from the gaps it reads in `/proc/self/maps`; without them upstream reserves nothing, and x86 programs got host addresses above 2^47 (`0xffff...`), which jemalloc and mimalloc abort on. dmx's patch probes for the gaps with `MAP_FIXED_NOREPLACE`, halving only the chunks that come back EEXIST, and keeps a 64 MB readable-writable window below the stack so it can still grow; if even that fails it writes a message and exits instead of running with the wrong layout. In a chroot with `/proc` unmounted: `user_space_47bit=True` and all 11 page checks pass, jemalloc and mimalloc pass, x86 `sleep` 6.3 MB RSS over 61 mappings. The probe costs 31 ms per x86 process (x86 `true` 3 → 34 ms), so it stays the fallback; containers always have `/proc`. x86test gained `pages_4k_without_proc` for both emulators: 40/40, selftest 95 MB. FEX is `fex-2610-dmx3`. |
| 2026-10-26 | Hardware TSO across CPU hotplug (WORKORDER B3) | Holds, in both directions. A native message-passing litmus (`measurements/tso-litmus.c`, built static with Alpine clang in a dmx VM; writer and reader pinned to cpu8 and cpu9): default model 2.39M reorderings per 4M iterations, TSO 0. After taking both vCPUs offline and online, eight TSO runs: 0 each. A plain run on the same freshly onlined vCPUs still reorders (1.5M, 1.7M), so the kernel does not leave TSO on either. A TSO litmus of 60M iterations while its two vCPUs were offlined and onlined six times under it: 0 reorderings, all vCPUs back online. The VMM's `ACTLR_EL1` reset on CPU_ON and the kernel's cached value agree, because a CPU going down always switches to its idle task first ([raw](measurements/2026-10-26-tso-hotplug.json)). |
| 2026-10-26 | pressuretest on the FEX and TSO guest (WORKORDER B3) | 12 of 12 rounds intact (12 GB incompressible hog, 32 % free, half the cores busy, e2fsck boots). The new kernel's context switch path and the VMM's CPU_ON reset did not disturb the bounce-buffered virtio-blk. |
| 2026-10-26 | Release dry run, 0.3.0-rc (WORKORDER B3) | Found a bug: `source_bundle`'s FEX loop shadowed its `path` parameter, so `make release` had failed with `AttributeError` since FEX landed (`ed5bd64`); nothing after the guest archive was written. Fixed, then packaged with `--ad-hoc`: guest 62.9 MB, binary 1.8 MB, sources 496 MB (21 packages, was 467 MB), 52 packages listed, 15 license texts and every id in THIRD_PARTY.md's table has one (0BSD and BSL-1.0 are new, from rpmalloc and range-v3 in FEX). The source bundle carries `fex/` (FEX plus its seven submodules, dmx's patch, the build script) and `linux/asahi-tso/` (four patches). NOTES.md still has no change summary; 0.3.0 needs it written by hand. Output deleted, nothing tagged, the version and guest pin restored. |
| 2026-10-26 | Node's slow start under FEX (WORKORDER R1) | The cost was multiblock compilation of 5000-instruction superblocks out of code that runs once, not the JIT, SMC tracking, TSO or threads (`--jitless` 616, `FEX_SMCCHECKS=0` 636, `FEX_TSOENABLED=0` 646, `UV_THREADPOOL_SIZE=1` 650 ms, all unchanged). `FEX_MULTIBLOCK=0` gives 199 ms but costs CPython 2.8× (1M-iteration loop 193 → 540 ms), so multiblock stays on and the block cap `MaxInst` becomes 150 instead of 5000 (build-time default in `build-fex.py`). Alternating A/B under load: node start 666–763 → 260–295 ms, node's JIT loop 3938–4342 → 3583–3814 ms, python start, python loop, imports and a 100 MB sha256 unchanged. x86test 40/40 with node start 260 ms against QEMU's 386; amd64 image matrix 9/9 (node 1.05 → 0.76 s, Temurin 2.65 → 2.08 s, postgres and python unchanged). Footprint after the x86 work fell with it: 275–302 → 240 MB (QEMU 225), which is most of R2 ([raw](measurements/2026-10-26-maxinst.json)). selftest 95 MB, dockertest 69/69. FEX is `fex-2610-dmx4`. |
| 2026-10-26 | FEX's extra guest memory (WORKORDER R2) | Explained and mostly gone with R1. The bulk was the code caches of 5000-instruction superblocks: x86test's footprint after the x86 work 275–302 → 240 MB (QEMU 225). Per process FEX is now the cheaper of the two: an x86 python holding 100 MB has RSS 117.8 MB over 69 mappings against QEMU's 126.2 MB over 43. What is left is timing, not memory: after a mix of x86 work, cleanup and `drop_caches`, FEX reads 180 MB and QEMU 176, and once the idle sweep has run both sit at 80 and 79 MB. |
| 2026-10-26 | TSO switch cost on a real workload (WORKORDER R3) | 0.78 µs per memory-model change, and only when x86 and native threads share a vCPU. An x86 `dd` piping 80 MB to a native `cat`, one vCPU, 38,000 context switches: 68–69 ms with hardware TSO against 38–39 ms with `FEX_TSOENABLED=0`, which is (69−39) ms / 38.3k = 0.78 µs each; two x86 processes (no model change) 45–46 ms; native to native 29–30 ms. With all ten vCPUs online the switches drop to 6,500 and the TSO and non-TSO runs are the same (33–34 ms). Accepted in Decisions rather than fixed, since the fix would slow native code ([raw](measurements/2026-10-26-tso-switch-and-unpack.json)). |
| 2026-10-26 | First boot's unpack and the idle footprint (WORKORDER R4) | The freed pages come back at the first idle sweep: fresh-disk boot 98–99 MB, then 85–87 MB five seconds later and flat after that. Two fixes were tried and measured away: `compact_memory` in /init right after the unpack changed nothing (selftest 96–100 MB; the pages are not in the buddy allocator's lists yet), and compaction in the idle sweep (plus a 4 MB touch to wake free page reporting, 4 ms in the guest) gained 2 MB on a fresh boot and nothing after heavy x86 work, so neither was kept. A manual compaction a minute after boot still finds 2–4 MB, which is the ceiling here. Accepted in Decisions. |
| 2026-10-26 | The idle footprint that read ~100 MB high (WORKORDER O1) | Explained: it is where the reading falls in dmx's idle cycle, not lost memory. With dockerd up the footprint stays at ~260 MB until the idle trim and sweep fire 30 s after the last activity (5 s tick, the host has it ~2 s later), drops to 185–205 MB, then creeps to 210–225 MB as dockerd and containerd read files back. One run sampled every 8 s: 259.5 MB at 8, 16, 24 and 32 s, 189 MB at 40 s, with guest used 65–66 MB the whole time. Twelve runs with the old fixed 35 s settle: 203 MB once (its longer image pull pushed the reading past the trim) and 265–276 MB the rest. `benchmark.py` now samples 35, 50, 65, 80 and 95 s and reports `idle_at_35s`, `idle_min` and `idle`: three runs gave floors 191/194/204 MB, steady 226/216/224 MB, idle CPU 0.44–0.53 %. Guest compaction from the idle sweep was tried again here (it looks like an 80 MB win in the pre-trim state) and dropped: A/B with the same build gave floor 191–204 and steady 216–225 MB with it against 184–186 and 213–214 without ([raw](measurements/2026-10-26-idle-readings.json)). README and benchmark.md quote the 35 s definition, so the steady state is ~20 MB above the published 198 MB: a rerun of the four-engine comparison is the maintainer's call. |
| 2026-10-26 | Cephes' exact terms (WORKORDER I2) | FEX links ten of Stephen L. Moshier's Cephes files for x87 long double maths (`sinll`, `tanll`, `atanll`, `exp2ll`, `log2ll`, `floorll`, `polevll`, `constll`, `mtherr` and FEX's `Impl.cpp`; the symbols are in dmx's binary), releases 2.0 to 2.3, Copyright 1984–1995 Stephen L. Moshier. Netlib's terms are "What you see here may be used freely but it comes with no support or guarantee"; the author gave written permission to license it as BSD ("BSD license is fine, modification is OK"), and FEX's `External/cephes/LICENSE` quotes that e-mail in full. THIRD_PARTY.md now says all of this instead of "BSD licensed". |
| 2026-10-26 | 32-bit x86 under FEX (WORKORDER I1) | Blocked on FEX, not on dmx. The binfmt entry works (`FEX-x86`, ELFCLASS32 and `EM_386` with the same mask as the 64-bit entry, registered for FEX only), but every 32-bit program dies with `E NoExec instruction in entry block: FFFFF000` and SIGSEGV: FEX starts at the page its 32-bit allocator marks as taken, so the program's ELF was never mapped. Same for Alpine's static PIE busybox (ET_DYN, entry 0x1b44f) and for the dynamically linked busybox of the x86 minirootfs in a chroot with `/proc`; unchanged by `FEX_MAXINST=5000`, `FEX_MULTIBLOCK=0`, `FEX_SMCCHECKS=0`/`2`, `FEX_TSOENABLED=0` and `FEX_ROOTFS`. The code was reverted; the pinned and signature-checked 32-bit inputs and the next debugging step are in WORKORDER I1. |
| 2026-10-26 | 32-bit x86 images work (WORKORDER I1, fixed) | The crash was FEX's fallback vsyscall page: with no VDSO thunk (dmx builds none) FEX writes `int 0x80` into a page of its own and leaves it read-only, so the first syscall a 32-bit program makes through `AT_SYSINFO` hit a page FEX tracks as non-executable — `NoExec instruction in entry block: FFFFF000`, which is that page's address, not a failed mapping. dmx's patch maps it read-execute and tells FEX's VMA tracking (`AddVirtualPage`). `/init` registers `FEX-x86` (ELFCLASS32, `EM_386`) when the emulator is FEX; with QEMU the entry stays out, since `qemu-x86_64` cannot run those programs. x86test 44/44, including a pinned 32-bit Alpine root (static busybox, the dynamic one through `ld-musl-i386.so.1`, i386 `sleep` 5 MB RSS, `true` 3 ms). Image matrix 24/24 with all three platforms on a quiet Mac: the six images that publish 386 pass, Redis's jemalloc and PostgreSQL included ([raw](measurements/2026-10-26-images-all-platforms.json)). `test-images.py` gained optional platforms and `--pin-optional`, so adding one does not move the pins already measured. FEX's `uname -m` says `x86_64` even for a 32-bit process (QEMU's i386 says `i686`); written down in compatibility.md. FEX is `fex-2610-dmx5`. |
| 2026-10-26 | 0.3.0 release and its verification | Signed and notarized, published as [v0.3.0](https://github.com/cothis/dmx/releases/tag/v0.3.0) with 14 assets (binary 1.8 MB, guest 62.9 MB, sources 496 MB, 21 packages). Gates before it: unit 42/42, selftest 97 MB, daemon 53/53, MCP 30/30, x86 44/44, Docker 69/69, sandbox 41/41, pressure 12/12, image matrix 24/24. `make release` ran twice with `pin_changed` false on the second, so the tag builds the binary that was published. NOTES.md gained a hand-written "Changes since 0.2.2" section and SHA256SUMS was recomputed for it. From a local server: guest download, boot and selftest ok (101 MB), install.sh installs and `spctl` says Notarized Developer ID. From GitHub as a user: install.sh, `guest fetch`, selftest 96 MB, the `FEX-x86` binfmt entry present, and `docker run` on all three platforms (arm64, amd64, 386). |
| 2026-10-26 | Engine comparison with 0.3.0 (maintainer asked to re-measure) | Quiet Mac (load 1.0–1.7), one engine at a time, three rounds alternating, the same Docker Desktop and OrbStack installers as before (sha256 match), Colima from Homebrew. Medians: idle steady state dmx 222 MB, OrbStack 379, Colima 1100, Docker Desktop 1026; dmx's floor 194 MB. Idle CPU dmx 0.40 % of one core, now the lowest of the four (1.4 % in 0.2.2), against 0.53 / 0.67 / 0.46. Holding 2 GiB: 2390 / 2693 / 3160 / 3154 MB; ten seconds after freeing it: dmx 356 MB (back in 2–5 s), the others still holding. Longer probes: OrbStack returns it by 20 s, Colima still holds 3100 MB at five minutes, Docker Desktop holds 3117 MB at five minutes and then its Resource Saver stops the VM (258 MB at six minutes). `docker run` 104 / 97 / 52 / 63 ms; 256 MiB SHA-256 847 / 1334 / 795 / 819 ms. README and benchmark.md now quote the steady state with the floor beside it ([raw](measurements/2026-10-26-engine-comparison-0.3.0.json)). The three engines were removed afterwards. |
| 2026-10-26 | Updating an installed dmx | Before this there was no update path but re-running `install.sh`, and nothing said that the daemon already running keeps serving the old version: measured on a 0.2.2 → 0.3.0 update, the old daemon (pid, version 0.2.2) answered every command, `dmx stop` only powered the VM off, the daemon exited ~10 s later (its linger), and the next command started 0.3.0 and fetched the matching guest. `dmx update` now does the whole thing: resolve the newest release from GitHub's `releases/latest` redirect (a mirror needs `--version`), check the archive against the published `.sha256`, run the unpacked binary to confirm the version, rename it over the running file, then quit an idle daemon (`handover: quit`) or say `stop_to_switch` when the VM is up. It refuses a `.build` binary (`update_source_build`) and an unwritable directory (`update_not_writable`), both with hints. Every command now prints a two-line notice when the daemon answering is another version. daemontest gained four checks (57/57): the plan, the source-build guard, a copy of the binary really updated to 0.2.2, and the notice. |
| 2026-10-26 | 0.3.1 release and its verification | Signed and notarized, published as [v0.3.1](https://github.com/cothis/dmx/releases/tag/v0.3.1) with 14 assets; it ships `dmx update` and the notice about a daemon from another dmx. Gates: unit 42/42, selftest 97 MB, daemon 57/57, MCP 30/30, x86 44/44, Docker 69/69, sandbox 41/41. Two release runs, `pin_changed` false on the second. NOTES.md's "Changes since 0.3.0" written by hand, SHA256SUMS recomputed. From a local server: boot `--selftest` ok (98 MB), install.sh installs, `spctl` says Notarized Developer ID. As a user: 0.3.0 installed from GitHub has no `update` (as README says), `install.sh` from `releases/latest` takes it to 0.3.1, `dmx update --check` then answers "0.3.1 is the newest release", and a real `dmx update --version 0.3.0` with the VM up installed it and reported the handover rather than touching the VM. |
| 2026-10-26 | 0.3.2: four things the releases showed were missing | (1) A release whose boot files are unchanged is no longer downloaded again: the pin and the receipt both carry each file's sha256, so comparing them is free. Measured on the published releases: `dmx update` from 0.3.1 to 0.3.2 moved 1.86 MB instead of 64.7 MB, kept the guest, rewrote `release.json` to v0.3.2 and booted on it; a guest whose files differ (0.2.2's) still downloads. (2) `dmx update` checks the download's Developer ID against the running binary's and runs `codesign --verify`: from the published 0.3.2 it reports `signature: V4YA23448U`, and a build from source reports that it skipped the check instead of claiming a match. (3) `docs/release-notes/<version>.md` holds the change summary and `release.py` folds it into NOTES.md before writing SHA256SUMS, which 0.2.2, 0.3.0 and 0.3.1 had done by hand; packaging without notes is refused. (4) `dmx doctor` names the daemon and, when it is from another dmx, says what to do. Gates: unit 46/46, selftest 97 MB, daemon 57/57, MCP 30/30, x86 44/44, Docker 69/69, sandbox 41/41. Published as [v0.3.2](https://github.com/cothis/dmx/releases/tag/v0.3.2) (the tag push needed a retry: GitHub answered 500 once). |
| 2026-10-27 | Review of the day's code by two other models | Asked Claude Sonnet 5.5 and Codex (`gpt-6.1-sol`, which answered "at capacity", then `gpt-6-astra`) to review `1d2614c..5b054be` adversarially. Both found the same two worst defects in `dmx update`, which 0.3.2 shipped: (1) the downloaded binary was **executed** by `check(binary:is:)` before its signature was checked, so a release server could run code as the user and only then be rejected; (2) `handOver` treated every state that was not `running` — including `starting`, `stopping` and a `status` call that failed — as idle and sent `quit`, which powers the VM off, so an update could kill a booting VM and its containers. Also found: concurrent updates shared `downloads/update-<version>` so one could install what the other had not verified; a `dmx` symlink inside the archive would have made every check read the binary being replaced and the rename would have replaced it with a link to itself; `--version` was unvalidated although it reaches a URL, a directory name and a `removeItem`; an update with no version named would silently downgrade a dmx newer than the newest release; `writeReceipt` was not atomic, and a truncated `release.json` makes a downloaded guest look locally built, which dmx never replaces; the `/proc`-less address-space probe split on ENOMEM, which under an `RLIMIT_AS` means ~68 billion mmap calls; `AT_SECURE` still left FEX reading `$HOME/.fex-emu/ThunksDB.json` through `GetConfigDirectory`; x86test ignored whether its `umount /proc` worked; and test-images.py passed when an explicit `--image`/`--platform` pair had no pins. All fixed: signature (now with a `codesign -R` requirement tying it to Apple's anchor and the team, not a string compare) before execution, no `quit` at all, per-process work directory, archive member must be a plain file, `^\d+\.\d+\.\d+(-…)?$`, a SemVer ordering check, atomic receipt, ENOMEM stops the probe, the three FEX directory functions answer with the system-wide path under `AT_SECURE`, and both tests now fail when the thing they check breaks. Gates after: unit 48/48, selftest 97 MB, daemon 57/57, MCP 30/30, x86 46/46, Docker 69/69, sandbox 41/41. |
| 2026-10-27 | The reviews' second half | Sonnet's findings 7–17 after the first message was truncated, each checked against the code: `try? verify.run()` followed by `waitUntilExit()` would have raised and ended dmx if codesign could not start; two errors had no hint, against the project's own rule; the signature branches had no test, so the decision is now a pure function (`teamToRequire`) with one test per combination; the `_exit(1)` for an empty reservation also fired on the procfs path, where upstream runs with the host allocator, so it is now scoped to the probe path; the `.sha256` parser mismatched a file holding only the digest and an uppercase one; `setAttributes(0o755)` ran before the plain-file check, so a symlink member would have been chmod'd through; the staged copy was not re-hashed before the rename; `dmx doctor` dropped its daemon check silently when the daemon spoke another protocol, which is exactly what it should report; `release.py` raised AttributeError if the version line were reformatted; and the setuid control proved nothing about `$HOME/.fex-emu/Config.json` because the environment layer wins — x86test now has two controls (47/47, one per source). Gates after: unit 49/49, selftest 94 MB, daemon 57/57, Docker 69/69, MCP 30/30, sandbox 41/41, x86 47/47. FEX is `fex-2610-dmx8`. |
| 2026-10-27 | 0.3.3 release and its verification | Signed and notarized, published as [v0.3.3](https://github.com/cothis/dmx/releases/tag/v0.3.3) with 14 assets: the two security defects the reviews found in 0.3.2's `dmx update` and the fifteen smaller ones. Gates: unit 49/49, selftest 94 MB, daemon 57/57, MCP 30/30, x86 47/47, Docker 69/69, sandbox 41/41. Two release runs, `pin_changed` false on the second; NOTES.md's change summary came from `docs/release-notes/0.3.3.md` with nothing edited by hand. Local server: boot `--selftest` ok (100 MB), install.sh, `spctl` Notarized Developer ID, SHA256SUMS 10/10. As a user: 0.3.2 from GitHub updated itself to 0.3.3 (1.86 MB; its guest did change this time, so the 62 MB came too), the published 0.3.3 then ran the hardened signature check on a downgrade to 0.3.2 and reported team V4YA23448U, selftest from GitHub 98 MB, `dmx doctor` names the daemon, and `docker run` works on arm64, amd64 and 386. |
| 2026-10-27 | Pre-announcement review of 0.3.3 | Six code findings fixed, stale docs corrected. Unit 59/59; selftest 23/23; daemon 57/57; MCP 33/33; x86 47/47; Docker 69/69; sandbox 44/44; image matrix 24/24; pressure 12/12 rounds (12 GiB host allocation). Selftest host footprint 97 MiB before, 94–97 after; final 1 GiB reclaim 1123 → 103 MiB in 329 ms (before 1122 → 102 in 214 ms). Published 0.3.3 installer, guest fetch, strict signature/notarization check, selftest (97 MiB) and signed same-version update pass; local guest hashes match published. [Review](review-2026-10-27.md), [bounded results](measurements/2026-10-27-preannouncement-review.json). These fixes are not released. |

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
- 2026-10-23: Idle footprint at 8G from 173 to 145 MB, under the phase 4 target: fixed kernel hash sizes, finer free page reporting, capped per-CPU page lists, no apk in the guest.
- 2026-10-23: Streaming through vsock no longer grows dmx's memory with the bytes passed (500 MB: 637 → 157 MB peak).
- 2026-10-23: Transparent huge pages only on madvise: with 32 MB huge pages, a sparse 1 GB heap cost 1 GB instead of 0.6 MB.
- 2026-10-24: Slabs capped at 32 KB: idle at 8G 146 → 141 MB.
- 2026-10-24: Kernel config trimmed to what dmx and Docker use: idle at 8G 141 → 120 MB, kernel build 19 min instead of 2 h 21 min.
- 2026-10-24: VMM fixes: vCPUs come back after CPU_OFF, no lost virtio interrupts on ack, a stopped VM closes its vsock streams.
- 2026-10-24: The unexplained 24 MB turned out to be guest pages `mincore` misses. Linear map in blocks and small atomic DMA pools: idle at 8G 120 → 112 MB.
- 2026-10-24: One memory zone in the guest kernel; idle 111 MB at 8G.
- 2026-10-24: Kept kernel text protected in the linear map (no `rodata=noalias`); idle 115 MB at 8G.
- 2026-10-24: Phase 5 done. `dmx daemon` boots the VM on first use and stops it when idle; `dmx exec`, `shell`, `start`, `stop`, `status`, `config`, `install` (launchd socket activation). Ctrl-C now reaches guest processes.
- 2026-10-24: `make install`. Phase 4 memory work and phases 6 and 9 started in parallel worktrees.
- 2026-10-24: `dmx mcp` merged: AI clients run commands in the VM over MCP with capped output. Fixed truncated exec output after a vsock reset.
- 2026-10-24: Memory controller merged: idle page cache trims, zram on demand, balloon under host pressure. Phase 4 tasks done except the memmap.
- 2026-10-24: Guest networking merged: virtio-net and a user space NAT; the guest reaches the internet over HTTP.
- 2026-10-24: Port forwarding merged (`dmx port`), with two exec data-loss fixes.
- 2026-10-24: virtio-fs merged: host directories at the same path in the guest. Device interrupts now wake their vCPU.
- 2026-10-24: Maintainer: "Docker must just work; security like standard programs." Open decisions settled to Docker Desktop behavior (Decisions). Agents `double` (2x footprint of host-written guest pages) and `frag` (fragmented freed guest memory) started.
- 2026-10-24: Data disk merged; phase 6 done. Phase 7 (Docker) next.
- 2026-10-24: Idle sweep merged: guest memory freed in small blocks goes back to macOS when idle.
- 2026-10-24: x86_64 binaries run in the guest through qemu-x86_64 and binfmt_misc; THP off.
- 2026-10-24: Phase 7 done: the stock docker CLI and Compose work against `~/.dmx/docker.sock` (`make dockertest`). Pages devices touch are no longer counted twice (idle 99 MB). An interrupted first-boot format is redone.
- 2026-10-24: Maintainer: no GitHub CI and no Homebrew. Agents `cli`, `gaps`, `reuse`, `memmap`, `phase9`, `release` started.
- 2026-10-24: `dmx tools` (docker CLI, Compose, Buildx without Homebrew; BuildKit builds) and release groundwork (guest download, `make release`, install.sh) merged.
- 2026-10-24: Phase 9 done: sandboxes with policies and TTLs, checkpoints, fork, rollback and logs, in the CLI and over MCP.
- 2026-10-24: virtio-mem merged: the guest boots with 1 GB and plugs the rest on demand; idle ~80 MB at any ceiling (8G was 107, 16G 145).
- 2026-10-24: Docker gaps closed (UDP ports, taken-port errors, restart policies at boot, qemu in docker.img); reused guest pages counted again (`MADV_ZERO`); smaller rx ring. daemontest updated for virtio-mem.
- 2026-10-24: Flaky sandboxtest fixed: a macOS socketpair bug lost EOF wakeups of blocking reads; all socket reads poll first. A sandbox exec no longer lets its stdin writer outlive the stream.
- 2026-10-24: The socketpair EOF-wakeup bug reported to Apple (FB25307646).
- 2026-10-24: Phase 4 follow-ups done: status exposes hotplug RAM, critical pressure unplugs spare RAM before balloon fallback, and allocations still grow RAM under pressure. Refreshed README, the daemon protocol and stale PLAN entries; tracked phase 6 extensions and phase 10 image/benchmark validation explicitly.
- 2026-10-25: Ran the 9×2 pinned image matrix; switched to 4K pages for Python/Java and real 4K mapping/guard semantics. Fixed slow page reporting and normal hotplug metadata return; 2 GB containers return within 10 s at both the 4G comparison profile and default 8G profile. Added raw evidence, a benchmark harness with checked Mach-time CPU accounting, and source-patch release notices. Redis amd64's default QEMU layout and unavailable comparison engines remain open; no public release made.
- 2026-10-25: Added HANDOFF.md and linked it from Next up so a new session can continue directly with the pinned amd64 Redis reproduction, verified memory gates and remaining release work. Documentation only; no new runtime validation claimed.
- 2026-10-25: Fixed the default amd64 Redis crash: dmx builds qemu-x86_64 from pinned QEMU 11.0.3 with Alpine's patches and a 2^47 x86_64 guest base (`make qemu`). Image matrix 18/18; x86test checks the address range and jemalloc/mimalloc; release packager ships the QEMU recipe and its static libraries' licenses. Remaining phase 10 work needs maintainer decisions.
- 2026-10-25: Cross-engine comparison against Docker Desktop, OrbStack and Colima (installed briefly, then removed); dmx lowest at idle and under load and returns memory within seconds. README gained a Docker trademark notice. Release recommendation written for the maintainer.
- 2026-10-25: Released v0.1.0 on GitHub (binary, guest, 467 MiB source bundle); installed and booted from GitHub as a user would.
- 2026-10-25: Profiled warm `docker run`: the gap to Colima is data disk barrier flushes; plain fsync would close it but risks the disk on a power cut, so the barrier stays (maintainer). dockerd now runs in its own cgroup, so `--memory` limits swap without a warning. Next: boot-time fsck.
- 2026-10-25: Phase 11 (work Macs) started: README rewritten for users and company reviewers, SECURITY.md and private vulnerability reporting, repository topics. Maintainer: announce to communities after more improvements.
- 2026-10-25: dockerd reads the user's Docker Engine settings from `~/.docker/daemon.json` like Docker Desktop (mirrors, insecure registries, proxies), under dmx's own keys.
- 2026-10-25: dockerd uses the Mac's proxy and its added root certificates; `dmx status` no longer hangs on a stuck agent; a dangling guest link no longer loops guest downloads. Developer ID certificate created and release.py signs and notarizes; the next release is the first notarized one.
- 2026-10-25: Download mirrors as settings (`release_url`, `tools_url`) for company networks. Phase 11 done except a test on a real corporate network; next is the 0.2.0 release.
- 2026-10-25: Released v0.2.0, the first Developer ID signed and notarized release, with the work-Mac features; installed and booted from GitHub as a user would.
- 2026-10-25: A stuck guest agent no longer wedges the daemon: control calls time out after 60 s and the connection is replaced (daemontest pauses the agent to check). The oops's cause stays open. Next: boot-time fsck.
- 2026-10-25: The data disk is checked with e2fsck at every boot and repaired unattended when needed. Next: data disk resizing.
- 2026-10-25: Raising `disk_size` grows an existing data disk at the next boot, online. Next: split DNS for company VPNs.
- 2026-10-25: Guest DNS goes through macOS's resolver: split DNS from VPNs, `.local` names, network changes. Next: Unix sockets and xattrs on shared files.
- 2026-10-25: Shared files: Unix sockets bind in shares, `user.*` xattrs, and ownership stored by chown and by non-root creators, so non-root containers can write to bind mounts (postgres data directory works). Next: the Mac's SSH agent in containers.
- 2026-10-25: The Mac's SSH agent is at `/run/host-services/ssh-auth.sock` in the VM, as on Docker Desktop; the vsock device accepts guest-initiated connections. Next: IPv6 in the guest network.
- 2026-10-25: A CNAME answer waits for the address it leads to (up to the query's 5 s), instead of answering with the CNAME alone after 1.5 s. Next: release 0.2.1.
- 2026-10-25: Released v0.2.1 (signed, notarized); installed and booted from GitHub as a user would. Next: IPv6 in the guest network.
- 2026-10-25: IPv6 in the guest network: a ULA prefix behind the NAT, NDP and ICMPv6 echo from the gateway, TCP/UDP onto the Mac's IPv6 sockets, unroutable AAAA records left out; Docker `--ipv6` networks work. Next: ICMP errors to the guest.
- 2026-10-25: ICMP errors to the guest: destination unreachable for TCP and UDP flows the Mac cannot reach and for closed UDP ports. Next: port forwarding on the Mac's IPv6.
- 2026-10-25: Port forwards listen on the Mac's IPv6 too (::1 with 127.0.0.1, :: with 0.0.0.0), TCP and UDP. A guest kernel stack overflow reproduces on fsck-repair boots. Next: that crash.
- 2026-10-26: The guest kernel crashes were guest memory corrupted by direct I/O on guest pages while the Mac swapped; virtio-blk now copies through a bounce buffer and virtio-fs ignores O_DIRECT on the host. `make pressuretest` keeps the reproducer. Next: release 0.2.2 (maintainer's call).
- 2026-10-26: Released v0.2.2 (signed, notarized) with the guest memory corruption fix and guest IPv6; installed and booted from GitHub. daemontest's port forward footprint now waits for the memory checks' memory to come back. Next: the engine comparison on a quiet Mac.
- 2026-10-26: Engine comparison rerun on a quiet Mac (Docker Desktop, OrbStack, Colima installed briefly, then removed): same picture with narrow ranges; README shows the new numbers. dmx's idle CPU is the highest of the four and predates 0.2.2. Next: what wakes dmx at idle.
- 2026-10-26: dmx's idle CPU came from the idle trim repeating (dockerd's file pages reclaimed and read back every few seconds); trimming once per idle spell takes it from 1.4 to 0.57 % of a core. The WFI cap and the mapping remaps were ruled out by measurement. Next: x86_64 images faster than QEMU (FEX-Emu, hardware TSO).
- 2026-10-26: x86_64 images run through FEX-Emu with the Apple CPU's hardware TSO (Asahi's kernel patches, ACTLR_EL1 written only when the memory model changes); QEMU stays as `x86_emulator qemu`. CPU-bound x86 code 2.5–9× faster, image matrix 18/18. Next: release 0.3.0 (maintainer's call).
- 2026-10-26: Maintainer: fix bugs and regressions before releasing. docs/WORKORDER.md lists them in order (FEX and setuid programs, FEX without /proc, unrun checks, node start, FEX memory, TSO switch cost, first-boot unpack, the high idle readings). Next: WORKORDER B1.
- 2026-10-26: WORKORDER B1 fixed: FEX took its configuration from the caller even for a setuid x86 program, which binfmt's `C` flag runs with the file's credentials. dmx's FEX now honours `AT_SECURE` (no `FEX_*` variables, no user config), x86test checks it with a control, and docker.md says so. Next: WORKORDER B2 (FEX without `/proc`).
- 2026-10-26: WORKORDER B2 fixed: without `/proc` FEX reserved nothing above 2^47 and x86 programs got addresses they cannot hold; dmx's FEX now probes for the free parts with `MAP_FIXED_NOREPLACE` (31 ms per process, only on that path) and refuses to run if it cannot. x86test checks the layout and both allocators in a chroot without `/proc`. Next: WORKORDER B3 (pressuretest, TSO with CPU hotplug, release dry run).
- 2026-10-26: WORKORDER B3 done, P0 complete. pressuretest passes on the FEX and TSO guest (12/12); hardware TSO survives vCPU offline/online in both directions (native litmus, 0 reorderings against 2.4M in the default model); the release dry run found `make release` broken since FEX landed (a loop variable shadowed the output path) and now packages FEX's sources, the Asahi patches and the new licenses. Next: WORKORDER P1 (node start under FEX).
- 2026-10-26: WORKORDER R1 fixed: node started slowly under FEX because multiblock compiled 5000-instruction superblocks out of code that runs once. A translated block now holds 150 x86 instructions (build-time default), so node starts in 260 ms against QEMU's 386, its JIT loop is 8 % faster, nothing measured got slower, and the memory FEX held after x86 work fell from 275–302 to 240 MB. Next: WORKORDER R2 (the 15 MB that is left).
- 2026-10-26: WORKORDER P1 finished. R2 was the superblock code caches R1 removed (x86test footprint after x86 work 275–302 → 240 MB; per process FEX is now cheaper than QEMU, 117.8 vs 126.2 MB, and both end at 80 MB after the idle sweep). R3 measured: 0.78 µs per TSO↔plain switch, 69 vs 39 ms on one vCPU for a pipe-bound x86-to-native workload, no difference when vCPUs are free; accepted. R4 measured: the unpack's pages come back 5 s after boot, and both compaction fixes tried were worth 0–2 MB, so accepted. Next: WORKORDER P2 (the occasional ~100 MB high idle).
- 2026-10-26: WORKORDER P2 explained: the ~100 MB high idle readings were taken before the idle trim, which returns ~70 MB 30 s after the last activity; the footprint then settles ~20 MB above its floor as dockerd reads files back. `benchmark.py` samples 35–95 s and reports the floor and the steady state. Guest compaction was tried again and dropped on an A/B. Next: WORKORDER I1 (32-bit x86 images through FEX).
- 2026-10-26: WORKORDER I2 done: THIRD_PARTY.md now names the ten Cephes files FEX links, their copyright and releases, Netlib's "used freely, no support or guarantee" terms and the author's written BSD permission, instead of "BSD licensed". Next: WORKORDER I1 (32-bit x86 images through FEX).
- 2026-10-26: WORKORDER I1 attempted and reverted: the `FEX-x86` binfmt entry registers fine, but FEX never maps a 32-bit program's ELF (`NoExec instruction in entry block: FFFFF000`), for static PIE and dynamic programs alike and under every config knob tried. The reproduction, the pinned 32-bit Alpine inputs and the next debugging step are written down; x86test is green at 40/40 and node starts in 246 ms against QEMU's 370. The work order is now done except I1. Next: the maintainer's call on releasing 0.3.0.
- 2026-10-26: WORKORDER I1 done, work order finished: `linux/386` images run. FEX's fallback vsyscall page (used when there is no VDSO thunk) was mapped read-only, so every 32-bit program died on its first syscall; it is now read-execute and tracked as such. x86test 44/44 with a pinned 32-bit Alpine root, image matrix 24/24 across arm64, amd64 and 386 on a quiet Mac, selftest 97 MB, dockertest 69/69. Next: 0.3.0, which needs the maintainer's call to tag and publish.
- 2026-10-26: Released v0.3.0 (signed, notarized): FEX-Emu with hardware TSO for amd64 and 386 images, the idle CPU fix and everything the work order fixed. NOTES.md carries a hand-written change summary. Verified from GitHub as a user: install.sh, guest download, selftest 96 MB and `docker run` on arm64, amd64 and 386. Next: rerun the four-engine comparison with 0.3.0 and update the published idle numbers (maintainer asked for it).
- 2026-10-26: Re-measured the four-engine comparison with 0.3.0 on a quiet Mac (same installers by sha256, Docker Desktop with its Resource Saver left on). Idle steady state: dmx 222 MB against OrbStack 379, Colima 1100 and Docker Desktop 1026; idle CPU 0.40 % of one core, now the lowest of the four. README and benchmark.md quote the steady state with dmx's 194 MB floor beside it, and record that OrbStack returns 2 GiB by 20 s while the Virtualization-framework engines hold it for minutes. Engines removed afterwards. Next: the maintainer's call on announcing the project.
- 2026-10-26: `dmx update` added: it checks the newest release, verifies the published sha256, replaces the running binary and hands the daemon over (quits an idle one, tells you to `dmx stop` when the VM is up); every command now says when the daemon answering is another version, which is what made an update look like it had not taken effect. README has an Updating section, release.md documents the mechanism, and the version literal moved to `Sources/DMXCore/Version.swift` so the daemon client can compare it (release.py reads it there). daemontest 57/57, including a real update of a copied binary. Next: the maintainer's call on a 0.3.1 that ships it, and on announcing the project.
- 2026-10-26: Released v0.3.1 (signed, notarized): `dmx update`, the notice when the daemon answering is another dmx, and the daemontest additions. Verified as a user: 0.3.0 from GitHub has no `update`, `install.sh` from `releases/latest` takes it to 0.3.1, and from there `dmx update --check` and a real update behave as documented. Next: the maintainer's call on announcing the project.
- 2026-10-26: Released v0.3.2 with the four gaps the 0.3.0/0.3.1 releases exposed: no guest re-download when the boot files are unchanged (1.86 MB instead of 64.7 MB to update), a Developer ID check on what `dmx update` downloads, release notes kept in `docs/release-notes/` and folded into NOTES.md by `release.py`, and a daemon line in `dmx doctor`. A stray `scripts/__pycache__/*.pyc` from an earlier commit was removed and ignored. Next: the maintainer's call on announcing the project.
- 2026-10-27: Fixed the rest of what the two reviews found (Sonnet 7–17): a codesign launch failure could end dmx, two errors had no hint, the signature branches had no test, the hard exit for an empty reservation reached the procfs path, the `.sha256` parser was too strict, a symlink member was chmod'd before being rejected, the staged copy was not re-hashed, doctor hid a protocol mismatch, release.py could raise, and the setuid control proved only half of what it claimed. Everything verified: unit 49/49, x86 47/47, and the other five suites green. Next: the maintainer's call on releasing 0.3.3 with the update-path fixes.
- 2026-10-27: Released v0.3.3: the two security defects two independent reviews found in 0.3.2's update path (the downloaded binary was executed before its signature was checked; an update could stop a VM that was booting) and fifteen smaller ones. Verified from GitHub: 0.3.2 updates itself to 0.3.3, the hardened codesign requirement passes on the published binary, selftest 98 MB, containers on arm64, amd64 and 386. Next: the maintainer's call on announcing the project.
- 2026-10-27: Completed the pre-announcement review: fixed guest FUSE file/directory lifetime races, a read-only open mutating host modes, virtqueue address overflow, malformed allowlists, and oversized size/TTL conversions. Added regressions, refreshed README/release docs/help/HANDOFF, and reran the real-VM suites, 24-image matrix and 12 pressure rounds. No idle-memory increase observed (97 MiB before, 94–97 after). Published 0.3.3 still installs, verifies and boots; the new fixes await a patch release before community announcement.
- 2026-10-27: Maintainer authorized the release after documentation cleanup. Preparing v0.3.4 with the six pre-announcement review fixes and their regressions; release notes and install URLs are updated. Community posting remains a separate step.
- 2026-10-27: Completed v0.3.4 qualification after fixing FEX signal-return state and atomic instruction-word decoding. Added a deterministic signal regression and the 100-run Java gate, verified live emulator hashes, and recorded failed controls and the initial candidate-packaging error. All release suites passed; signing and publication remain next.

- 2026-10-27: Published signed/notarized v0.3.4 from 04ef90d. Verified all 14 uploaded/downloaded assets, fresh installation and selftest (97 MiB), update from a running 0.3.3 with VM/data preservation and new guest activation, and arm64/amd64/386 containers. Review, documentation and release are complete; community posting remains the maintainer’s decision.
- 2026-10-27: Java crash cause confirmed and a second FEX defect fixed. All six crash reports match a mixed decode of HotSpot's atomic method-entry patch (fault addresses and registers recomputed exactly). A new fixture fails 18/20 on the old FEX and the signal-only build and passes on the decoder fix, dmx9 and QEMU. FEX also kept running translations of code that changed between decoding and write protection (0/20 on dmx9). `fex-2610-dmx10` rechecks the decoded words once the pages are protected and redecodes; x86test gains both fixtures (53/53), image matrix 24/24, Java 100/100, selftest 96 MiB. Not released. Next: the maintainer's call on a patch release.
- 2026-10-27: Removed dmx10's compile cost: it re-protected already protected pages on every compile (262,144-block storm 318–324 ms against dmx9's 268–270). `fex-2610-dmx11` remembers protected pages until their next invalidation (248–259 ms), passes both fixtures and every suite, and is pinned for v0.3.5 (release notes written; the maintainer asked to release after the tuning). Next: package, sign, publish and verify v0.3.5.
- 2026-10-27: Published signed/notarized v0.3.5 (dmx11) from 610c3c5 at the maintainer's request. Second packaging kept the pin; the local rehearsal, the 14 uploaded and re-downloaded digests, a fresh install (selftest 94 MiB), an update from a running 0.3.4 that kept the VM and data and loaded dmx11 next boot, and arm64/amd64/386 containers all passed. Next: the maintainer's call on the community announcement.
- 2026-10-27: The idle sweep trims the data disk (FITRIM through a new agent call): one Mac's data.img held 5.9 GB for 260 MB of data because blocks freed without online discard (journal replay, e2fsck, a killed VM's lost discards) were never punched. daemontest's `disk_idle_trim` fails on the v0.3.5 guest and passes now (58/58); idle footprint unchanged at 97 MiB. Not released. Next: the maintainer's call on v0.3.6.
- 2026-10-27: v0.3.6 qualified with the idle disk trim: unit 59, selftest 23 (97 MiB, 1123 → 102 MiB in 320 ms), daemon 58, MCP 33, x86 53, Docker 69, sandbox 44, images 24, Java 100. The guest differs from 0.3.5 only in its initramfs (agent). Next: publish and verify v0.3.6.
- 2026-10-27: Published signed/notarized v0.3.6 (idle disk trim) from 14d7866. Second packaging kept the pin; local rehearsal (selftest 97 MiB), the 14 uploaded and re-downloaded digests, a fresh install, an update of a running 0.3.5 (VM and data kept, new guest next boot, idle trim logged in 32 ms) and arm64/amd64/386 containers passed. Next: the maintainer's call on the community announcement.
- 2026-10-27: `dmx tools install` (and so `dmx install`) replaces a `~/.local/bin` link that points at nothing instead of skipping it, and `dmx tools ls` calls such a link broken. On one Mac a deleted temporary DMX_HOME had left `docker` dangling, so after removing Homebrew's docker the install would have left no `docker` at all. Links that still resolve stay untouched. Unit 60/60 (the new test fails on the old code), dockertest 69/69. Not released.
- 2026-10-27: Re-measured dmx alone with the 0.3.0 comparison's protocol (v0.3.6 guest, three rounds, load 1.1–1.4): idle 222 MB, floor 193, idle CPU 0.37 %, 2 GiB held 2389 → 358 MB in 2 s, `docker run` 102 ms, SHA-256 839 ms, all within the 0.3.0 ranges. README notes it; the other engines were not re-measured.
- 2026-10-27: v0.3.7 qualified (dangling docker link fix, README signing section, benchmark re-check; guest byte-identical to 0.3.6): unit 60, selftest 23 (95 MiB, 1123 → 102 MiB in 101 ms), daemon 58, MCP 33, x86 53, Docker 69, sandbox 44, images 24, Java 100. Next: publish and verify v0.3.7.
- 2026-10-27: Published signed/notarized v0.3.7 from b4f9da0. Second packaging kept the pin; local rehearsal (selftest 96 MiB), 14 uploaded and re-downloaded digests, a fresh install (97 MiB), an update of a running 0.3.6 that kept VM, data and the unchanged guest, the published binary replacing a dangling docker link, and arm64/amd64/386 containers passed. Next: the maintainer's call on the community announcement.
- 2026-10-27: `dmx install` failed on another Mac ("launchd did not start the daemon") although launchd ran the daemon. Reproduced here as a race: `launchctl bootout` returns while the old daemon is still exiting (over a second when it powers a VM off), so the immediate bootstrap fails with EIO or loads a job whose socket does not answer yet, and install tried to connect exactly once. With the VM up before each run, 0.3.7 installed 5/10 (all failures `Bootstrap failed: 5: Input/output error`). install now waits until launchd has let go of the job and its process, retries bootstrap on EIO for 5 s and connects for up to 10 s, and its error names the connect errno and launchd's job state: 10/10 with the VM up, 10/10 without. Not released.
- 2026-10-27: v0.3.8 qualified (dmx install waits for launchd; guest byte-identical to 0.3.7): unit 60, selftest 23 (96 MiB, 1123 → 102 MiB in 321 ms), MCP 33, x86 53, Docker 69, sandbox 44, images 24, Java 100. daemontest's first run failed 6 network checks (DNS timeouts, the 64 MB HTTP download, IPv6) while the Mac's DNS switched to Tailscale's resolver mid-run; the rerun under the same network passed 58/58. Next: publish and verify v0.3.8.
- 2026-10-27: Published signed/notarized v0.3.8 from 7f32e3f. Second packaging kept the pin; local rehearsal (selftest 97 MiB), 14 uploaded and re-downloaded digests, a fresh install (96 MiB), an update of a running 0.3.7 (VM, data and unchanged guest kept), the dangling-link replacement and arm64/amd64/386 containers passed. The published binary then ran `dmx install` 5/5 with the VM up on this Mac. Next: the maintainer's call on the community announcement.
- 2026-10-27: Fixed a permanent guest receive stall: a user's Mac lost all guest networking (DNS, TCP) right after a fresh boot until the VM restarted, and daemontest's 6 failed network checks during v0.3.8's qualification were the same bug, not the DNS switch blamed then. With MTU 65520 a 64 KB frame could wait for receive buffers Linux adds only after it receives something (it refills only once more than 32 of the 64 slots are empty; buffers are at least 1536 bytes), and every frame behind it waited too: logged as "head frame 65546 bytes; guest posted 59360 bytes in 38 buffers". The MTU is now 49126, so the largest frame always fits the 32 x 1536 bytes always posted; a frame over it is dropped instead of blocking. Fresh boots with a 1 MiB download each: 0.3.8 stalled 3/300, the fix 0/900 (Fisher p = 0.016). Host to guest 64 MB: 440-467 MB/s (0.3.5-0.3.8: 453-506), memory unchanged; daemontest 58/58 twice, unit 61. Codex (gpt-6-astra) independently ranked the same deadlock first and cited the Linux 6.18 refill and min-buffer code. Not released.
- 2026-10-27: v0.3.9 qualified (MTU 49126 against the receive deadlock; guest byte-identical to 0.3.8): unit 61, selftest 23 (97 MiB), daemon 58 (64 MB at 501 MB/s), MCP 33, x86 53, Docker 69, sandbox 44, images 24, Java 100. The suite's selftest returned 1 GiB in 2062 ms, against 101-423 ms before; three reruns took 314-325 ms with the Mac at load 2.7-3.7, and the change does not touch memory, so it is recorded as an outlier. Next: publish and verify v0.3.9.
- 2026-10-27: Published signed/notarized v0.3.9 from 1051460. The first packaging failed because I had removed the temporary DMX_HOME it reads the guest from, and the release commit was made without the pin; it was amended before any push. Second packaging kept the pin; local rehearsal (selftest 97 MiB), 14 uploaded and re-downloaded digests, a fresh install (97 MiB), an update of a running 0.3.8, the dangling-link replacement and arm64/amd64/386 containers passed, then the published binary started 300 fresh VMs with a 1 MiB download each without a stall. Next: the maintainer's call on the community announcement.
- 2026-10-27: `dmx install` links `~/.docker/run/docker.sock` (Docker Desktop's path) to `~/.dmx/docker.sock`, keeping a socket another engine serves; `dmx uninstall` removes only its own link. A user's tool failed on Docker Desktop's hardcoded paths while the docker CLI worked through the context. Unit test (free, taken, dead and dangling paths); on this Mac `dmx install` made the link, `docker -H unix://~/.docker/run/docker.sock version` answered 29.9.2 and `curl --unix-socket` `_ping` OK. No VM or memory change. Not released.
- 2026-10-27: v0.3.10 qualified (`~/.docker/run/docker.sock` link; guest boot files byte-identical to 0.3.9): unit 62, selftest 23 (96 MiB, 1122 → 101 MiB in 214 ms), daemon 58 (64 MB at 501 MB/s), MCP 33, x86 53, Docker 69, sandbox 44, images 24, Java 100. Next: publish and verify v0.3.10.
- 2026-10-27: Published signed/notarized v0.3.10 from aa061fc. Second packaging kept the pin; local rehearsal (selftest 23/23, 101 MiB) and install.sh from it; 14 uploaded and re-downloaded files byte-identical to the local ones; a fresh install from GitHub (selftest 23/23, 101 MiB, guest v0.3.10 downloaded); `dmx update` of a running 0.3.9 with a container (stop_to_switch, container kept, volume data kept, the unchanged guest not downloaded); arm64, amd64 and 386 (LONG_BIT 32) containers; the published `dmx install` made the link on a free path and replaced a dangling one, and docker and curl `_ping` answered through it. The guest receipt still names v0.3.6 (recorded in Next up). Next: the maintainer's call on the community announcement.
- 2026-10-27: A boot now records the new tag when a release keeps the boot files (the receipt had stayed at v0.3.6 through 0.3.7-0.3.10). Unit 63 (the new test fails without the change); a copy of this Mac's v0.3.6 guest booted with downloads blocked: selftest 23/23 (97 MiB), receipt, `dmx guest` and `dmx doctor` say v0.3.10. Not released.
