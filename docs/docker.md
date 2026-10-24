# Docker on dmx

The stock `docker` CLI and Compose talk to `~/.dmx/docker.sock` (`$DMX_HOME/docker.sock`), which
dmx forwards to dockerd in the guest. Nothing else is needed on the Mac: no Docker Desktop, no
root, no extra processes.

```sh
brew install docker docker-compose   # the CLI and the compose plugin
dmx install                          # launchd answers on docker.sock; selects the docker context "dmx"
docker run --rm hello-world
```

Without `dmx install`, `dmx start` (or any `dmx` command that starts the daemon) brings up the
socket, and `export DOCKER_HOST=unix://$HOME/.dmx/docker.sock` points the CLI at it. For
`docker compose`, Homebrew's plugin needs `"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]`
in `~/.docker/config.json` (Homebrew prints this; dmx does not edit it).

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
- **Configuration** (`/run/dmx/daemon.json`): `host-gateway-ips` 192.168.127.254 (the Mac, so
  `--add-host x:host-gateway` works as on Docker Desktop), `ip6tables` false (the guest network
  has no IPv6), `shutdown-timeout` 5 s (the host powers the guest off within 10 s; the agent
  sends dockerd SIGTERM and waits up to 7 s so containers stop cleanly). Everything else is
  Docker's default: overlayfs, the containerd image store, json-file logs, the userland proxy,
  cgroup v2 with cgroupfs. Images, containers and volumes live on the data disk
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
  Docker client boots it again (images stay on the data disk). Containers with a restart policy
  come back when dockerd next starts, that is, on the next Docker client, not at boot.
- The daemon learns about containers from dockerd's event stream (`start` and `die`, then a
  listing of running containers); that connection does not count as use.

## Published ports

Ports a running container publishes are forwarded from the Mac, like Docker Desktop does, through
the same machinery as `dmx port` ([daemon protocol](daemon-protocol.md#port-forwarding)): each
connection becomes a vsock stream to the agent, which connects to the port on the guest's
loopback, where docker-proxy listens.

- The host address is what the container asked for, as on Docker Desktop: `-p 8080:80` listens on
  0.0.0.0 (every interface; macOS may ask whether dmx may accept incoming connections),
  `-p 127.0.0.1:8080:80` on loopback only. Docker lists the IPv6 binding (`::`) of the same port
  too; only IPv4 is forwarded. Other addresses are not forwarded.
- They appear in `dmx port ls` with `source: docker`, are never written to `ports.json`, and go
  away when the container stops or the VM does.
- A port that is taken on the Mac (by another program, or by a `dmx port` forward) is logged in
  the daemon log and not forwarded; the container still runs. Docker Desktop fails `docker run`
  in that case.
- TCP only. UDP ports are published inside the guest but not forwarded.

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

`make dockertest` (`scripts/test-docker.py`) runs the stock CLI and Compose against a throwaway
`DMX_HOME` with a throwaway `DOCKER_CONFIG`, on host ports 20080 to 20090. It needs the internet
for Docker Hub. `swift test` covers the context store, the plist, published-port selection and
the DNS answers.

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
| `docker compose up -d` (2 services, volume, port, bind mount) | 3.8 to 21 s |
| Bind mount (`/tmp`, virtio-fs), 256 MB | read + md5 in a container 15.9 s incl. start; write with fsync 30 MB/s in a container, 108 MB/s from `dmx exec` at the same time: host load bound |
| Published port, 256 MB over HTTP from a container (busybox httpd reading a bind mount) | 5.8 to 12 s |
