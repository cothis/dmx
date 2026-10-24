# dmx

A container engine for macOS that stays out of your memory, built to be driven by AI agents as easily as by people.

> Early development; no public release yet. `dmx` runs Docker, Compose and BuildKit in its own Linux VM on Hypervisor.framework, with storage, networking and host file sharing. An on-demand daemon boots the VM and stops it when idle. Memory the guest frees goes back to macOS within seconds, and virtio-mem adds RAM as needed. Agents can use MCP tools and disposable sandboxes with checkpoints, resource limits and TTLs.

## Why

Linux containers need a Linux kernel, so every container tool on macOS runs a VM. CPU inside that VM is close to native on Apple Silicon. Memory is where it hurts: most VMs grow to their limit and never give memory back. dmx aims for:

- **Memory that comes back.** A memory balloon returns pages the guest no longer uses, the guest itself is tiny, and the VM stops entirely when nothing is running.
- **Docker compatible.** A Docker Engine API socket, so the `docker` CLI and Compose keep working.
- **AI native.** Every command has `--json` output and structured errors with a hint for the next step. `dmx mcp` serves the same core to AI clients over MCP.

## Status

See [docs/PLAN.md](docs/PLAN.md) for the detailed plan.

| Phase | | |
|---|---|---|
| 1 | Boot a Linux VM with Virtualization.framework, debug console | done |
| 2 | Guest agent (Rust) and vsock control channel | done |
| 3 | Own VMM on Hypervisor.framework, so freed guest memory goes back to macOS | done |
| 4 | Memory: footprint tracking, smaller baseline, memory controller, on-demand RAM | done |
| 5 | Daemon, launchd socket activation, idle stop | done |
| 6 | Data disk, networking, port forwarding, file sharing | done; extensions remain |
| 7 | Docker compatibility (dockerd in the guest first) | done; image workloads and remaining emulation limits in [compatibility](docs/compatibility.md) |
| 8 | Own runtime, replacing dockerd piece by piece | not started |
| 9 | `dmx mcp`, sandboxes, checkpoints and logs | done |
| 10 | Release: install script, guest downloads verified by dmx | groundwork done, no release yet |

