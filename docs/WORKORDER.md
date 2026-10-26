# Work order: fix bugs and regressions before the next release

Written 2026-10-26, after FEX-Emu became the default x86 emulator (`ed5bd64`). The maintainer
asked for bug fixes and improvements first; 0.3.0 waits until this list is done or each
remaining item is written down as accepted. Work top to bottom. Each item says what is known,
what is only suspected, where to look and when it is done.

Rules for every item (on top of [AGENTS.md](../AGENTS.md)):

- One heavy job at a time: `make kernel`, `make fex`, the image matrix, a build inside the daemon
  VM. Two VMs sharing the cores made a kernel build take 3110 s instead of 315 s and made every
  measurement in that window useless. Stop and remove experiment containers and images when done.
- Reproduce first, then fix, then add a check to the test that would have caught it.
- Measure before and after on the same load (alternate A/B when the host is busy) and record the
  numbers in PLAN.md's findings.
- Changes to FEX go into `FEX_PATCH` in `scripts/build-fex.py`; kernel changes into
  `scripts/build-kernel.py`. Rebuild with `make fex` / `make kernel`, then `make guest`.

## P0: correctness and security

### B1. FEX honoured `FEX_*` variables and `~/.fex-emu` for setuid x86 programs (fixed 2026-10-26)

- **Known.** binfmt_misc registers FEX with flag `C`, so a setuid x86 binary runs FEX with the
  file's credentials (as with QEMU, see the binfmt rows in PLAN.md). FEX reads its configuration
  from `FEX_*` environment variables and `$HOME/.fex-emu/Config.json`
  (`Source/Common/Config.cpp`, `FEXCore/Source/Interface/Config/Config.cpp`) and nowhere checks
  `AT_SECURE`. The kernel sets `AT_SECURE` for such an exec.
- **Suspected.** An unprivileged user in a container can make a setuid-root x86 program load
  code they control, e.g. `FEX_ROOTFS=/tmp/evil` (library lookups go through the rootfs) or a
  thunk/config path. That is worse than QEMU's accepted `QEMU_LOG_FILENAME` exposure, which only
  writes a file.
- **Check.** In x86test, as `nobody`, run a setuid-root x86 program (copy the x86 busybox, chmod
  4755, owner root) with `FEX_ROOTFS` pointing at a directory the user owns holding a different
  musl loader, and with `HOME` at a directory holding a `.fex-emu/Config.json`. See whether either
  takes effect.
- **Fix if confirmed.** In `FEX_PATCH`: when `getauxval(AT_SECURE)` is set, ignore `FEX_*`
  variables and the user config (keep the built-in defaults). Keep the `C` flag (Docker Desktop
  behaviour); do not drop setuid support.
- **Done when** the check above is a permanent x86test check that passes, and docker.md's binfmt
  paragraph says what FEX ignores for setuid programs.
- **Done (2026-10-26).** Confirmed: as `nobody`, a setuid-root x86 busybox honoured
  `FEX_OUTPUTLOG` (a root-owned file at a path the caller chose) and parsed a `FEX_APP_CONFIG`
  file the caller owned. `FEX_PATCH` now checks `getauxval(AT_SECURE)` in two places: the
  interpreter drops every `FEX_*` variable from the environment before anything reads it, and
  `LoadConfig` keeps only the built-in defaults and the system-wide file (no `$HOME/.fex-emu`,
  `FEX_APP_CONFIG` or Steam layers). The `C` flag and setuid support stay. x86test:
  `fex.setuid_ignores_caller_config`, plus `fex.setuid_control_reads_config` so the check cannot
  pass for the wrong reason. 38/38, selftest 96 MB; FEX is now `fex-2610-dmx2`.

### B2. Without `/proc`, FEX hands x86 programs addresses above 2^47

- **Known (measured).** FEX reserves [2^47, 2^48) by reading `/proc/self/maps`. In a chroot
  without `/proc`, mmap returned `0xffff...` addresses and `ldd` failed. Containers always have
  `/proc`, so Docker is not affected; x86test now mounts it. jemalloc and mimalloc crash on such
  addresses (the Redis bug QEMU had).
- **Fix.** In `FEX_PATCH`: when `/proc/self/maps` cannot be read, reserve the upper half anyway by
  probing with `mmap(MAP_FIXED_NOREPLACE)` (FEXCore `Allocator.cpp`, `StealMemoryRegion`). If
  that is not possible, exit with a clear message rather than run with a wrong layout.
- **Done when** x86test has a second probe run in a chroot *without* `/proc` and it reports
  `user_space_47bit=True` (and jemalloc passes there too).

### B3. Checks not yet run on the FEX and TSO guest

- `make pressuretest` (guest memory and disk integrity while the Mac swaps). The kernel's context
  switch path and the VMM's CPU_ON reset changed; run it with the current build. It slows the Mac
  for a few minutes and must run alone.
