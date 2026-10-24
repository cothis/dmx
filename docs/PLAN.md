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
| The daemon exits when idle; the CLI starts it if launchd does not (2026-10-24) | An idle dmx should cost nothing, not even a 4 MB daemon. `dmx install` is optional: without it `dmx exec` still just works, which matters for agents. One daemon per `DMX_HOME`, enforced by a lock file. |
| Docker from a read-only image unpacked onto the data disk, started on first use (2026-10-24) | Docker is ~170 MB unpacked: in the initramfs it would sit in guest RAM. A pinned image on a read-only disk is unpacked only when its sha256 changes, and dockerd starts only when `docker.sock` is first used, so a VM nobody runs Docker in costs nothing extra. |
| Drop dmx's own mappings of guest RAM after device traffic (2026-10-24) | macOS charges a page to `ri_phys_footprint` once per mapping; guest RAM is mapped by dmx and by stage 2, so pages a device filled counted twice (1 GB read = +2 GB). Remapping dmx's view onto itself (`mach_vm_remap` overwrite) after traffic leaves one mapping; devices fault pages back in. |
| Transparent huge pages off in the guest (2026-10-24) | With 16K pages a huge page is 32 MB. `madvise` (2026-10-23) still let qemu's 128 MB code buffer take 32 MB per x86 process (`sleep` 38 MB RSS, 5.4 MB without); nothing in dmx needs huge pages. Replaces the `madvise` choice. |
| Guest network is a user space NAT inside dmx, not vmnet (2026-10-24) | vmnet needs root or `com.apple.vm.networking`, which Apple grants on request (verified: an ad-hoc process gets VMNET_FAILURE, the entitlement gets it killed). Guest flows map onto host sockets like passt: no TCP stack, no second process, bounded buffers, and traffic is dmx's own so VPNs and firewalls apply. Costs: IPv4 only, no ICMP errors; inbound goes through vsock port forwarding. |
| Defaults and security follow Docker Desktop (2026-10-24) | Maintainer's rule: Docker must just work, and security choices match standard tools. So: host directories shared read-write at the same path (Docker Desktop shares /Users, /Volumes, /private, /tmp, /var/folders; phase 7 matches that list), containers reach host services through a host alias (`host.docker.internal` in phase 7, today `host.dmx.internal`), ports bind 127.0.0.1 unless asked, host user ↔ guest root on shares, `init_on_alloc` on as in stock kernels, no TLS tools in the base guest (dockerd does its own TLS). Port forwards persist and keep the 4 MB daemon up while they exist. MCP tools are `dmx_*`, argv-based, 8 KiB/120 s defaults. |
| No GitHub CI, no Homebrew dependency (2026-10-24) | Maintainer's choice: GitHub is only for distribution (source and releases). Checks run locally before a release (`make build`, `swift test`, selftest, daemontest, dockertest). dmx ships its own pinned Docker CLI tools instead of relying on Homebrew. |
| dmx ships the docker CLI, Compose, Buildx and the keychain credential helper (2026-10-24) | Docker Desktop does, and users should not need Homebrew. Pinned upstream darwin-arm64 builds (the static CLI is trust-on-first-download: Docker publishes no checksum for it). Plugins through `cliPluginsExtraDirs`; no shell rc files edited. All Apache-2.0. |
| Sandboxes are containers in the one VM (2026-10-24) | No state of dmx's own to clean up (labels), egress rules inside each sandbox's namespace cover every protocol. Isolation is Docker's: a guest kernel exploit reaches the whole guest and its shares; per-sandbox VMs are a possible later step for hostile code. |
| Guest memory beyond 1 GB is hotplugged with virtio-mem (2026-10-24) | The memmap (struct page) costs ~4.7 MB of footprint per GB of ceiling whether used or not. Plugging on demand makes the ceiling free until used; the balloon still squeezes under host pressure. |
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
      current growth, unplug after 30 s with more than 1.5 GB available. The guest onlines plugged
      memory as movable (`memhp_default_state=online`, `online_policy=auto-movable`). Idle footprint
      ~80 MB at any ceiling. `CONFIG_VIRTIO_MEM` becomes built in on the next `make kernel`.
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
      swappiness 0). Warning: trim at once, then after 5 s idle; after a critical spell the balloon
      cap loosens to used + 1 GB. Critical: also push cold anonymous and tmpfs pages to zram and
      inflate the balloon to cap the guest at used + 256 MB, re-checked every 2 s. Normal again:
      deflate. `dmx status` shows a `memory` object; actions are logged with `memory:`.
