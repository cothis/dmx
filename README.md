# dmx

A Docker-compatible container engine for Apple Silicon Macs that gives memory back, built to be
driven by AI agents as easily as by people.

> Early development (0.x). dmx runs dockerd, Compose and BuildKit in its own small Linux VM on
> Hypervisor.framework. The VM starts on first use, stops when idle, and returns memory the guest
> frees within seconds.

| Same Mac, 2 CPUs / 4 GiB VM | dmx | OrbStack | Colima | Docker Desktop |
|---|---|---|---|---|
| Idle | **222 MB** | 379 MB | 1100 MB | 1026 MB |
| Idle CPU | **0.4 %** of one core | 0.5 % | 0.7 % | 0.5 % |
| While a container holds 2 GiB | **2390 MB** | 2693 MB | 3160 MB | 3154 MB |
| After it frees the 2 GiB (10 s at most) | **356 MB** | 2699 MB | 3164 MB | 3157 MB |
| Warm `docker run --rm alpine true` | 104 ms | 97 ms | 52 ms | 63 ms |

Medians of three rounds on a quiet Mac, measured with dmx 0.3.0; dmx 0.3.6 measured the same
([re-check](docs/benchmark.md#dmx-re-check-2026-10-27-036)). Whole engine, VM included. Idle memory is the steady
state 95 s after the last command: dmx's dips to 194 MB when it trims the guest and settles at
222 MB. OrbStack gives the 2 GiB back about 20 s after the container exits, past the 10 s this
table allows; Colima and Docker Desktop still hold it five minutes later. Method, raw data
and caveats: [docs/benchmark.md](docs/benchmark.md#results-2026-10-26-dmx-030-quiet-mac). dmx's `docker run` is
slower than Colima's because dmx keeps write ordering on the data disk across a power cut
([why](docs/benchmark.md#warm-docker-run-profile-2026-10-25)).

## Why dmx

- **Memory that comes back.** Most engines grow their VM to its limit and keep it. dmx's own VMM
  returns freed guest pages to macOS, adds RAM to the guest only as it needs it, trims caches when
  idle, and powers the VM off after 5 minutes with nothing running (the daemon then exits).
- **Docker compatible.** The stock `docker` CLI, Compose and BuildKit against a Docker Engine API
  socket; published ports, bind mounts of Mac paths, `host.docker.internal`, the Mac's SSH agent
  at `/run/host-services/ssh-auth.sock`, restart policies and amd64 images work as on Docker
  Desktop. amd64 and 386 images run through FEX-Emu with the Apple CPU's hardware TSO memory
  model, in place of Docker Desktop's Rosetta; `dmx config set x86_emulator qemu` switches to QEMU
  (amd64 only). dmx
  installs pinned copies of the CLI tools, so neither Homebrew nor Docker Desktop is needed.
- **AI native.** Every command has `--json` and structured errors with a hint naming the next
  command; nothing prompts. `dmx mcp` gives AI clients the engine itself over MCP, with capped
  output, and disposable sandboxes with a network and file policy, resource limits, a TTL, and
  checkpoints to roll back to or fork from.

## Quick start

Requires macOS 15 or later on Apple Silicon. Intel Macs are not supported.

```sh
curl -fsSL https://github.com/cothis/dmx/releases/download/v0.3.9/install.sh | sh
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
dmx update                       # install the newest release over this one
```

### Updating

`dmx update` downloads the newest release, checks it against the sha256 published beside it and
against the Developer ID the running dmx is signed with, and replaces the binary it is running
from; `dmx update --check` only says whether a newer one exists. The Linux guest follows by
itself: the new dmx knows the sha256 of its own guest and downloads it before the next boot, and
skips that download when the release ships the kernel, initramfs and Docker image already on disk
(a patch release usually does, so updating moves 1.8 MB rather than 64).

A VM that is running is left alone, because its containers are. The daemon serving it is still the
old version until it exits, which `dmx update` says: `dmx stop` powers the VM off and the daemon
exits a few seconds later, so the next command runs the new version. Any command that reaches a
daemon of another version says so too, and `dmx doctor` names both.

`dmx update` is in v0.3.1 and later; from v0.3.2 it also checks who signed the download. From v0.3.0 or earlier, update once by running the install
script, which replaces the binary the same way:

```sh
curl -fsSL https://github.com/cothis/dmx/releases/latest/download/install.sh | sh
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

**Signing and notarization.** Every release from 0.2.0 on is signed with the Developer ID
"Developer ID Application: MINHO YUN (V4YA23448U)", with the hardened runtime, a secure timestamp
and a single entitlement (`com.apple.security.hypervisor`), and notarized by Apple. Macs that
allow only notarized software run it, and a copy downloaded with a browser asks once before its
first launch. (0.1.0 was ad-hoc signed.) To check an installed copy:

```sh
codesign -dv --verbose=2 ~/.local/bin/dmx 2>&1 | grep -E 'Authority|TeamIdentifier'
codesign --verify --strict --check-notarization ~/.local/bin/dmx && echo notarized
```

`spctl --assess` says "the code is valid but does not seem to be an app" for any command-line
tool. That is not a rejection. A command-line tool cannot carry a stapled ticket, so Gatekeeper
looks the notarization up online at first launch. `dmx update` installs only a binary signed by
the same team.

**What dmx contacts.** GitHub Releases for dmx updates and the guest, and `download.docker.com` and GitHub
for the docker CLI tools; `dmx config set release_url …` and `tools_url …` point both at a
company mirror (files keep their upstream names; `dmx tools ls --json` lists the URLs), and dmx
checks the guest and tools against sha256s built into it. Self-updates use the published sha256
and the running binary's Developer ID team (the signature check is skipped for ad-hoc source
builds). No telemetry. Containers
and image pulls reach the network through dmx's own host sockets, so the Mac's VPN, firewall and
routing apply to them as to any app.

**Where data lives.** Everything is under `~/.dmx` (`DMX_HOME` to change): the guest, the
settings, and the data disk `data.img` (a sparse file, 64 GB at most by default, holding images,
containers and volumes). Space the guest frees on it goes back to the Mac when the files are
deleted, and anything that missed that at the next idle moment.

**Security model.** Defaults follow Docker Desktop. `/Users`, `/Volumes`, `/private`, `/tmp` and
`/var/folders` are shared read-write with the VM at the same paths (`dmx config set shares` to
narrow them); the Mac user maps to root in the guest. `~/.dmx/docker.sock` is readable only by the
user. `dmx port` forwards bind 127.0.0.1 unless told otherwise; Docker's published ports follow
their bindings (`-p 8080:80` listens on all interfaces, as on Docker Desktop). The Mac's SSH agent
is reachable in the VM at `/run/host-services/ssh-auth.sock`, so a container that mounts it can
use the user's keys, as on Docker Desktop. Containers and
sandboxes share one VM and its kernel: their isolation is Docker's, not a VM per sandbox, and
sandboxes with a host allowlist can still resolve any DNS name. Report vulnerabilities as
described in [SECURITY.md](SECURITY.md).

**Proxies and Docker Engine settings.** dockerd pulls through the HTTP and HTTPS proxy set in
System Settings (Network, Proxies), with its exceptions; a proxy on the Mac's own loopback is
reached from the VM. Registry mirrors, insecure registries, a different proxy and other Docker
Engine settings go in `~/.docker/daemon.json`, as with Docker Desktop. Both apply at the VM's
next start (`dmx stop`). Proxy auto-configuration (PAC) files and proxies that ask for a password
are not supported yet; set such a proxy in daemon.json. Proxy settings apply to image pulls, not
to programs inside containers.

**Company certificates.** Root certificates an administrator or you added to the macOS keychain
and marked trusted (a TLS-inspecting proxy, an internal registry's CA) are trusted by dockerd and
BuildKit in the VM, as on Docker Desktop. Certificates handed out as a file go in
`~/.dmx/ca-certificates.pem`. Both apply at the VM's next start.

**DNS** in the VM goes through macOS's resolver, so names only a VPN's DNS servers know (split
DNS) and `.local` names resolve in containers as they do on the Mac.

**Known gaps:** PAC proxy configuration, shared-file ACLs, and connecting to arbitrary Mac Unix
sockets from containers. IPv6 is implemented in the VM network and published ports; external
IPv6 and an actual corporate TLS-inspection network still need acceptance tests in environments
that provide them. Progress is tracked in [docs/PLAN.md](docs/PLAN.md#next-up).

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
make fex       # build the guest's FEX-Emu inside a dmx VM (once per version)
make guest     # build ~/.dmx/guest from pinned Alpine Linux packages, the kernel, qemu and FEX
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
- `scripts/`: guest, kernel, qemu and FEX builds, release packaging, end-to-end tests on the real VM

## License

Apache License 2.0. See [LICENSE](LICENSE).

Docker is a trademark of Docker, Inc. dmx is an independent project, compatible with the Docker CLI
and Engine API; it is not affiliated with or endorsed by Docker, Inc.
