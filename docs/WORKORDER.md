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

### B2. Without `/proc`, FEX handed x86 programs addresses above 2^47 (fixed 2026-10-26)

- **Known (measured).** FEX reserves [2^47, 2^48) by reading `/proc/self/maps`. In a chroot
  without `/proc`, mmap returned `0xffff...` addresses and `ldd` failed. Containers always have
  `/proc`, so Docker is not affected; x86test now mounts it. jemalloc and mimalloc crash on such
  addresses (the Redis bug QEMU had).
- **Fix.** In `FEX_PATCH`: when `/proc/self/maps` cannot be read, reserve the upper half anyway by
  probing with `mmap(MAP_FIXED_NOREPLACE)` (FEXCore `Allocator.cpp`, `StealMemoryRegion`). If
  that is not possible, exit with a clear message rather than run with a wrong layout.
- **Done when** x86test has a second probe run in a chroot *without* `/proc` and it reports
  `user_space_47bit=True` (and jemalloc passes there too).
- **Done (2026-10-26).** `FEX_PATCH` adds a probe to `StealMemoryRegion`: where `/proc/self/maps`
  cannot be opened it reserves [Begin, End) with `MAP_FIXED_NOREPLACE`, halving only the chunks
  that answer EEXIST or ENOMEM, and maps the 64 MB below the stack pointer readable-writable (as
  the procfs path does for the gap under the stack) so the stack can still grow. If the host
  ignores the flag, nothing is reserved and `Setup48BitAllocatorIfExists` writes a message and
  exits. x86test's `pages_4k_without_proc` runs the page probe and both allocators in the chroot
  with `/proc` unmounted, for both emulators: 40/40. Cost: x86 `true` 3 → 34 ms without `/proc`,
  61 mappings and 6.3 MB RSS for an x86 `sleep`; unchanged with `/proc`.

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
- **Done (2026-10-26).** pressuretest: 12 of 12 rounds intact (12 GB hog, 32 % free). TSO with
  CPU hotplug: a native litmus (`docs/measurements/tso-litmus.c`) shows 0 reorderings in TSO
  against 2.39M in the default model, 0 across eight offline/online rounds of both vCPUs, 0 while
  its vCPUs were taken away under it, and a plain thread on a freshly onlined vCPU still reorders,
  so TSO is neither lost nor left on. The dry run found `make release` broken since `ed5bd64`:
  `source_bundle`'s FEX loop shadowed its `path` parameter, so the run died before writing
  anything but the guest archive. Fixed; the rc then packaged correctly (sources 496 MB with
  `fex/` and `linux/asahi-tso/`, 15 license texts including 0BSD and BSL-1.0). Output deleted,
  nothing tagged. NOTES.md still needs its change summary written by hand for 0.3.0.

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
- **Done (2026-10-26).** Not the JIT, SMC tracking, TSO or node's threads: `--jitless`,
  `FEX_SMCCHECKS=0`, `FEX_SMCCHECKS=2`, `FEX_TSOENABLED=0`, `FEX_HALFBARRIERTSOENABLED=0` and
  `UV_THREADPOOL_SIZE=1` all left it at 616–650 ms. It was multiblock compiling superblocks of up
  to `MaxInst` = 5000 x86 instructions out of code that runs once. Turning multiblock off gives
  199 ms but costs CPython 2.8×, so instead `MaxInst` is 150 by build-time default
  (`Config.json.in` in `FEX_PATCH`): node start 260 ms against QEMU's 386, node's JIT loop 8 %
  faster, python start/loop/imports and sha256 unchanged, amd64 image matrix 9/9. See
  [measurements](measurements/2026-10-26-maxinst.json).

### R2. FEX keeps more guest memory after x86 work

- **Known.** x86test footprint after the x86 work: FEX 275–292 MB, QEMU 227–231 MB; after
  cleanup and drop_caches: FEX 115–138 MB, QEMU 126–127 MB (two runs). Per-process RSS is the
  same (`sleep` 5 MB).
- **Look at.** Where the extra 50–60 MB is while x86 programs run (FEX code caches, its
  allocator's arenas; `smaps_rollup` of a running x86 python), and whether it all comes back once
  they exit (it should: the processes are gone). Compare the idle sweep's result a minute later.
- **Update (2026-10-26).** R1's block cap took most of it: footprint after the x86 work is now
  240 MB against QEMU's 225 (was 275–292 vs 227–231), after cleanup 137 vs 124. So the code
  caches of 5000-instruction superblocks were the bulk of it; 15 MB is left to explain.
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