- CPU hotplug with a TSO thread: take vCPUs offline and online while an x86 program with TSO
  runs (selftest's `cpu_hotplug` covers only native code). The VMM resets `ACTLR_EL1` on CPU_ON;
  confirm the program keeps TSO after it migrates (litmus test from PLAN's hardware TSO row,
  `docs/measurements/2026-10-26-hardware-tso.json`).
- `make release VERSION=0.3.0-rc` into `.build/dist` without uploading: it now packages FEX's
  sources and licenses and the Asahi patches, and has not run since. Check THIRD_PARTY.md, the
  LICENSES/ list (0BSD and BSL-1.0 are new) and the source bundle's `fex/` and `linux/asahi-tso/`.
  Delete the rc output afterwards; do not tag.
- **Done when** all three are recorded in PLAN.md's findings, with any failure fixed or filed
  here.

## P1: regressions FEX brought

### R1. Node starts slower under FEX (650 vs 370 ms for `node -e 0`)

- **Known.** x86test, two runs each; QEMU 366–373 ms, FEX 650–660 ms. The image matrix's node
  workload is level (1.05 vs 0.97 s). The cause is not measured.
- **Look at.** FEX's self-modifying-code handling (`SMCChecks`, default `mtrack`: V8 writes and
  patches code), `Multiblock`, and whether the time is in translation or in signals/mprotect
  (the guest has no `perf`: time the phases with FEX's own stats or by bisecting its config). Try FEX config values through `FEX_*` variables first; a default that helps goes into
  the binary as a build-time default, not an environment variable.
- **Done when** node start is at most QEMU's, or the reason it cannot be is written down with
  numbers.

### R2. FEX keeps more guest memory after x86 work

- **Known.** x86test footprint after the x86 work: FEX 275–292 MB, QEMU 227–231 MB; after
  cleanup and drop_caches: FEX 115–138 MB, QEMU 126–127 MB (two runs). Per-process RSS is the
  same (`sleep` 5 MB).
- **Look at.** Where the extra 50–60 MB is while x86 programs run (FEX code caches, its
  allocator's arenas; `smaps_rollup` of a running x86 python), and whether it all comes back once
  they exit (it should: the processes are gone). Compare the idle sweep's result a minute later.
- **Done when** the difference is explained, and either reduced or accepted in PLAN.md's
  decisions with the numbers.

### R3. Switching between TSO and non-TSO threads costs ~0.8 µs per switch

- **Known.** Pipe round trip 1001–1027 ns between plain processes, 1125 ns between two TSO
  processes, 2658–2686 ns when a TSO and a plain process alternate on one CPU: each `ACTLR_EL1`
  write traps to Hypervisor.framework.
- **Look at.** Whether real x86 workloads alternate like that (an x86 container talking to a
  native dockerd or containerd shim over a pipe on the same CPU). Measure with the image matrix
  and a busy x86 container before optimising. Leaving TSO on for a native thread would be safe
  (TSO is stricter) but slows native code, so measure that trade too before changing anything.
- **Done when** measured on a real workload and either fixed or accepted in PLAN.md.

### R4. Unpacking the emulator at first boot leaves freed guest pages

- **Known.** selftest (fresh disk every time) idle: 78 MB with no emulator, 88–91 MB qemu only,
  94–97 MB FEX only. Dropping the page cache afterwards changed nothing, so it is freed memory in
  blocks free page reporting misses. The daemon unpacks once per version.
- **Look at.** Unpacking with less memory churn (unxz with a smaller buffer, or `dd` with
  `iflag=direct`), or letting the idle sweep run before selftest measures.
- **Done when** selftest idle is within 2 MB of the qemu-only number, or this is accepted.

## P2: open items from before

### O1. Idle footprint that sometimes reads ~100 MB high

Phase 10's open task: 2 of 9 benchmark runs before the idle trim fix, 0 of 3 after. Reproduce
with `make benchmark` repeated (at least 10 runs on a quiet Mac), and when a high run happens,
capture the guest's `/proc/meminfo`, `/proc/pagetypeinfo` and the per-CPU free lists before the
VM stops.

## Improvements after the bugs

- **I1. 32-bit x86 images (`linux/386`).** FEX runs them; register `FEX-x86` too (FEX's own magic
  and mask), add a 386 case to x86test and the image matrix. QEMU users keep x86_64 only, or add
  qemu-i386 if it is cheap.
- **I2. cephes license.** The THIRD_PARTY entry quotes FEX's "BSD licensed" note. Find the exact
  terms of the cephes files FEX vendors and record them precisely.

## Then

Release 0.3.0 (maintainer's call to tag and publish): idle CPU fix, FEX with hardware TSO,
whatever this list fixed. Write the "Changes since 0.2.2" section in NOTES.md by hand as for
0.2.2.
