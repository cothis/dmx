# dmx

A container engine for macOS that stays out of your memory, built to be driven by AI agents as easily as by people.

> Early development. Today `dmx` runs its Linux VM on its own VMM (Hypervisor.framework) inside a daemon that boots it on first use (in about 0.25 s) and stops it when idle, runs commands and shells in it through a guest agent, and measures what the VM costs the host. Memory the guest frees goes back to macOS within seconds. Storage, networking and Docker compatibility come next.

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
| 4 | Memory: footprint tracking, smaller baseline, memory controller | idle target met; controller next |
| 5 | Daemon, launchd socket activation, idle stop | done |
| 6 | Data disk, networking, port forwarding, file sharing | |
| 7 | Docker compatibility (dockerd in the guest first) | |
| 8 | Own runtime, replacing dockerd piece by piece | |
| 9 | `dmx mcp`, sandboxes, checkpoints | `dmx mcp` works; sandboxes next |
| 10 | Release: CI, guest artifacts, Homebrew | |

Measured on an M-series Mac (10 cores, 16 GB): the guest agent answers about 0.15 to 0.25 s after boot starts. The whole dmx process, guest RAM included, costs about 87 MB at idle with a 2 GB ceiling and 115 MB with 8 GB (the first Virtualization.framework build cost 170 and 356 MB), thanks to a 16K page guest kernel trimmed to what dmx needs, no SWIOTLB bounce buffer, and dmx's own VMM. With the VM stopped the daemon costs 4 MB, and an idle daemon exits. Virtualization.framework never hands memory the guest frees back to macOS (its balloon is a no-op on the host); on Hypervisor.framework guest RAM is memory dmx owns, so when the guest frees 1 GB, dmx gives it back to macOS within about 2 seconds.

## Build

Requires macOS 15+ on Apple Silicon, Xcode (Swift 6), Python 3, and Rust via rustup with the
guest target: `rustup target add aarch64-unknown-linux-musl` (it links with the bundled `rust-lld`).

```sh
make build     # swift build + ad-hoc sign with the virtualization entitlement
make kernel    # build the 16K page guest kernel inside a dmx VM (slow; once per kernel version)
make guest     # fetch pinned Alpine Linux artifacts, build ~/.dmx/guest/{Image,initramfs.gz}
make install   # copy dmx to ~/.local/bin (PREFIX=... to change)
.build/release/dmx doctor
.build/release/dmx boot --selftest --json
make daemontest                  # the daemon end to end, in a throwaway DMX_HOME
make mcptest                     # dmx mcp driven like an MCP client
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

`dmx mcp` is a stdio MCP server with the tools `dmx_exec`, `dmx_status`, `dmx_start`, `dmx_stop`,
`dmx_config_get` and `dmx_config_set`. Command output is capped per stream (head and tail, 8 KiB
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

- `Sources/DMXCore`: VM, console, doctor and selftest logic, shared by the CLI and the future MCP mode
- `Sources/DMXCore/Daemon`: the daemon, its client, exec through it, and the launchd agent
- `Sources/DMXCore/MCP`: `dmx mcp`, the MCP server on stdio, and exec with capped output
- `Sources/DMXCore/HV`: the VMM: vCPUs, device tree, GIC setup, PL011, virtio-mmio devices (console, rng, vsock, balloon with free page reporting, blk for the data disk, net, fs)
- `Sources/dmx`: the command line
- `guest/init`: PID 1 inside the VM
- `guest/agent`: `dmx-agent`, the Rust guest agent on vsock ([protocol](docs/agent-protocol.md))
- `scripts/build-kernel.py`: builds the guest kernel in a dmx VM from pinned, checksummed sources and toolchain
- `scripts/build-guest.py`: builds the guest from pinned, checksummed Alpine Linux packages and that kernel
- `scripts/test-daemon.py`: end to end test of the daemon on the real VM (`make daemontest`)
- `scripts/test-mcp.py`: `dmx mcp` driven over pipes on the real VM (`make mcptest`)
- `docs/PLAN.md`: full plan, decisions, progress and measurements

## License

Apache License 2.0. See [LICENSE](LICENSE).