Measured on an M-series Mac (10 cores, 16 GB): the current 4K guest costs about 78 MB at idle with 2 vCPUs / a 4G ceiling, and about 89–90 MB with 10 vCPUs / an 8G ceiling. The whole dmx process is counted, guest RAM included; Docker adds memory after it starts. The guest boots with 1 GB and hotplugs more as needed, so unused ceiling RAM has no memmap cost. The first Virtualization.framework build cost 170 MB at 2G and 356 MB at 8G. With the VM stopped the daemon costs about 4 MB, and an idle daemon exits. Free page reporting returns data pages within seconds; spare hotplug RAM is removed after 5 seconds of surplus. Under host pressure dmx also trims caches and uses a balloon for memory that cannot be removed. These are local measurements, not a controlled comparison with other engines; see [the dated measurements](docs/PLAN.md#findings-and-measurements).

The guest uses 4K pages for x86 shared mappings, guard pages and partial `msync`; virtio-mem keeps unused ceiling RAM free. Some amd64 allocators still need a QEMU address-layout workaround (currently Redis; see [the image matrix](docs/compatibility.md)). Other gaps include IPv6 and split DNS, data disk resizing and boot-time fsck, and extended file-sharing metadata. See [Next up](docs/PLAN.md#next-up) for release validation and the remaining runtime work.

## Install

Releases need no Xcode, Python, Rust or Homebrew: one script installs `dmx` into `~/.local/bin`
(no sudo), and dmx downloads its Linux guest on first use, checked against the sha256 built into
the binary. No release is published yet; until then, build from source below.

```sh
curl -fsSL https://github.com/cothis/dmx/releases/download/v0.1.0/install.sh | sh
dmx install            # optional: launchd starts dmx on demand; adds a docker context
dmx guest fetch        # optional: download the guest now instead of on the first boot
```

See [docs/release.md](docs/release.md) for what a release contains and how one is cut.

## Build

Requires macOS 15+ on Apple Silicon, Xcode (Swift 6), Python 3, and Rust via rustup with the
guest target: `rustup target add aarch64-unknown-linux-musl` (it links with the bundled `rust-lld`).

```sh
make build     # swift build + ad-hoc sign with the hypervisor entitlement
make kernel    # build the trimmed 4K page guest kernel inside a dmx VM (once per kernel version)
make qemu      # build the guest's qemu-x86_64 inside a dmx VM (under a minute, once per version)
make guest     # fetch pinned Alpine Linux artifacts, build ~/.dmx/guest/{Image,initramfs.gz}
make install   # copy dmx to ~/.local/bin (PREFIX=... to change)
.build/release/dmx doctor
.build/release/dmx boot --selftest --json
make daemontest                  # the daemon end to end, in a throwaway DMX_HOME
make mcptest                     # dmx mcp driven like an MCP client
make dockertest                  # Docker, Compose and BuildKit, using dmx's bundled tools
make sandboxtest                 # sandbox policies, checkpoints, logs and TTLs
make x86test                     # x86_64 binaries through QEMU and binfmt_misc
make imagetest                   # workloads in nine digest-pinned images, arm64 and amd64
make benchmark                   # local measurements; comparison protocol in docs/benchmark.md
```

## Use

```sh
dmx exec -- uname -a             # boots the VM (and the daemon) if needed; exits with the command's status
dmx shell                        # interactive shell in the VM
dmx status --json                # state, uptime, guest memory, host footprint
dmx stop                         # power off now instead of waiting for the idle timeout
dmx config set idle_timeout 10m  # also: cpus, memory (the ceiling, e.g. 8G), disk_size
dmx install                      # optional: launchd starts the daemon on the first connection,
                                 # and docker, docker compose and docker buildx are installed
docker run --rm hello-world      # the docker context "dmx" points at ~/.dmx/docker.sock
dmx boot                         # debugging: a VM in the foreground with its console, Ctrl-] powers off
```

### From an AI agent (MCP)

`dmx mcp` is a stdio MCP server with VM and config tools, `dmx_exec`, `dmx_sandbox_*` for
disposable environments and checkpoints, and `dmx_logs`. Command output is capped per stream (head and tail, 8 KiB
by default) so a large log does not flood the agent's context. Register it with Claude Code:

```sh
claude mcp add dmx -- dmx mcp
```

See [docs/mcp.md](docs/mcp.md) for other clients and the tool reference.

Docker needs no Homebrew and no Docker Desktop: dmx installs pinned, sha256-checked copies of the
docker CLI and the Compose and Buildx plugins into `~/.dmx` (`dmx tools install`, also part of
`dmx install`), links `docker` into `~/.local/bin` when that is on PATH, and `docker build` uses
BuildKit. See [docs/docker.md](docs/docker.md).

The VM stops after 5 minutes with nothing using it, and the daemon exits 10 s later.
The guest's `/var/lib` is a data disk, `~/.dmx/data.img`: a sparse file of 64G (`disk_size`, set
before the first boot) that takes only what the guest stores, and shrinks again when it deletes.
State lives in `~/.dmx` (override with `DMX_HOME`). The control socket is described in
[docs/daemon-protocol.md](docs/daemon-protocol.md).

## Layout

- `Sources/DMXCore`: VM, console, doctor and selftest logic, shared by the CLI, daemon and MCP server
- `Sources/DMXCore/Daemon`: the daemon, its client, exec through it, and the launchd agent
- `Sources/DMXCore/MCP`: `dmx mcp`, the MCP server on stdio, and exec with capped output
- `Sources/DMXCore/HV`: the VMM: vCPUs, device tree, GIC setup, PL011, virtio-mmio devices (console, rng, vsock, balloon with free page reporting, mem for on-demand RAM, blk for the data disk, net, fs)
- `Sources/DMXCore/Sandbox`: sandbox policies, lifecycle, checkpoints, fork, rollback, TTL and logs
- `Sources/dmx`: the command line
- `guest/init`: PID 1 inside the VM
- `guest/agent`: `dmx-agent`, the Rust guest agent on vsock ([protocol](docs/agent-protocol.md))
- `scripts/build-kernel.py`: builds the guest kernel in a dmx VM from pinned, checksummed sources and toolchain
- `scripts/build-qemu.py`: builds the guest's qemu-x86_64 in a dmx VM from pinned QEMU source, Alpine's patches and toolchain
- `scripts/build-guest.py`: builds the guest from pinned, checksummed Alpine Linux packages and that kernel
- `scripts/test-daemon.py`: end to end test of the daemon on the real VM (`make daemontest`)
- `scripts/test-mcp.py`: `dmx mcp` driven over pipes on the real VM (`make mcptest`)
- `scripts/release.py`, `scripts/install.sh`: a release directory (`make release`) and the script users install it with
- `docs/PLAN.md`: full plan, decisions, progress and measurements

## License

Apache License 2.0. See [LICENSE](LICENSE).

Docker is a trademark of Docker, Inc. dmx is an independent project, compatible with the Docker CLI
and Engine API; it is not affiliated with or endorsed by Docker, Inc.
