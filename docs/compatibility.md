# Container image compatibility

The matrix runs real workloads, not just `--version`, in nine official Docker images on
`linux/arm64` and `linux/amd64`. Index and per-platform manifest digests are fixed in
[scripts/image-matrix.json](../scripts/image-matrix.json). Tags are labels for those exact
inputs, not floating inputs when a test runs. Docker verifies the pulled content against the
recorded digest; `--pin` resolves and verifies registry metadata before updating the pins.

```sh
make build guest
make imagetest

# Focused reruns can keep an isolated data disk and downloaded layers:
python3 -I scripts/test-images.py --state-dir /tmp/dmx-images --image java --platform linux/amd64

# Deliberately refresh metadata/pins; this executes no image:
python3 -I scripts/test-images.py --pin
```

The VM has 2 CPUs, a 4 GiB ceiling and no host shares. Each container has a 1 GiB memory
limit, 2 CPUs, a 256-PID limit and core dumps disabled. Workloads use no external network;
only image downloads need the network. The CLI and Docker configuration are isolated; the
host's `~/.docker` is not changed. An ordinary test failure stays a failure, including a known
emulation bug, and makes the command exit nonzero. This is a smoke matrix, not a guarantee
that every workload or application version works.

## Workloads and observations, 2026-10-25

| Image label | Workload | arm64 | amd64 with 4K kernel | amd64 with previous 16K kernel |
|---|---|---|---|---|
| Alpine 3.24 | shell, architecture and SHA-256 | pass | pass | pass |
| Debian trixie-slim | shell, architecture and SHA-256 | pass | pass | pass |
| Ubuntu 24.04 | shell, architecture and SHA-256 | pass | pass | pass |
| Python 3.14-slim | SQLite WAL, reopen/query, shared mmap and full flush | pass | pass | shared library mapping fails |
| Node 24-alpine | JIT loop, WebAssembly, worker thread and file I/O | pass | pass | pass |
| nginx stable-alpine | HTTP body on container loopback, restart and read again | pass | pass | pass |
| Redis 8-alpine | SET/GET, BGSAVE and AOF persistence across restart | pass | pass with dmx's qemu-x86_64 (failed with upstream's layout, below) | fails |
| PostgreSQL 18-alpine | initdb, 10,000-row SQL transaction, checkpoint and restart persistence | pass | pass | pass |
| Temurin 21-jdk-jammy | javac, JIT, thread, shared mapping and partial force | pass | pass | partial msync returns EINVAL |