- [x] Guest policy: zram swap (lz4, a quarter of the ceiling) turned on by the agent the first time
      the guest is squeezed or passes half its ceiling (at boot it costs ~3.5 MB);
      `vm.swappiness=100` and `vm.page-cluster=0` with it. Transparent huge pages off (`never`; was `madvise` until qemu's code buffer took 32 MB per x86 process).
      `init_on_alloc` stays on: on dmx's VMM inflating costs CPU (~1.5 s for 7.8 GB), not memory.
- [x] Freed guest blocks under 512 KB (after connection bursts, small-file work): when idle, the
      controller lowers free page reporting to order 0 (16 KB) and has every slab cache free its
      empty slabs (agent `reporting_order`, `shrink_slabs`); order 5 comes back on the next use.
      Footprint returns to idle + 1 to 6 MB; idle CPU unchanged. ~10 MB after network traffic stays
      (probably virtio-net rx buffers).
- [x] Host pressure drives the controller above. `memory_pressure -S` needs root, so tests use the
      daemon's `simulate_pressure` method.

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
      virtio-blk (`HV/VirtioBlock.swift`: `F_NOCACHE`, flush = `F_BARRIERFSYNC`, discard and
      write-zeroes punch holes, requests off the vCPU thread, image locked against a second VM).
      `/init` formats a blank disk with pinned e2fsprogs (deleted after mount), ext4 at /var/lib
      with discard; the agent freezes it before power-off. Left: fsck at boot, resizing.
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
      are returned as links, never followed; read-only enforced on the host; setuid/setgid dropped,
      chown a no-op. Host user ↔ guest root, others nobody. 1 s attribute cache (like virtiofsd
      cache=auto) plus a re-lookup when opening a file the host changed. `make test` covers hostile
      requests. Left: Unix sockets in a share, xattrs, ACLs, DAX, stored ownership.

Done when: the guest can `wget` from the internet, a guest web server is reachable on `localhost`, and a host directory is readable/writable in the guest.

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
- [x] x86_64 binaries through QEMU user mode: Alpine's static `qemu-x86_64` 11.0.3 (pinned, signature
      checked) registered with binfmt_misc, flags `POCF` (Docker Desktop uses `CF`; `P` keeps
      argv[0]). Carried compressed in the initramfs and unpacked onto the data disk on first boot
      or a version change, so it uses guest RAM only while x86 code runs (+~2 MB idle; moves to
      Docker's delivery later). Now carried at the end of docker.img instead (initramfs 3.1 → 2.1 MB). 16K pages: msync, mincore, MADV_DONTNEED, MAP_FIXED|MAP_SHARED and
      mprotect/munmap on single 4K pages misbehave (Findings). `make x86test`.
- [x] `make dockertest` (`scripts/test-docker.py`, 33 checks): hello-world, `run -it`, build, compose
      with a volume, a published port and a bind mount, idle stop with Docker, the context.

Done when: the test suite passes with the stock `docker` CLI.
Result: passes with Homebrew's docker 29.9.1 and Compose 5.6.0. Containers with a restart policy
come back at boot (agent `docker_autostart` reads dockerd's records; no dockerd otherwise); dmx
does not start at login, so after a Mac reboot they wait for the VM to boot. Earlier: `docker build` uses the legacy
builder unless `docker-buildx` is installed. Now: BuildKit through dmx's Buildx; `make dockertest` uses
only dmx's tools (43 checks).

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
      Still to come: logs and sandbox tools.
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
- [ ] First public release. Before it: versioning (SemVer `v0.1.0`?), GPL source (written offer
      vs attaching ~300 MB of sources), Developer ID signing (browser downloads are quarantined).
- [ ] Guest artifacts published as GitHub Releases, downloaded and verified by `dmx`, so users do not need Python.
      They contain GPL software (kernel, busybox, qemu-x86_64 "GPL-2.0-only AND LGPL-2.1-only"):
      ship license texts and the corresponding source or a written offer (qemu: QEMU 11.0.3 +
      Alpine aports 51049924607603c9d9b7132c187a7f31085d7a12). dmx stays Apache-2.0: these run as
      separate programs in the guest.
- [ ] Developer ID signing and notarization when distributing binaries (no Homebrew tap).

### Later, maybe

- macOS-native mode without a VM: sandbox profiles + APFS clones to isolate macOS programs (cannot run Linux images; weaker isolation).

## Next up

Phase 7 is done. Open items, roughly in order of value:
- Memory: plug state in `dmx status`; unplug (virtio-mem) instead of only the balloon under
  critical host pressure.
- Before a public release: compatibility of popular images with 16K pages, a comparison with
  Docker Desktop, OrbStack and Colima on a quiet Mac, Developer ID signing.
- Phase 10: guest artifacts as releases (GPL obligations noted there), an install script; no CI, no Homebrew.
- Re-measure timings on a quiet host: most of today's numbers were taken at load 15 to 90.

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
| 2026-10-24 | virtio-fs memory | Idle with a share 113 to 121 MB (116 to 121 without, noise). dmx's heap ~11 MB after repeated traffic. Reading 1 GB through the guest page cache costs 2 GB of footprint, all returned when the guest drops its cache; the same with writes and a bounce buffer, so pages the host writes into guest RAM seem to count twice. Unexplained; virtio-blk will likely show it too. |
| 2026-10-24 | Data disk (virtio-blk), load 6 to 25 | Initramfs 1.63 → 2.02 MB (mke2fs, deleted after mount; shmem unchanged). Idle footprint ~115 MB, unchanged within ~1 MB (118 without `no_prefetch_block_bitmaps`). Write 2 GB 1.1 to 1.2 GB/s, read 2.1 to 2.2 GB/s. Through the host cache: 323 MB/s write and +2 GB footprint (host cache charged to dmx), hence `F_NOCACHE`. 2 GB deleted: host allocation 1.9 GB → 11 to 22 MB in 0.08 to 0.17 s. Online discard costs 1.28 vs 0.48 s per GB deleted; without it nothing comes back until fstrim. 4K write + fsync 2.8 to 6.6 ms with barrier flush, 9.8 to 16.7 ms with `F_FULLFSYNC`. SIGKILL mid-write ×3: journal replayed, e2fsck clean. First boot formats in 0.3 to 0.9 s. |
| 2026-10-24 | Selftest under host load ~29 (several agents' VMs) | Agent up after 5 to 11 s instead of ~0.2 s; the 30 s and even 60 s selftest timeouts are hit, `--timeout 180` passes. Compare timings only on a quiet host. |
| 2026-10-24 | Fragmented free memory and the idle sweep, load 25 to 85 | Before: 500 forwarded connections 119 → 163 MB (free blocks of order 0 to 4 hold ~33 MB, slab +7 MB); untar/rm of 9,200 files in tmpfs 122 → 151 MB; 500 MB wget 117 → 136 MB. `page_reporting_order` is writable at runtime (0644): writing 0 gave 163 → 128 MB in ~10 s, then shrinking slabs 133 → 115 MB. With the sweep: connections 161 → 112 MB, untar/rm 150 → 113 MB, wget 134 → 125 MB (idle 107 to 112). A sweep takes 40 to 1050 ms wall, under 0.1 s daemon CPU. Idle daemon CPU per 60 s: 0.05 to 0.06 s (0.06 to 0.07 before). Order 0 always on showed no cost while busy, but the host was too loaded to be sure; not adopted. |
| 2026-10-24 | Guest soft lockup at host load 80 to 86 | Once, right after an untar/rm workload: `soft lockup - CPU#N stuck for 140s` in ksoftirqd/rcu_preempt on 6 vCPUs, daemon at ~40 % CPU. Not reproduced in 24 stress rounds. Suspected vCPU starvation on an overloaded host rather than the sweep; open. |
| 2026-10-24 | daemontest at host load 40 to 61 | The 500 MB stdout check took over 60 s (6 MB/s; 90 to 240 MB/s on a quieter host) for old and new builds alike. Test timeouts are now 300 s and a timeout fails its check instead of the script. |
| 2026-10-24 | x86_64 through qemu-x86_64, load 25 to 90 | Initramfs 2.03 → 3.09 MB. Idle +~2 MB (115 to 117 → 117 to 119), guest used unchanged; first-boot unpack leaves +4 to 8 MB of freed pages. x86 process RSS with THP madvise / never: `sleep` 38 / 5.4 MB, python3 43 to 47 / 15.7 MB, node 23.5 MB; x86 `true` 201 → 49 ms. Rough speed (loaded host): `true` 22 to 62 ms vs 1 to 6 native, sha256 1.8 to 4.5x native. Static, dynamic (chroot), python3 (ssl, sqlite, threads), node 24 (JIT, wasm) work. |
| 2026-10-24 | x86 programs on 16K guest pages | x86 code sees 4096-byte pages. Works: brk, MAP_PRIVATE at 4K offsets (copied, not shared), MAP_SHARED at 4K offsets without MAP_FIXED. EINVAL on a 4K page inside a 16K page: msync (Python `mmap.flush()`), mincore, MADV_DONTNEED (page not zeroed), MAP_FIXED|MAP_SHARED misaligned to 16K. Not enforced: mprotect and munmap of a single 4K page (guard pages fail silently). Likely victims: stack guards, LMDB-style msync databases, the JVM's 4K polling page (untested). |
| 2026-10-24 | binfmt `C` flag | As `nobody`, a setuid-root x86 binary with `QEMU_LOG_FILENAME=/root/x` creates a root-owned file: qemu honours `QEMU_*` while privileged. Docker Desktop's `CF` has the same exposure; kept to match it. |
| 2026-10-24 | Pages counted twice | Standalone test: 512 MB touched by host and guest = 1026 MB footprint whichever side goes first; a second mapping in one process without a VM (`mach_vm_remap` alias) does the same; the VM object held 512 MB. Dropping either mapping halves it. Fix: 1 GB virtio-fs read +2046 → +1024 MB; selftest idle 115 to 117 → 97 to 99 MB (the host's copies of kernel and initramfs had counted twice); idle footprint now equals the guest's own count (reserved + used). ~30 remaps per GB, 0.3 to 3 ms each. Side effect: a page only a device filled and the guest never touched is uncounted until touched (small with init_on_alloc on). |
| 2026-10-24 | Reusable pages re-dirtied by the guest | After `MADV_FREE_REUSABLE` and a full guest rewrite, footprint stayed 2 MB with 512 MB dirty, counted only once macOS paged them out. Real VM: a 500 MB refill came in ~50 MB short. Fix idea: keep released ranges out of stage 2 and `MADV_FREE_REUSE` them on the guest's fault. Open. |
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
