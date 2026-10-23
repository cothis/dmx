# dmx

A container engine for macOS that stays out of your memory, built to be driven by AI agents as easily as by people.

> Early development. Today `dmx` boots its Linux VM on its own VMM (Hypervisor.framework), talks to a guest agent over vsock, runs a command or a console in it, and measures what the VM costs the host. Memory the guest frees goes back to macOS within seconds. Docker compatibility comes next.

## Why

Linux containers need a Linux kernel, so every container tool on macOS runs a VM. CPU inside that VM is close to native on Apple Silicon. Memory is where it hurts: most VMs grow to their limit and never give memory back. dmx aims for:

- **Memory that comes back.** A memory balloon returns pages the guest no longer uses, the guest itself is tiny, and the VM stops entirely when nothing is running.
- **Docker compatible.** A Docker Engine API socket, so the `docker` CLI and Compose keep working.
- **AI native.** Every command has `--json` output and structured errors with a hint for the next step. An MCP server mode (`dmx mcp`) is planned on top of the same core.

## Status

See [docs/PLAN.md](docs/PLAN.md) for the detailed plan.

| Phase | | |
|---|---|---|
| 1 | Boot a Linux VM with Virtualization.framework, debug console | done |
| 2 | Guest agent (Rust) and vsock control channel | done |
| 3 | Own VMM on Hypervisor.framework, so freed guest memory goes back to macOS | done |
| 4 | Memory: footprint tracking, smaller baseline, memory controller | next |
| 5 | Daemon, launchd socket activation, idle stop | |
| 6 | Data disk, networking, port forwarding, file sharing | |
| 7 | Docker compatibility (dockerd in the guest first) | |
| 8 | Own runtime, replacing dockerd piece by piece | |
| 9 | `dmx mcp`, sandboxes, checkpoints | |
| 10 | Release: CI, guest artifacts, Homebrew | |

Measured on an M-series Mac (10 cores, 16 GB): the guest agent answers about 0.3 s after boot starts. The whole dmx process, guest RAM included, costs 126 MB at idle with a 2 GB ceiling and 172 MB with 8 GB (the first Virtualization.framework build cost 170 and 356 MB), thanks to a 16K page guest kernel, no SWIOTLB bounce buffer, and dmx's own VMM. Virtualization.framework never hands memory the guest frees back to macOS (its balloon is a no-op on the host); on Hypervisor.framework guest RAM is memory dmx owns, so when the guest frees 1 GB, dmx gives it back to macOS within about 2 seconds.

## Build

Requires macOS 15+ on Apple Silicon, Xcode (Swift 6), Python 3, and Rust via rustup with the
guest target: `rustup target add aarch64-unknown-linux-musl` (it links with the bundled `rust-lld`).

```sh
make build     # swift build + ad-hoc sign with the virtualization entitlement
make kernel    # build the 16K page guest kernel inside a dmx VM (slow; once per kernel version)
make guest     # fetch pinned Alpine Linux artifacts, build ~/.dmx/guest/{Image,initramfs.gz}
.build/release/dmx doctor
.build/release/dmx boot --selftest --json
.build/release/dmx boot          # interactive console, Ctrl-] powers off
```

State lives in `~/.dmx` (override with `DMX_HOME`).

## Layout

- `Sources/DMXCore`: VM, console, doctor and selftest logic, shared by the CLI and the future MCP mode
- `Sources/DMXCore/HV`: the VMM: vCPUs, device tree, GIC setup, PL011, virtio-mmio devices (console, rng, vsock, balloon with free page reporting)
- `Sources/dmx`: the command line
- `guest/init`: PID 1 inside the VM
- `guest/agent`: `dmx-agent`, the Rust guest agent on vsock ([protocol](docs/agent-protocol.md))
- `scripts/build-kernel.py`: builds the guest kernel in a dmx VM from pinned, checksummed sources and toolchain
- `scripts/build-guest.py`: builds the guest from pinned, checksummed Alpine Linux packages and that kernel
- `docs/PLAN.md`: full plan, decisions, progress and measurements

## License

Apache License 2.0. See [LICENSE](LICENSE).