The 16K kernel passed 15/18 combinations; the 4K control passed 17/18 with Alpine's
qemu-x86_64. With dmx's qemu-x86_64 (the guest-base default below) the default matrix passes
18/18. The bounded raw reports include image and guest artifact hashes:
[16K baseline](measurements/2026-10-25-images-16k.json),
[4K control](measurements/2026-10-25-images-4k-control.json),
[Redis with the earlier explicit workaround](measurements/2026-10-25-redis-workaround.json),
[18/18 with dmx's qemu-x86_64](measurements/2026-10-25-images-guest-base.json).

## Why 4K guest pages

The earlier 16K kernel saved memmap memory. x86 programs see 4K pages through QEMU, though,
so a 4K operation inside a larger Linux page could fail or behave incorrectly. The matrix
found a Python loader failure for `libpython3.14.so.1.0` and a Java
`MappedByteBuffer.force(4096, 4096)` failure. A 4K Linux guest resolved both with the same
image digests and QEMU binary. `make x86test` also checks fixed shared mappings, msync,
MADV_DONTNEED zeroing and real guard-page faults at 4K offsets; these must all work, rather
than counting the earlier limitations as expected successes.

Before tuning the reporting budget, three alternating 2-CPU/4G selftests measured 64–66 MB
idle on 16K and 77–78 MB on 4K. virtio-mem means the extra memmap is paid for present RAM,
not the entire configured ceiling. The unmodified reporting budget made 1 GiB return take
8.3–10.0 s on 4K; the dmx kernel now processes one bounded initial free-list length per pass
instead of spreading it over sixteen 2-second rounds. Busy reporting stays 512 KiB; idle
reporting covers a complete Mac page so dmx never releases a partly occupied host page.
Final measurements and validation are recorded in [PLAN.md](PLAN.md#findings-and-measurements).

| Same 2-CPU / 4G selftest profile, three runs | Idle host MiB | Return after freeing 1 GiB |
|---|---|---|
| Previous 16K kernel | 64–66 | 0.41–2.16 s |
| 4K, upstream 1/16 reporting budget | 77–78 | 8.29–10.00 s |
| 4K, bounded whole-list reporting budget | 78 | 0.317–2.114 s |

[Measured profiles](measurements/2026-10-25-reclaim-profiles.json) retain every sample and the
guest artifact hashes. The current 4K kernel also passed the ten 4K mapping/permission/zeroing
probe checks in `make x86test`, including mincore and a real fault after partial munmap.

The default 8G ceiling exposed a second source of residual footprint: the data pages had
returned, but surplus hotplug RAM and its memmap stayed until a 30-second delay and quiet polling
expired. The first 10-CPU/8G container test was still 78.86 MiB above baseline after 10 s.
Normal unplug now starts after 5 seconds of surplus, with a one-second poll during that
countdown; already-pending unplug work is left to the guest. The same profile then returned
from 2426 MiB to 237 MiB, below its preceding baseline, in 6.14 s. The 2-CPU/4G workload also
passed in 1.50 s using the explicit baseline +64 MiB threshold. These checks do not require
idle VM shutdown or host pressure.

[Before normal unplug tuning](measurements/2026-10-25-default-unplug-before.json) and
[after](measurements/2026-10-25-default-unplug-after.json) keep the full measurements. The
default image run with Alpine's qemu-x86_64 had exactly the Redis amd64 failure:
[17/18 report](measurements/2026-10-25-images-4k-final.json); the separately labeled
[workaround run](measurements/2026-10-25-redis-workaround-final.json) passed.

## amd64 address layout: fixed in dmx's qemu-x86_64

The pinned Redis amd64 image's `redis-server` and `redis-cli` used to die with SIGSEGV under
QEMU's default layout. The cause is in QEMU 11.0.3's linux-user setup: for a 64-bit guest without
`-R`, `guest_addr_max` is `~0`, so `mmap_find_vma` accepts any host address. The dmx guest kernel
has a 48-bit address space, and when a hint is taken Linux searches top-down from just below
2^48. x86_64 programs then get `0x0000ffff...` addresses, above x86-64's 47-bit user space.
Redis's jemalloc sign-extends pointers from bit 47 (they become `0xffffffff...`) and faults; an
upstream [Nix report](https://github.com/NixOS/nix/issues/16184) shows the same with mimalloc
under Docker Desktop's QEMU.

dmx now builds its own qemu-x86_64 (`make qemu`, [build-qemu.py](../scripts/build-qemu.py)): the
same pinned QEMU 11.0.3 source, Alpine's patches and Alpine's static linux-user configuration,
plus one patch. On an aarch64 host, when neither `-B` nor `QEMU_GUEST_BASE` is given, the x86_64
guest base is 2^47, so every host address below 2^48 is a guest address below 2^47. It is
a default in the interpreter that binfmt_misc runs: no container environment, wrapper or
per-image setting, and `docker run`, `docker exec`, fork/exec and chroots without qemu in their
file system all get it. `QEMU_GUEST_BASE=0` restores upstream behavior for diagnosis.

Checks on the real VM, 2026-10-25:

- Redis amd64 passes its full workload without any setting; the image matrix is 18/18
  ([report](measurements/2026-10-25-images-guest-base.json)).
- Before the change, all nine amd64 images passed with `QEMU_GUEST_BASE=0x800000000000` set on
  every `run` and `exec`, so the new default breaks none of glibc malloc (Debian, Ubuntu,
  Python, Temurin), musl's mallocng (Alpine, Node, nginx, PostgreSQL), V8 or the JVM.
- `make x86test` maps with a taken hint and a 1 GiB reservation and requires every address
  below 2^47; the same probe with `QEMU_GUEST_BASE=0` must see a higher address, so it detects
  the old layout. It also runs Python allocation work with Alpine's jemalloc and mimalloc
  preloaded.
