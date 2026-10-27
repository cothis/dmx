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
   steady-state timings. Sample idle memory at 35, 50, 65, 80 and 95 seconds after the pull, then
   measure ten seconds of idle CPU, five `docker run ... true` samples, and a 256 MiB SHA-256
   workload. One idle reading is not one number for dmx: the idle trim and sweep fire 30 seconds
   after the last activity and take ~70 MB back, and dockerd and containerd then read some of
   their files again, so the footprint has a floor (`idle_min`, 185–205 MB here) and a steady
   state (`idle`, 210–225 MB). A fixed 35-second settle sat on the edge of the trim, which is why
   2 of 9 runs on 2026-10-25 read ~70 MB high
   ([measurements](measurements/2026-10-26-idle-readings.json)). The 0.3.0 table quotes the steady
   state, with the floor and the 35-second reading next to it; the older tables quote the
   35-second reading alone, which is all they measured.
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

## dmx re-check, 2026-10-27 (0.3.6)

0.3.1 to 0.3.6 changed the update path, host/guest boundary checks, the x86 emulator and the
idle sweep (which now also trims the data disk), so dmx alone was measured again with the
protocol and Mac of the 0.3.0 comparison below. Three rounds, host load 1.1 to 1.4, v0.3.6
guest ([raw](measurements/2026-10-27-dmx-recheck-0.3.6.json)). The other engines were not
measured again: nothing in dmx can move their numbers. Medians, with ranges in parentheses:

| | dmx 0.3.0 (2026-10-26) | dmx 0.3.6 |
|---|---|---|
| Idle, steady state at 95 s, MB | 222 (219–223) | 222 (220–224) |
| Idle, lowest reading in the window, MB | 194 (188–195) | 193 (191–198) |
| Idle CPU, % of one core | 0.40 (0.39–0.42) | 0.37 (0.37–0.38) |
| Holding 2 GiB in tmpfs, MB | 2390 (2389–2391) | 2389 (2388–2393) |
| After freeing it, MB / time back within baseline +64 MB | 356 (352–358) / 2 s (2–5) | 358 (352–358) / 2 s (2–2) |
| `docker run --rm alpine true`, ms | 104 (98–104) | 102 (99–112) |
| SHA-256 of 256 MiB, ms | 847 (838–864) | 839 (836–842) |

Every number is inside or next to the 0.3.0 range, so the README table still describes dmx;
the idle disk trim costs nothing visible.

## Results, 2026-10-26 (dmx 0.3.0, quiet Mac)

Same Mac as below (macOS 26.6.1, 10 cores, 16 GB), host load 1.0 to 1.7 for every run, one engine
at a time, three rounds in alternating order, 2 CPUs and 4 GiB each. dmx 0.3.0 against the same
engine builds as the 0.2.2 comparison below (the Docker Desktop and OrbStack installers match by
sha256) ([raw](measurements/2026-10-26-engine-comparison-0.3.0.json)). Medians, with ranges in
parentheses:

| | dmx 0.3.0 | OrbStack 2.2.5 | Colima 0.10.3 (vz) | Docker Desktop 4.96.3 |
|---|---|---|---|---|
| Idle, steady state at 95 s, MB | **222** (219–223) | 379 (374–379) | 1100 (1084–1366) | 1026 (1022–1058) |
| Idle, lowest reading in the window, MB | **194** (188–195) | 377 (374–378) | 1099 (1083–1366) | 1024 (1021–1057) |
| Idle at 35 s, as in the tables below, MB | **194** (188–195) | 445 (442–445) | 1099 (1083–1366) | 1024 (1021–1057) |
| Idle CPU, % of one core | **0.40** (0.39–0.42) | 0.53 (0.42–0.57) | 0.67 (0.58–0.81) | 0.46 (0.44–0.49) |
| Holding 2 GiB in tmpfs, MB | **2390** (2389–2391) | 2693 (2690–2700) | 3160 (3153–3369) | 3154 (3151–3199) |
| After freeing it (at the 10 s limit), MB | **356** (352–358) | 2699 (2695–2708) | 3164 (3153–3372) | 3157 (3152–3200) |
| Back within baseline +64 MB | **2 s** (2–5) | no (by 20 s, probe) | no (3100 MB at 5 min) | no (258 MB at 6 min, VM stopped) |
| `docker run --rm alpine true`, ms | 104 (98–104) | 97 (94–103) | **52** (51–54) | 63 (62–64) |
| SHA-256 of 256 MiB, ms | 847 (838–864) | 1334 (1285–1347) | **795** (793–806) | 819 (805–826) |

What changed since the 0.2.2 table below:

- **dmx's idle CPU is now the lowest of the four**, 0.40 % of one core against 1.4 % in 0.2.2:
  the idle trim no longer repeats (see the entry below). Idle memory is unchanged at the 35 s
  mark (198 → 194 MB).
- **The idle window is sampled, not a single reading.** dmx trims an idle guest 30 s after the
  last activity and dockerd then reads some files back, so its floor is 194 MB and its steady
  state 222 MB. OrbStack does the same more slowly: 445 MB at 35 and 50 s, 377 MB from 65 s. The
  two Virtualization-framework engines are flat across the window.
