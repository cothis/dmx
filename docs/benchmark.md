# Comparing container engines

`make benchmark` runs a repeatable local dmx workload. It does not by itself establish a
comparison with another engine. The script reports host load, versions, settings, the exact
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

## Availability on 2026-10-25

Docker Desktop and OrbStack are absent from `/Applications`; the Colima, OrbStack and Lima
CLIs are absent from PATH. Only dmx can be measured in the current environment. The comparison
remains open until the other engines are available, configured and measured on a quiet host.
The external-engine path has not been exercised against those engines here.

The current local 2-CPU/4G run ([raw report](measurements/2026-10-25-dmx-benchmark.json))
recorded 78.41 MiB before Docker, a 193.38 MiB snapshot after the 35 s settle, 0.549% of one
core during the following ten-second idle window, a 117.12 ms median of five warm container
starts and 914 ms for SHA-256 of 256 MiB. The 2 GiB tmpfs allocation returned within baseline
+64 MiB in 1.50 s. Host load was 2.88 → 2.57, pressure normal; these are provisional local
numbers, not results on an otherwise idle Mac.

The additional default 10-CPU/8G acceptance profile
([report](measurements/2026-10-25-default-unplug-after.json)) returned the same allocation in
6.14 s, below its preceding baseline. It exposed and verifies the fix for normal hotplug
metadata lingering after data pages had already been returned.
