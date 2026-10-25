# Docker on dmx

The stock `docker` CLI, Compose and Buildx talk to `~/.dmx/docker.sock` (`$DMX_HOME/docker.sock`),
which dmx forwards to dockerd in the guest. dmx brings the CLI and its plugins itself, as Docker
Desktop does: no Homebrew, no Docker Desktop, no root, no extra processes.

```sh
dmx install                # launchd answers on docker.sock; selects the docker context "dmx";
                           # installs docker, docker compose and docker buildx
docker run --rm hello-world
docker build .             # BuildKit
```

Without `dmx install`, `dmx tools install` installs the tools alone, `dmx start` (or any `dmx`
command that starts the daemon) brings up the socket, and
`export DOCKER_HOST=unix://$HOME/.dmx/docker.sock` points the CLI at it.

## The docker CLI, Compose and Buildx

`dmx install` and `dmx tools install` download pinned darwin-arm64 builds, check each against the
sha256 built into dmx (`Sources/DMXCore/DockerTools.swift`), and put them in `~/.dmx`:

| Tool | Version | From | Installed as |
|---|---|---|---|
| docker CLI | 29.9.2 (as dockerd in the guest) | download.docker.com `mac/static/stable/aarch64/docker-29.9.2.tgz` (19 MB) | `~/.dmx/bin/docker` (41 MB) |
| docker-credential-osxkeychain | 0.9.12 | github.com/docker/docker-credential-helpers (2.3 MB) | `~/.dmx/bin/docker-credential-osxkeychain` |
| Compose | 5.6.1 | github.com/docker/compose `docker-compose-darwin-aarch64` (29 MB) | `~/.dmx/cli-plugins/docker-compose` |
| Buildx | 0.38.1 | github.com/docker/buildx `buildx-v0.38.1.darwin-arm64` (62 MB) | `~/.dmx/cli-plugins/docker-buildx` |

About 113 MB to download and 136 MB on disk. The GitHub releases publish `checksums.txt`, which
the pins match; download.docker.com publishes none for the static CLI, so its pin is the tgz as
first downloaded (and the sha256 of `docker/docker` inside it).

- **Downloads** go to `~/.dmx/downloads/<file>.part` and resume from there (HTTP range) when
  interrupted or rerun; failed attempts are retried four times. Only a file with the pinned size
  and sha256 is used; it is renamed over the installed file, so a half-written binary is never in
  place and a running copy keeps its file. A mismatch deletes the download (`checksum_mismatch`);
  network trouble keeps it (`download_failed`, hint: run `dmx tools install` again). Installed
  files with the right sha256 are not downloaded again; a changed one is replaced.