- **OrbStack returned the 2 GiB just outside the 10 s limit** in all three rounds, where the
  0.2.2 comparison saw it come back in 3.9 to 5.4 s. A longer probe has it back by 20 s
  (2583 MB at 10 s, 506 MB at 20 s against a 477 MB baseline). Colima keeps it: 3100 MB five
  minutes after the container exited. Docker Desktop holds 3117 MB for five minutes and then its
  Resource Saver stops the VM, leaving 258 MB of app processes from six minutes on — so it does
  give the memory back, a few minutes later and by stopping the VM rather than returning pages.
- **Timings are within the earlier ranges** except OrbStack's SHA-256 (1261 → 1334 ms) and
  Docker Desktop's `docker run` (67 → 63 ms).

Docker Desktop was measured with its Resource Saver left on, which is its default; three earlier
rounds with it off are in the raw file and read the same (idle 1032 MB, 1019–1058), because it
does not act inside a 95-second window. Every process of each engine was measured, as below:
Docker Desktop 11 processes, Colima 4, OrbStack 1 (its vmgr helper), dmx 1.

## Results, 2026-10-26 (dmx 0.2.2, quiet Mac)

Same Mac as below (macOS 26.6.1, 10 cores, 16 GB) with nothing else busy: host load 1.0 to 1.6
for every run. One engine at a time, three rounds (dmx, OrbStack, Colima, Docker Desktop; round
2 in reverse), 30 s between engines, 2 CPUs and 4 GiB each, same engine versions as on
2026-10-25 and dmx 0.2.2 ([raw](measurements/2026-10-26-engine-comparison.json)). Medians, with
ranges in parentheses:

| | dmx 0.2.2 | OrbStack 2.2.5 | Colima 0.10.3 (vz) | Docker Desktop 4.96.3 |
|---|---|---|---|---|
| Idle after 35 s, MB | **198** (191–202) | 530 (529–552) | 1093 (1082–1379) | 1053 (1051–1091) |
| Idle CPU, % of one core | 1.4 (1.3–1.5) | 0.6 (0.6–0.7) | 0.6 (0.6–0.8) | **0.4** (0.4–0.6) |
| Holding 2 GiB in tmpfs, MB | **2380** (2377–2382) | 2614 (2604–2618) | 3132 (3104–3409) | 3225 (3188–3229) |
| After freeing it (when back, else at 10 s), MB | **342** (340–344) | 546 (524–627) | 3138 (3110–3411) | 3223 (3191–3229) |
| Back within baseline +64 MB | **1.9 s** (0.5–2.0) | 5.4 s (3.9–5.4) | no | no |
| `docker run --rm alpine true`, ms | 101 (95–103) | 95 (92–101) | **52** (50–53) | 67 (65–69) |
| SHA-256 of 256 MiB, ms | 853 (835–861) | 1261 (1260–1266) | **806** (804–814) | 818 (817–824) |

What changed from the busy-Mac run: the memory columns agree with it (dmx and OrbStack give
freed memory back within seconds, the Virtualization framework engines keep it), with much
narrower ranges. Every engine's warm `docker run` and SHA-256 got faster without the load:
dmx 118 → 101 ms, but Colima 73 → 52 and Docker Desktop 99 → 67, so dmx's gap remains (the data
disk's barrier flushes, below). dmx now takes the most CPU at idle, 1.4 % of one core against
0.4 to 0.6 % (0.6 % on 2026-10-25).

That idle CPU and an idle footprint that sometimes reads ~100 MB higher are not new in 0.2.2:
alternating the v0.2.1 release (its GitHub binary and guest) with 0.2.2, three runs each, gave
idle 182, 187 and 297 MB at 1.4–1.6 % CPU for 0.2.1 and 187, 201 and 284 MB at 1.3–1.9 % for
0.2.2; 10 s after freeing 2 GiB, 312–334 MB against 344–345 MB.

The idle CPU was the idle trim repeating (fixed the same day): `memory.reclaim` also takes the
file pages of running programs, dockerd and containerd read ~40 MB back from the data disk
within seconds, the cache passed the trim threshold again, and the next 5 s tick trimmed it
again. Trimming once per idle spell, three benchmark runs: idle CPU **0.57 %** (0.55–0.72) of
one core, idle 195–200 MB, `docker run` 95–106 ms, 353 MB after freeing 2 GiB (11 MB more:
dockerd's pages stay), back in 2.0–5.4 s
([raw](measurements/2026-10-26-idle-cpu.json)). The occasional ~100 MB higher idle reading did
not come up in those runs; it is not explained yet.

Engines were set up as on 2026-10-25 (vendor DMGs with the same sha256s, Developer ID and
notarization checked; Colima from Homebrew), plus what avoided password prompts: Docker
Desktop with the default socket, vmnetd and privileged ports off and its CLI tools in
`~/.docker/bin`; OrbStack headless with `setup.use_admin` and `docker.set_context` off. The same
setup served the 0.3.0 comparison above, and afterwards all three were removed again with their
data (`~/.colima`, `~/.orbstack`, Docker Desktop's containers and group container) and the
`~/.docker` entries they had added (its contexts, the `cli-plugins` symlinks into Docker.app,
`buildx`, `models`, `mutagen`, `desktop-build` and the `daemon.json` Docker Desktop wrote), so
`docker context ls` is back to `default`. Every
process of each engine was measured (Docker Desktop: backend, UI, build, virtualization, agent
and the VM process; Colima: two limactl processes, the VM process and the ssh mux; OrbStack:
its vmgr helper). Afterwards all three were removed, with their data, and the shell profiles
they edited restored.

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
Colima and dmx. The `docker run` gap is the data disk's flushes (profiled 2026-10-25, below). The quiet-Mac rerun is above.

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
