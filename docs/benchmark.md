# Comparing container engines

`make benchmark` runs a repeatable local dmx workload; with `--endpoint` and `--pid` it measures
another engine the same way (results below). The script reports host load, versions, settings, the exact
image digest and individual timing samples, and measures `ri_phys_footprint` rather than RSS.
Guest RAM is charged to the VMM process; RSS and the `footprint` command can omit it.

## Protocol

Use the same Mac, macOS version and Docker CLI, with other VM workloads stopped. Configure
each engine for **2 CPUs, a 4 GiB memory ceiling and no host shares**, and disable unrelated
extensions or background containers. Keep each engine's ordinary memory reclamation policy;
dmx's on-demand RAM and idle reclaim remain enabled. Use native arm64 for these measurements;
emulation compatibility is tested separately in [compatibility.md](compatibility.md).

1. Record the engine version and all its VM, daemon and helper processes. Give the script the
   process IDs charged for guest RAM and the other engine processes. `--pid` can be repeated;
   its report names and measures every supplied process. Verify attribution using that engine's
   actual process tree before comparing totals; a guessed PID is not sufficient evidence.
2. Stop the other engines and wait for background host work to settle. Record host load and
   memory pressure. Repeat each engine at least three times in alternating order; summarize
   medians and ranges. A busy-host run remains provisional even if every check passes.
3. Pull the same digest-pinned Alpine arm64 image. Network download time is excluded from
   steady-state timings. Let idle memory settle for 35 seconds, then measure ten seconds of
   idle CPU, five `docker run ... true` samples, and a 256 MiB SHA-256 workload.
4. Write 2 GiB into a container's tmpfs, record host memory while held and the sampled peak,
   then remove it and the container. Record time and footprint until memory is back within
   64 MiB of the preceding baseline, with a ten-second limit.
5. For cold start and idle shutdown, use each engine's documented lifecycle separately.
   The harness measures dmx's start and first Docker use; it does not stop or start an external
   engine, so its report has no comparable external cold-start number.

`scripts/benchmark.py` uses a fresh Docker config and removes only its own containers. Its
external-engine mode requires an existing Unix socket and the measured process IDs, and
checks the guest's CPU count and visible RAM against the requested settings. It does not
install or change external engines. Shared-folder settings and complete PID attribution
must be checked by the operator; Docker's info endpoint cannot establish them.

```sh
make build guest
python3 -I scripts/benchmark.py > dmx-benchmark.json

# After installing/configuring an engine and identifying its real VM/helper PIDs:
python3 -I scripts/benchmark.py --endpoint unix:///path/to/docker.sock \
  --label ENGINE --pid VM_PID --pid HELPER_PID > engine-benchmark.json
```

The host memory reader follows the macOS SDK's `rusage_info_v4` layout, and a dmx run compares
its reading with the independent Swift status reader before collecting results. CPU counters
use Mach absolute ticks: the script converts them with `mach_timebase_info` and checks a short
CPU workload against `getrusage` before measuring an engine. This matters on Apple Silicon's
non-1:1 timebase; see XNU's
[fill_task_rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).
CPU is shown as a percentage of one core; the footprint peak is sampled every 100 ms, not a
lifetime peak. `--cpus` and `--ceiling-gb` support other acceptance profiles, but comparisons
must use the same profile for every engine; the container workload remains limited to 2 CPUs.

## Results, 2026-10-25

One Mac (macOS 26.6.1, 10 cores, 16 GB), one engine running at a time, three rounds in
alternating order, 2 CPUs and 4 GiB each ([raw](measurements/2026-10-25-engine-comparison.json)).
Host load was 2.4 to 6.4, so this is a provisional comparison, not a quiet-Mac result. Medians,
with ranges in parentheses:

