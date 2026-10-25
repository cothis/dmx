# dmx

A Docker-compatible container engine for Apple Silicon Macs that gives memory back, built to be
driven by AI agents as easily as by people.

> Early development (0.x). dmx runs dockerd, Compose and BuildKit in its own small Linux VM on
> Hypervisor.framework. The VM starts on first use, stops when idle, and returns memory the guest
> frees within seconds.

| Same Mac, 2 CPUs / 4 GiB VM | dmx | OrbStack | Colima | Docker Desktop |
|---|---|---|---|---|
| Idle | **180 MB** | 528 MB | 1097 MB | 1176 MB |
| While a container holds 2 GiB | 2373 MB | 2621 MB | 3172 MB | 3373 MB |
| 10 s after it frees the 2 GiB | **332 MB** | 618 MB | 3180 MB | 3362 MB |
| Warm `docker run --rm alpine true` | 118 ms | 123 ms | 73 ms | 99 ms |

Medians of three rounds on a moderately busy Mac; whole engine, VM included. Method, raw data
and caveats: [docs/benchmark.md](docs/benchmark.md#results-2026-10-25). dmx's `docker run` is
slower than Colima's because dmx keeps write ordering on the data disk across a power cut
([why](docs/benchmark.md#warm-docker-run-profile-2026-10-25)).

## Why dmx

- **Memory that comes back.** Most engines grow their VM to its limit and keep it. dmx's own VMM
  returns freed guest pages to macOS, adds RAM to the guest only as it needs it, trims caches when
  idle, and powers the VM off after 5 minutes with nothing running (the daemon then exits).
- **Docker compatible.** The stock `docker` CLI, Compose and BuildKit against a Docker Engine API
  socket; published ports, bind mounts of Mac paths, `host.docker.internal`, restart policies and
  amd64 images (through QEMU) work as on Docker Desktop. dmx installs pinned copies of the CLI
  tools, so neither Homebrew nor Docker Desktop is needed.
- **AI native.** Every command has `--json` and structured errors with a hint naming the next
  command; nothing prompts. `dmx mcp` gives AI clients the engine itself over MCP, with capped
  output, and disposable sandboxes with a network and file policy, resource limits, a TTL, and
  checkpoints to roll back to or fork from.

## Quick start

Requires macOS 15 or later on Apple Silicon.

```sh
curl -fsSL https://github.com/cothis/dmx/releases/download/v0.1.0/install.sh | sh
dmx install                      # launchd starts dmx on demand; installs docker, compose, buildx
                                 # and selects the docker context "dmx"
docker run --rm hello-world      # the first run downloads the Linux guest (~62 MB, sha256-checked)
```

The script installs `dmx` into `~/.local/bin` without sudo. `dmx install` is optional: without it,
`dmx exec` and `dmx start` start the daemon themselves.

```sh
dmx status                       # VM state, guest memory, host footprint (--json for scripts)
dmx exec -- uname -a             # run a command in the VM, booting it if needed
dmx shell                        # interactive shell in the VM
dmx stop                         # power off now instead of waiting for the idle timeout
dmx config set memory 8G         # also: cpus, idle_timeout, disk_size, shares; next boot
dmx port add 8080:80             # forward a host port to the VM (Docker's -p needs no command)
dmx doctor                       # check this Mac and the installation
```

### From an AI agent

```sh
claude mcp add dmx -- dmx mcp    # or any MCP client: the command is `dmx mcp` on stdio
```

The agent gets `dmx_exec`, `dmx_status`, `dmx_sandbox_create/exec/checkpoint/rollback/fork/rm`
and `dmx_logs`. A sandbox starts with no network and no host files; it gets only what it is
granted:

```sh
dmx sandbox create build --mount ~/src/app:/src --network dl-cdn.alpinelinux.org --ttl 1h
dmx sandbox exec build -- apk add --no-cache make gcc musl-dev
dmx sandbox checkpoint build tools
dmx sandbox exec build -- make -C /src     # /src is read-only unless granted
dmx sandbox rollback build                 # back to "tools"
```

See [docs/mcp.md](docs/mcp.md) and [docs/sandbox.md](docs/sandbox.md).

## Using dmx at work

**Licensing.** dmx is Apache-2.0: free for commercial use, modification and internal
redistribution, with a patent grant. It does not use Docker Desktop, so Docker Desktop's
subscription terms for larger companies do not apply; the docker CLI, Compose, Buildx, dockerd,
containerd and runc it uses are Apache-2.0 open source. The Linux guest also contains GPL programs
(the Linux kernel, QEMU, BusyBox, iptables and others), which run as separate programs in the VM;
using them carries no obligation, and every release attaches their complete source
(`dmx-sources-<version>.tar`) for anyone who redistributes dmx. `third-party.json` in each release
lists every component and its license. Docker Hub's own terms and pull limits still apply to
images pulled from it, whatever engine pulls them.

**What dmx contacts.** Only GitHub Releases (the guest, unless `DMX_RELEASE_URL` points at a
mirror), and `download.docker.com` and GitHub for the docker CLI tools. No telemetry. Containers
and image pulls reach the network through dmx's own host sockets, so the Mac's VPN, firewall and
routing apply to them as to any app.

**Where data lives.** Everything is under `~/.dmx` (`DMX_HOME` to change): the guest, the
settings, and the data disk `data.img` (a sparse file, 64 GB at most by default, holding images,
containers and volumes).

**Security model.** Defaults follow Docker Desktop. `/Users`, `/Volumes`, `/private`, `/tmp` and
`/var/folders` are shared read-write with the VM at the same paths (`dmx config set shares` to
narrow them); the Mac user maps to root in the guest. `~/.dmx/docker.sock` is readable only by the
user. `dmx port` forwards bind 127.0.0.1 unless told otherwise; Docker's published ports follow
their bindings (`-p 8080:80` listens on all interfaces, as on Docker Desktop). Containers and
sandboxes share one VM and its kernel: their isolation is Docker's, not a VM per sandbox, and
sandboxes with a host allowlist can still resolve any DNS name. Report vulnerabilities as
described in [SECURITY.md](SECURITY.md).

**Signing.** Releases are ad-hoc signed, not yet signed with a Developer ID or notarized. The
install script is not affected by Gatekeeper; a tarball downloaded with a browser needs
`xattr -d com.apple.quarantine dmx`. Managed Macs that allow only notarized software cannot run
dmx yet.

**Known gaps** that matter on company networks: dockerd does not yet use an HTTP(S) proxy set on
the Mac, and does not trust certificates added to the macOS keychain (TLS inspection), so image
pulls behind either fail today. Also missing: IPv6, split DNS, data disk resizing and boot-time
fsck. Progress is tracked in [docs/PLAN.md](docs/PLAN.md#next-up).

**Uninstalling.**

```sh
dmx uninstall          # remove the launchd agent and the docker context; powers the VM off
dmx tools uninstall    # remove dmx's docker, compose and buildx and their links
rm -rf ~/.dmx ~/.local/bin/dmx    # the guest, settings, and all images, containers and volumes
```

## Build from source

Requires Xcode (Swift 6), Python 3, and Rust via rustup with the guest target
(`rustup target add aarch64-unknown-linux-musl`; it links with the bundled `rust-lld`). Guest
inputs are pinned by sha256.

```sh
make build     # swift build + ad-hoc sign with the hypervisor entitlement
make kernel    # build the guest kernel inside a dmx VM (once per kernel version)
make qemu      # build the guest's qemu-x86_64 inside a dmx VM (once per version)
make guest     # build ~/.dmx/guest from pinned Alpine Linux packages, the kernel and qemu
make install   # copy dmx to ~/.local/bin (PREFIX=... to change)
make selftest  # boot, agent, memory return; then daemontest, dockertest, mcptest,
               # sandboxtest, x86test, imagetest, benchmark (see the Makefile)
```

How it works and what has been measured: [docs/PLAN.md](docs/PLAN.md) (goal, decisions,
phases, measurements), [docs/docker.md](docs/docker.md), [docs/network.md](docs/network.md),
[docs/compatibility.md](docs/compatibility.md), [docs/release.md](docs/release.md).

## Layout

- `Sources/DMXCore`: all logic, shared by the CLI, the daemon and the MCP server
  - `HV`: the VMM on Hypervisor.framework: vCPUs, GIC, virtio devices (console, rng, vsock,
    balloon with free page reporting, mem, blk, net with a user space NAT, fs)
  - `Daemon`: the daemon, memory controller, port forwarding, Docker socket proxy, launchd
  - `MCP`, `Sandbox`: `dmx mcp`, capped exec, sandbox policies and lifecycle
- `Sources/dmx`: the command line (argument parsing and output only)
- `guest/init`, `guest/agent`, `guest/docker`: PID 1, the Rust guest agent, Docker's start-up
- `scripts/`: guest, kernel and qemu builds, release packaging, end-to-end tests on the real VM

## License

Apache License 2.0. See [LICENSE](LICENSE).

Docker is a trademark of Docker, Inc. dmx is an independent project, compatible with the Docker CLI
and Engine API; it is not affiliated with or endorsed by Docker, Inc.
