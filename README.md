# dmx

A container engine for macOS that stays out of your memory, built to be driven by AI agents as easily as by people.

> Early development. Today `dmx` boots its Linux VM, talks to a guest agent over vsock, runs a command or a console in it, and measures what the VM costs the host. Memory work and Docker compatibility come next.

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
| 3 | Memory: footprint tracking, smaller baseline, balloon controller | in progress |
| 4 | Daemon, launchd socket activation, idle stop | |
| 5 | Data disk, networking, port forwarding, file sharing | |
| 6 | Docker compatibility (dockerd in the guest first) | |
| 7 | Own runtime, replacing dockerd piece by piece | |
| 8 | `dmx mcp`, sandboxes, checkpoints | |
| 9 | Release: CI, guest artifacts, Homebrew | |

Measured on an M-series Mac (10 cores, 16 GB): the guest agent answers about 0.3 s after boot starts. On the host the idle VM costs 137 MB with a 2 GB ceiling and 181 MB with 8 GB (it was 170 and 356 MB), thanks to a 16K page guest kernel and no SWIOTLB bounce buffer. Getting under 150 MB at 8 GB and returning memory after use are the rest of phase 3.

## Build

Requires macOS 14+ on Apple Silicon, Xcode (Swift 6), Python 3, and Rust via rustup with the
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
- `Sources/dmx`: the command line
- `guest/init`: PID 1 inside the VM
- `guest/agent`: `dmx-agent`, the Rust guest agent on vsock ([protocol](docs/agent-protocol.md))
- `scripts/build-kernel.py`: builds the guest kernel in a dmx VM from pinned, checksummed sources and toolchain
- `scripts/build-guest.py`: builds the guest from pinned, checksummed Alpine Linux packages and that kernel
- `docs/PLAN.md`: full plan, decisions, progress and measurements

## License

Apache License 2.0. See [LICENSE](LICENSE).