- **Plugins** reach the CLI through `cliPluginsExtraDirs` in `$DOCKER_CONFIG/config.json` (default
  `~/.docker`), as Docker Desktop's do: `~/.dmx/cli-plugins` is put first in the list, so dmx's
  copies win over another install of the same plugin (Homebrew's, say), and the other keys and
  entries stay. `~/.docker/cli-plugins` is not touched.
- **`docker` on PATH**: if `~/.local/bin` (where `make install` puts dmx) is on PATH, `docker` and
  the credential helper are linked there, unless something else already has the name. dmx does
  not edit shell rc files: `dmx tools ls` says which `docker` PATH finds and, if it is not dmx's
  (Homebrew's comes first, or `~/.local/bin` is not on PATH), what to change
  (`export PATH="$HOME/.dmx/bin:$PATH"`).
- **Credentials**: with `docker-credential-osxkeychain` on PATH and no credentials in config.json,
  the CLI uses the macOS keychain for `docker login`, as with Docker Desktop, instead of storing
  them base64-encoded in config.json.
- **BuildKit**: with the buildx plugin present, `docker build` runs `docker buildx build` on the
  `default` builder (docker driver), which is dockerd's built-in BuildKit, and `docker compose build`
  goes through Buildx as well. Multi-stage builds, `RUN --mount=type=cache` and the rest of
  BuildKit's Dockerfile features work; the build context is sent over the same docker.sock.
  `DOCKER_BUILDKIT=0` still selects the deprecated legacy builder. `--no-cache` also gives
  `RUN --mount=type=cache` steps an empty cache mount; a step that reruns for another reason
  (a changed input or build argument) sees what earlier runs left there.
- `dmx tools ls` shows versions, paths and states (`present`, `missing`, `changed`);
  `dmx tools uninstall` and `dmx uninstall` remove the files, the links that point at them and
  the plugin directory from the docker config.

## What runs where

```
docker CLI ──▶ ~/.dmx/docker.sock ──▶ dmx daemon ──vsock──▶ dmx-agent `connect` ──▶ /var/run/docker.sock
                (launchd or the daemon)        │                                         dockerd ─ containerd ─ runc
                                               └─ follows /events: published ports, running containers
```

- **Versions**, pinned by sha256 in `scripts/build-guest.py` from Alpine 3.24 aarch64:
  docker-engine 29.9.2 (dockerd, docker-proxy), containerd 2.3.7, runc 1.4.3, tini-static 0.19.0
  (docker-init), iptables 1.8.13 (nf_tables backend) with libxtables, libnftnl, libmnl,
  libseccomp 2.6.1, ca-certificates-bundle 20261020. Signatures were checked against the Alpine
  keys in the minirootfs when they were pinned.
- **Delivery.** These are ~160 MB unpacked, too much for the initramfs, which lives in guest RAM.
  `make guest` writes them as `guest/docker.img`: a 4 KB header (`dmx-docker 1`, the sha256 and
  length of the payload) and a gzip'd tar (52 MB), attached as a read-only virtio-blk disk with
  the serial `dmx-docker` (`VIRTIO_BLK_F_RO`; the host opens it read-only with a shared lock).
  The first time Docker is used after the payload changes, the guest unpacks it onto the data disk
  at `/var/lib/dmx/docker` and records the sha256; later starts only compare it. Alternatives
  considered: an ext4 or squashfs image needs mke2fs or mksquashfs, which macOS lacks; building the
  image in the VM adds a step that a plain tar does not need; unpacking from a share would add a
  virtio-fs device for one read. The netfilter, bridge and network driver modules Docker loads
  (236 with af_packet, 1.5 MB) come in the same tar, with the kernel's module index; the initramfs gained only the
  3 KB start script (`/sbin/dmx-docker`, from `guest/docker`).
- **qemu-x86_64** (`docker run --platform linux/amd64`, and x86 programs in `dmx exec`) is built by
  `make qemu` from pinned QEMU 11.0.3 source like Alpine's static build, with one dmx patch: the
  x86_64 guest base defaults to 2^47 so programs never see addresses above x86-64's 47-bit user
  space ([compatibility.md](compatibility.md#amd64-address-layout-fixed-in-dmxs-qemu-x86_64)). It comes xz'd
  (1 MB) after the tar in docker.img; the header gives its sha256, offset and length. `/init`
  unpacks it onto the data disk (`/var/lib/dmx/qemu`) when the copy there is another version and
  registers it with binfmt_misc at every boot, before anything runs, so x86 support does not wait
  for Docker. It used to be in the initramfs, where it cost ~2 MB of idle footprint.
- **Started on first use.** Nothing of Docker runs until a client connects to docker.sock after a
  boot. The daemon then calls the agent's `docker_start`, which runs `guest/docker`: unpack if
  needed, bind the module tree over /lib/modules (the kernel's own module loader runs modprobe in
  the root namespace), preload nf_tables, write `/run/dmx/daemon.json` and start dockerd. The
  agent returns once `/var/run/docker.sock` answers; dockerd starts its own containerd.
- **dockerd's mount namespace.** dockerd runs in its own mount namespace where `/usr` is an
  overlay of the unpacked tree over the guest's (binaries at the paths they were built for, no
  `PATH` or `LD_LIBRARY_PATH` that could leak into containers), `/etc/ssl` holds the CA bundle,
  and `/tmp` and `/var/folders` are the Mac's (see [Bind mounts](#bind-mounts)). The guest's root
  is the initramfs, where `pivot_root` fails; runc jails containers with `pivot_root`, and its
  fallback for ramdisks (`DOCKER_RAMDISK`, chroot after `MS_MOVE`) is weaker. So, as switch_root
  does, a recursive bind mount of `/` is moved on top of `/` and dockerd is chrooted into it: a
  root that is a mount with a parent, where `pivot_root` works. Only chrooting into the bind mount
  (without the move) was not enough: `docker exec` enters a container's mount namespace with
  `setns`, which roots the process at the topmost mount on the namespace's `/`; with nothing
  mounted there, exec'd processes landed in the guest's initramfs instead of the container.
- **Your settings.** `daemon.json` in the docker config directory (`~/.docker/daemon.json`, or
  under `$DOCKER_CONFIG`), where Docker Desktop keeps its Docker Engine settings: registry
  mirrors, insecure registries, proxies, labels, BuildKit's `builder` options and anything else
  dockerd reads. The daemon merges it under dmx's keys when dockerd starts, once per boot, so
  `dmx stop` applies a change. Keys dmx sets itself (`hosts`, `host-gateway-ips`, `ip6tables`,
  `shutdown-timeout`, `data-root`, `exec-root`, `pidfile`, `containerd`) are ignored, with a line
  in the daemon's log. A file that is not a JSON object fails the Docker client with
  `docker_config_invalid` and the file's path; a key dockerd rejects shows in dockerd's log.
- **Configuration** (`/run/dmx/daemon.json`): `host-gateway-ips` 192.168.127.254 (the Mac, so
  `--add-host x:host-gateway` works as on Docker Desktop), `ip6tables` false (the guest network
  has no IPv6), `shutdown-timeout` 5 s (the host powers the guest off within 10 s; the agent
  sends dockerd SIGTERM and waits up to 7 s so containers stop cleanly). Everything else is
  Docker's default: overlayfs, the containerd image store, json-file logs, the userland proxy,
  cgroup v2 with cgroupfs. dockerd and its containerd run in the `/dmx-docker` cgroup and
  containers in `/docker/<id>`: from the root cgroup, which has no `memory.swap.max`, dockerd
  reported no swap limit support, warned on every `--memory` and left swap unlimited. Images, containers and volumes live on the data disk
  (`/var/lib/docker`, `/var/lib/containerd`). dockerd's log is `/var/lib/dmx/log/dockerd.log`
  (`dmx exec -- tail /var/lib/dmx/log/dockerd.log`), the previous one `dockerd.log.1`.

## The socket

`~/.dmx/docker.sock` is mode 0600 (only this user, as `/var/run/docker.sock` is root's and the
docker group's on Linux). Each connection boots the VM if it is stopped and starts dockerd if it
is not running, then is spliced to the guest's socket through the agent's `connect` with a
`path` ([agent protocol](agent-protocol.md#connect)); bytes are copied as for a forwarded port. If
dockerd cannot start, the client gets an HTTP 503 whose message the CLI prints
(`Error response from daemon: dmx: ...`) with the command that shows the log.

- **launchd** (`dmx install`): the plist's `Sockets` has `Listeners` (dmx.sock) and `Docker`
  (docker.sock), so the first Docker client starts the daemon like the first `dmx` command does.
  `dmx install` also writes the docker context `dmx` into the docker CLI's store
  (`$DOCKER_CONFIG`, default `~/.docker`: `contexts/meta/<sha256 of "dmx">/meta.json`, host
  `unix://~/.dmx/docker.sock`) and sets `currentContext` in config.json, keeping its other keys
  and permissions; a config.json that is not JSON is left alone with an error. `dmx uninstall`
  removes the context and, if it was selected, the selection. `DOCKER_HOST` and `DOCKER_CONTEXT`
  still override it, as with any context.
- **Standalone** (no `dmx install`): the daemon binds docker.sock itself and removes it on exit.
  Since nothing else would answer there, a daemon that has served a Docker client does not exit
  when the VM goes idle (4 MB with the VM stopped, as with forwarded ports) until `dmx stop`.

## Memory and idle stop

- dockerd and containerd start only on first use: they cost ~55 MB of guest memory at idle (see
  [Measurements](#measurements-2026-10-24-8g-10-vcpu-host-load-25-to-50-from-other-agents-vms)),
  which a VM that never sees a Docker client does not pay.
- An open docker.sock connection uses the VM (`docker run -it`, `docker logs -f`, `compose up`
  attached), and so does every running container: `containers` in `dmx status` is their number,
  and the VM stops for being idle only `idle_timeout` after the last one exits and the last client
  disconnects. Without containers, an idle VM stops as before, and dockerd with it; the next
  Docker client boots it again (images stay on the data disk).
- The daemon learns about containers from dockerd's event stream (`start` and `die`, then a
  listing of running containers); that connection does not count as use.

## Restart policies

Containers with `--restart always`, `unless-stopped` or `on-failure` come back when the VM boots,
as they do when Docker Desktop starts, without waiting for a Docker client. After every boot the
daemon asks the agent (`docker_autostart`), which reads dockerd's own records
(`/var/lib/docker/containers/*/hostconfig.json` and `config.v2.json`) and starts dockerd only if a
container would come back: one that was started before, was not stopped with `docker stop`, and
whose policy is `always` or `unless-stopped`, or `on-failure` after a non-zero exit. dockerd then
restarts them itself; their published ports are forwarded and they keep the VM running. A VM
whose containers have no restart policy, or were stopped by hand, starts no dockerd at boot and
costs what it did before: the check reads one directory that does not exist yet.

- A container stopped with `docker stop` does not bring Docker up at boot. dockerd still starts
  an `always` container again whenever dockerd itself starts (as on Linux after a daemon
  restart), so it comes back with the next Docker client after the VM was stopped. On Docker
  Desktop the VM keeps running, so this differs only after an idle stop or `dmx stop`.
- What boots the VM is unchanged: a dmx command, a Docker client, or a connection to a forwarded
  port. dmx does not start at login; Docker Desktop does if "Start Docker Desktop when you sign
  in" is on. With `dmx install` the daemon starts on the first connection, but the VM, and so
  the restartable containers, wait for one.

## Published ports

Ports a running container publishes, TCP and UDP, are forwarded from the Mac, like Docker
Desktop does, through the same machinery as `dmx port` ([daemon protocol](daemon-protocol.md#port-forwarding)):
each TCP connection, and each UDP peer, becomes a vsock stream to the agent, which connects to
the port on the guest's loopback, where docker-proxy listens.

- The host address is what the container asked for, as on Docker Desktop: `-p 8080:80` listens on
  0.0.0.0 (every interface; macOS may ask whether dmx may accept incoming connections),
  `-p 127.0.0.1:8080:80` on loopback only. Docker lists the IPv6 binding (`::`) of the same port
  too; only IPv4 is forwarded. Other addresses are not forwarded.
- They appear in `dmx port ls` with `source: docker`, are never written to `ports.json`, and go
  away when the container stops or the VM does.
- The host ports are taken before the container starts: the daemon reads requests on
  docker.sock, and for `POST /containers/{id}/start` (and `restart`) it looks up the container's
  port bindings and listens on them before passing the request on. A port another program (or a
  `dmx port` forward) has fails the start with Docker Desktop's error, and the container stays
  created (a `--rm` one is removed, as dockerd does after a failed start), as on Docker Desktop:
  `Error response from daemon: Ports are not available: exposing port TCP 0.0.0.0:8080 -> 0.0.0.0:0: listen tcp 0.0.0.0:8080: bind: address already in use`.
  `docker compose up` fails the same way. Taking the port first also means it answers as soon as
  `docker run -d` returns. Ports dockerd picks itself (`-P`, a host port range) are forwarded
  once the container runs; one taken on the Mac then is only logged.
- Everything else on docker.sock passes byte for byte: request bodies are followed by their
  `Content-Length` or chunked framing only to find the next request, and a request that upgrades
  the connection (attach, exec, BuildKit sessions) turns it into a plain copy
  (`Daemon/DockerProxy.swift`). Replies are copied as they come; only the status line of a
  start's reply is looked at, to end the reservation.
- UDP: each peer (address and port) that sends to a published UDP port gets its own vsock stream,
  carrying datagrams framed with a 2-byte length ([agent protocol](agent-protocol.md#connect));
  the agent sends them from its own socket, and replies go back to the peer from the published
  port. A peer's stream closes after 60 s without datagrams (docker-proxy keeps its own 90 s);
  while open it counts as using the VM. Datagrams are dropped rather than queued when the guest
  cannot take them, as on a network.

## Bind mounts

The default shares are Docker Desktop's: `/Users`, `/Volumes` and `/private`, read-write, at the
same paths in the guest (`dmx config set shares` changes them; [network.md](network.md) and
PLAN.md describe virtio-fs). Docker Desktop also lists `/tmp` and `/var/folders`, which on macOS
are symlinks into `/private`. In dockerd's namespace, `/tmp` and `/var/folders` are bind mounts of
`/private/tmp` and `/private/var/folders`, so `docker run -v /tmp/x:/x` and a `$TMPDIR` path name
the Mac's files, while the rest of the guest (`dmx exec`) keeps its own `/tmp`.

`docker run -v $PWD:/w` works for any directory under the shares. A path outside them (for
example under `/opt/homebrew`) does not exist in the guest, so dockerd creates it there, empty, as
it does for any missing `-v` source; Docker Desktop refuses such a mount ("Mounts denied").

Programs under dockerd keep their temporary files in `/var/lib/dmx/tmp` (`TMPDIR`), on the data
disk: virtio-fs has no Unix sockets, and runc's console socket for `docker run -t` lives there.

## Host names

From containers, `host.docker.internal` is the Mac (its 127.0.0.1, through the NAT's
192.168.127.254) and `gateway.docker.internal` the gateway, 192.168.127.1, as on Docker Desktop.
The NAT's DNS server answers both itself (`HV/UserNetDNS.swift`), so they resolve on the default
bridge (whose containers ask 192.168.127.1 directly) and on user-defined networks (dockerd's
embedded DNS forwards to it). The guest's /etc/hosts has them for dockerd itself.

## Tests

`make dockertest` (`scripts/test-docker.py`) runs dmx's own CLI, Compose and Buildx (installed by
`dmx tools install` into `$DMX_HOME/cache/docker-tools`, kept between runs, and called by absolute
path; Homebrew's are never used) against a throwaway `DMX_HOME` with a throwaway `DOCKER_CONFIG`
and `HOME`, on host ports 20080 to 20090. It needs the internet for Docker Hub. `swift test` covers
the context store, installing the tools (from file URLs), the plist, published-port selection
and the DNS answers.

`make imagetest` runs nine digest-pinned official images on arm64 and amd64, with actual SQL,
HTTP, JIT, mmap and persistence workloads. The 4K guest resolves the previous Python loader
and Java partial-msync failures; dmx's qemu-x86_64 keeps x86_64 addresses below 2^47, which
fixed the amd64 Redis (jemalloc) crash. All 18 rows pass. See [compatibility.md](compatibility.md)
for exact inputs and the full matrix, and [benchmark.md](benchmark.md) for the measurement protocol.

## Measurements (2026-10-24, 8G, 10 vCPU, host load 25 to 50 from other agents' VMs)

Timings are several times slower than on a quiet Mac; compare them only with each other.

| What | Result |
|---|---|
| `make dockertest` | 33 of 33 checks pass (twice, load 31 and 49); one earlier run had `docker run` time out after the idle-stop test, not reproduced by hand or in later runs |
| Initramfs | 2.04 MB (was 2.02: the start script); docker.img 52 MB, 167 MB unpacked on the data disk |
| Idle footprint, Docker not used | 121 to 124 MB (shares now /Users, /Volumes, /private: three virtio-fs devices) |
| First Docker use after the image changed (unpack + dockerd) | 17 to 35 s until `docker version` answers |
| dockerd start on a later boot | 1.5 to 4.7 s (`dockerd up in` in the daemon log) |
| Guest memory with dockerd + containerd idle | guest used 95 to 98 MB (+52 to 55: dockerd RSS 37 MB, containerd 25 MB, part of it file pages) |
| Footprint with dockerd idle, after the idle trim | 280 to 306 MB on a later boot, 338 to 472 MB right after unpacking. Guest used + cache explain ~190 to 230; the rest (~90 MB) is guest memory the host wrote (binaries read from the disk) or freed in small blocks; see the `double` and `frag` work in PLAN.md |
| One container (`busybox sleep`) | guest used +10 to 12 MB (the shim), footprint 321 MB (537 to 589 in the suite, after pulls and builds) |
| `docker run --rm hello-world` | with pull 11 to 27 s; warm 1.9 to 3.2 s; cold (VM stopped, dockerd not started) 8.8 s at load 31, 12.5 s at 25, 54 s at 49 |
| `docker pull alpine` | 5.3 to 8.9 s |
| `docker build` (FROM alpine, RUN, COPY; legacy builder, no buildx) | 8.6 to 24 s |
| dmx's docker tools (2026-10-24, load 15 to 20) | 112 MB downloaded in 10 to 11 s, 137 MB on disk; `dmx tools install` with everything present (sha256 of 137 MB checked) 0.17 to 0.3 s. `make dockertest` with dmx's CLI 29.9.2, Compose 5.6.1, Buildx 0.38.1: 43 of 43 checks (two runs, load 15 and 20; an earlier run failed only the cache-mount check, which used `--no-cache` and was fixed) |
| `docker build` with BuildKit (same Dockerfile, alpine pulled; load 15 to 20) | first 1.2 to 2.0 s; `--no-cache` 0.52 to 1.1 s, legacy builder (`DOCKER_BUILDKIT=0`) 0.64 to 1.1 s: about the same for so small a build. Multi-stage with a cache mount 3.3 to 3.8 s, `docker compose build` 0.8 to 1.6 s |
| `docker compose up -d` (2 services, volume, port, bind mount) | 3.8 to 21 s |
| Bind mount (`/tmp`, virtio-fs), 256 MB | read + md5 in a container 15.9 s incl. start; write with fsync 30 MB/s in a container, 108 MB/s from `dmx exec` at the same time: host load bound |
| Published port, 256 MB over HTTP from a container (busybox httpd reading a bind mount) | 5.8 to 12 s |

Later the same day, at host load 5 to 14:

| What | Result |
|---|---|
| `make dockertest` | 47 of 47 checks pass (UDP, taken ports, restart policies, amd64 added) |
| Initramfs | 2.06 MB (was 3.10 with qemu-x86_64 in it); docker.img 53 MB with qemu-x86_64.xz (1 MB) at its end |
| Idle footprint, Docker not used, later boot, 8G (3 boots each, alternating) | 92 to 94 MB, qemu in the initramfs 91 to 95: no difference left after the idle sweep. Selftest 108 to 110 both ways. |
| UDP published port (busybox `udpsvd` echo in a container) | first reply 0.14 to 0.19 s after `docker run -d` started; 2000 round trips 190 to 300 µs each; 50 and 200 new peers at once all answered on their first datagram (a Python echo; `udpsvd` itself drops some) |
| Restart policy at boot | `dmx stop`, `dmx start`: the `unless-stopped` container answers on its port 1.0 to 1.2 s after `dmx start` returns (dockerd up in 170 to 190 ms) |
| Through the docker.sock proxy | 50 MB stdin through `docker run -i` 1.4 s and through `docker exec -i` and back 1.1 s, checksums match; a 20 MB build context intact |

After virtio-mem and the pressure/status follow-up (2026-10-24, host load about 5), the current
suite passed **57 of 57 checks**, including dmx's bundled CLI tools, BuildKit, Compose,
TCP/UDP publishing, taken ports, restart policies and an amd64 image. Its settled host
footprints were 65 MB before Docker, 273 MB with dockerd idle, and 305 MB with one container;
first Docker use took 1.34 s. These are separate local runs after several memory fixes, not a
controlled comparison with the earlier measurements or another container engine.
