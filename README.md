# dmx

A container engine for macOS that stays out of your memory, built to be driven by AI agents as easily as by people.

> Early development. Today `dmx` boots its Linux VM and gives you a console. Docker compatibility comes next.

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
| 2 | Guest agent (Rust) and vsock control channel | next |
| 3 | Memory: footprint tracking, smaller baseline, balloon controller | |
| 4 | Daemon, launchd socket activation, idle stop | |
| 5 | Data disk, networking, port forwarding, file sharing | |
| 6 | Docker compatibility (dockerd in the guest first) | |
| 7 | Own runtime, replacing dockerd piece by piece | |
| 8 | `dmx mcp`, sandboxes, checkpoints | |
| 9 | Release: CI, guest artifacts, Homebrew | |

Measured on an M-series Mac (10 cores, 16 GB): the guest boots in about 0.7 s and uses 64 MB inside. On the host the VM costs 170 MB with a 2 GB ceiling and 354 MB with 8 GB, because Linux keeps page metadata for its whole ceiling. Shrinking that is part of phase 3.

## Build

Requires macOS 14+ on Apple Silicon, Xcode (Swift 6) and Python 3.

```sh
make build     # swift build + ad-hoc sign with the virtualization entitlement
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
- `scripts/build-guest.py`: builds the guest from pinned, checksummed Alpine Linux packages
- `docs/PLAN.md`: full plan, decisions, progress and measurements

## License

Apache License 2.0. See [LICENSE](LICENSE).