| | dmx | OrbStack 2.2.5 | Colima 0.10.3 (vz) | Docker Desktop 4.96.3 |
|---|---|---|---|---|
| Idle after 35 s, MB | **180** (180–186) | 528 (526–604) | 1097 (988–1347) | 1176 (1149–1193) |
| Idle CPU, % of one core | 0.6 (0.5–0.7) | 0.2 (0.2–5.6) | 0.3 (0.2–0.5) | 0.4 (0.4–0.8) |
| Holding 2 GiB in tmpfs, MB | **2373** (2370–2373) | 2621 (2621–2736) | 3172 (3083–3345) | 3373 (3319–3388) |
| 10 s after freeing it, MB | **332** (329–337) | 618 (616–642) | 3180 (3092–3346) | 3362 (3299–3388) |
| Back within baseline +64 MB | 5.9 s (1.5–6.5) | 4.2 s (0.5–9.3) | no | no |
| `docker run --rm alpine true`, ms | 118 (113–159) | 123 (121–143) | **73** (65–75) | 99 (86–129) |
| SHA-256 of 256 MiB, ms | 954 (932–1346) | 1469 (1462–1477) | **912** (893–915) | 1739 (1110–1922) |

Longer after freeing 2 GiB (one run each): Docker Desktop held 3372 MB at 2 min and 365 MB at
5 min, when Resource Saver had stopped its VM (the app's processes stay); Colima held 3346 MB at
2 min and 3394 MB at 6 min; OrbStack went 618 → 378 MB over 5 min. dmx is back within 2 to 7 s
and stops its VM entirely after its idle timeout.

Settings and attribution: every process of each engine was measured (Docker Desktop's backend,
UI, helpers and the Virtualization framework VM process; Colima's limactl processes, ssh mux and
VM process; OrbStack's vmgr helper). OrbStack's round 1 also includes its UI process (49 MB);
rounds 2 and 3 ran headless via `orbctl start`. Colima ran with `--mount none`, Docker Desktop
with no file-sharing directories; OrbStack shares the Mac's home and cannot turn that off.
Engines were downloaded from their vendors (DMG sha256s matching Homebrew's cask pins, Developer
ID signatures checked), configured only for CPUs, memory and shares, and removed afterwards.

What this shows: dmx holds the least at idle and under load and gives freed memory back within
seconds; OrbStack also returns memory, from a higher baseline; the two Virtualization
framework engines keep what the guest touched until their VM stops. dmx's warm `docker run`
(118 ms) is behind Colima (73 ms) and Docker Desktop (99 ms); the SHA-256 work was fastest on
Colima and dmx. The `docker run` gap is the data disk's flushes (profiled 2026-10-25, below). A quiet-Mac rerun would tighten the ranges.

## Warm `docker run` profile (2026-10-25)

Same command as the benchmark (`--network none --memory 1g --cpus 2 --pids-limit 256`, then
`docker rm -fv`), 2 CPUs/4 GiB, host load 3–8. Through a logging proxy on the host: create
35–38 ms, start 48–54 ms, exit to `wait` reply ~16 ms; every API round trip through dmx's proxy
and vsock is ~0.3 ms, so the transport is not the cost. The 1 ms WFI cap is not either: 100 µs
and 20 ms caps give the same times.

The guest issues ~80 flushes per run and remove (`/sys/block/vda/stat`): ext4 makes two per
journal commit, and the fsyncs are containerd's `meta.db` (24), dockerd's network store
`local-kv.db` (14, even with `--network none`), the overlay snapshotter's `metadata.db` (12) and
~11 file fsyncs (ftrace on `ext4_sync_file_enter`). dmx answers each flush with
`F_BARRIERFSYNC`, ~0.35 ms on the host (plain `fsync` 15 µs, `F_FULLFSYNC` 3.7 ms on this Mac),
~0.85 ms as the guest sees it. Medians of 10 runs, three alternating rounds:

| Flush | Warm `docker run` |
|---|---|
| `F_BARRIERFSYNC` (dmx) | 122–137 ms |
| Answer at once, barrier before the next request | 115–130 ms |
| Plain `fsync` | 75–78 ms |
| None (upper bound) | 69 ms |

Lima, and so Colima, uses plain `fsync` (`DiskImageSynchronizationModeFsync`), which explains its
73 ms. dmx keeps the barrier (maintainer, 2026-10-25): with plain `fsync` the SSD may reorder
writes across a power cut and leave the ext4 data disk (images, volumes) corrupt; the fsck at boot
(since 0.2.1) can repair the file system but not bring back lost data. Answering early only moved the wait to the next write.
