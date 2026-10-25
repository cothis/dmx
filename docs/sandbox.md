# Sandboxes

A sandbox is a disposable Linux environment with a policy, meant for AI agents (through
[`dmx mcp`](mcp.md)) and for anyone who wants to run something they do not fully trust. It gets
nothing it was not granted: no network, no host files, a CPU, memory and process limit, and a
TTL after which it is removed. Code lives in `Sources/DMXCore/Sandbox`.

```sh
dmx sandbox create build --mount ~/src/app:/src --network dl-cdn.alpinelinux.org --ttl 1h
dmx sandbox exec build -- apk add --no-cache make gcc musl-dev
dmx sandbox checkpoint build tools                                    # the filesystem as it is now
dmx sandbox exec build -- sh -c 'cp -r /src /work && make -C /work'   # /src is read-only
dmx sandbox rollback build                                            # back to "tools"
dmx sandbox fork build build-b --checkpoint tools                     # a copy, to try another way
dmx sandbox logs web --since 10m                                      # any container's logs, capped
dmx sandbox rm build build-b
```

Every command takes `--json`; failures carry a stable code and a hint (`sandbox_not_found`,
`sandbox_exists`, `bad_sandbox_policy`, `mount_not_shared`, `checkpoint_not_found`,
`checkpoint_exists`, `bad_name`, `image_pull_failed`, `sandbox_create_failed`,
`sandbox_egress_failed`, `sandbox_exec_failed`, `sandbox_not_running`, `container_not_found`).

## What a sandbox is

A Docker container in dmx's VM, created through dockerd's API on `~/.dmx/docker.sock`
([docker.md](docker.md)). dmx keeps no state of its own about it: the container's labels hold its
name, its policy (as JSON) and its expiry, and checkpoints are images named
`dmx-sandbox/<name>:<checkpoint>`. So `docker ps` shows sandboxes as `dmx-sandbox-<name>`, and any
dmx process (the CLI, `dmx mcp`, the daemon) sees the same ones.

- **Main process.** `sleep` for the TTL under `tini` (Docker's `--init`), which keeps the sandbox up
  for `exec`; the image needs a `sleep` (busybox, coreutils). `--` and a command (MCP `command`)
  run that instead; its output is what `logs` shows. The image's entrypoint is not used.
- **Default image** `alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a`
  (the multi-arch index as of 2026-10-24): 4 MB to pull, a shell and busybox, pinned so a sandbox is the
  same tomorrow. Any image works (`--image`, MCP `image`); it is pulled on first use, without
  credentials (for a private registry, `docker pull` it first: an image dockerd has is used as is).
- **Names** are 1 to 40 of `a-z 0-9 - _ .`; without one, `sb-` and six hex digits.

## Policy

| Setting | Default | Notes |
|---|---|---|
| `network` | `none` | `none`: loopback only, no DNS. `all`: anything the guest reaches, including the Mac's own services through `host.docker.internal` and the LAN. A list of hosts, IPv4 addresses and CIDRs: only those (see below). |
| `mounts` | none | `HOST[:PATH][:rw]` (MCP `{"host", "path", "writable"}`). Read-only unless `rw`. The host path must exist and lie under dmx's shares (`/Users`, `/Volumes`, `/private`; `dmx config get shares`), and a writable mount needs a read-write share; symlinks are resolved on the Mac first (`/tmp/x` becomes `/private/tmp/x`). |
| `cpus` | 2 | CFS quota (`NanoCpus`). |
| `memory` | 1G | cgroup limit with no swap beyond it; the OOM killer acts inside the sandbox. |
| `pids` | 1024 | Fork bombs stop there. |
| `ttl` | 30m | At most 24h. Measured from creation (or from a fork); a rollback keeps it. |
| `env`, `workdir` | none, the image's | For the main process and every exec. |

Always on, not settable: `no-new-privileges`, Docker's default seccomp profile and capability set
minus `NET_RAW`, json-file logs capped at 2 x 10 MB, and the `dmx-sandbox` bridge (for `all` and
allowlists) with inter-container traffic off, so sandboxes cannot reach each other and Docker
keeps other networks' containers out.

### The egress allowlist

Rules are iptables (nf_tables) in the sandbox's own network namespace, set by dmx right after the
container starts: loopback, replies to connections already allowed, and the allowed addresses
are accepted; any other TCP connection gets a reset and anything else an ICMP "administratively
prohibited", so a blocked request fails at once instead of timing out. The `OUTPUT` policy is
`DROP` under them. `iptables` comes from Docker's tree in the guest; dmx runs it with `nsenter`
into the sandbox's namespace from the guest, so nothing is added to the image.

- **Why there and not elsewhere.** Rules in the sandbox's namespace go away with it (nothing to
  clean up, nothing to go stale when an address is reused), apply to every protocol, and need no
  proxy the program has to know about. The sandbox runs as root but without `CAP_NET_ADMIN`, so
  it cannot change them, and without `CAP_NET_RAW`, so packet sockets (`AF_PACKET` skips
  netfilter) and raw IP are not available to go around them. An allowlisting HTTP proxy would
  match on names rather than addresses and is a possible later addition; it only covers
  programs that use it.
- **Names are resolved once.** A hostname in the list is resolved on the Mac when the sandbox
  starts (the guest's DNS forwards to the Mac's resolver, so the answers match) and the addresses
  go into the rules (`allowed` in the output). A service whose addresses rotate (CDNs) can move
  off them; a rollback or fork resolves again. Use CIDRs for such services. IPv4 only: the sandbox network has
  no IPv6 (Docker turns IPv6 off on a container's interface when its network has none, so a
  sandbox has only `::1`), so there is nothing to allow or refuse over IPv6.
- **DNS works**, through Docker's resolver on 127.0.0.11 (loopback, then forwarded from outside
  the sandbox), so a program can look up any name even if it cannot connect. That is also a
  channel out: data can be encoded into DNS queries. With `none` there is no DNS.
- `host.docker.internal` in the list allows the Mac (192.168.127.254, which is the Mac's
  127.0.0.1 through dmx's NAT).
- A main process of the caller's waits until the rules are in place (a shell loop wrapped
  around it waits for a marker the rule script leaves), so it never runs unfenced; that needs
  `sh` in the image.
- If something with access to the Docker socket starts a sandbox's container itself
  (`docker start dmx-sandbox-x`), it runs without the rules. dmx only starts sandboxes through
  its own path, which sets them first; whoever holds the Docker socket can run anything anyway.

## Lifetime and the TTL

- The daemon removes a sandbox when its TTL runs out, with its checkpoints, whether or not the
  client that created it is still connected. It follows dockerd's containers through the agent
  (not docker.sock, so this does not count as using the VM) and wakes at the next expiry, or at
  least once a minute while sandboxes exist. Expiry is wall-clock time: a Mac that slept past it
  removes the sandbox on the next check after waking. `dmx sandbox ls`, `create` and the MCP list
  also sweep expired ones.
- **A running sandbox keeps the VM up**, as any running container does (`containers` in
  `dmx status`), until its TTL; then the VM stops after `idle_timeout` as usual. This is the
  trade: memory comes back when the sandboxes are gone, and the TTL bounds how long a forgotten
  one holds it. Remove sandboxes when done.
- `dmx stop` (or a crash, or a reboot of the Mac) stops the VM and every sandbox in it. Their
  filesystems stay; the next `exec` starts the sandbox again and sets its rules, unless its TTL
  has passed. A sandbox with a command of its own is not restarted (`sandbox_not_running`).
- `dmx sandbox rm` kills what runs in it and removes it and its checkpoints at once.

## Exec

`dmx sandbox exec NAME -- argv` (MCP `dmx_sandbox_exec`) is `docker exec`: argv runs directly, no
shell, as the image's user, in the sandbox's cgroup. The MCP tool and `--json` return the same
result as `dmx_exec`: exit code, head and tail of each stream within `max_output_bytes`, the
bytes left out, `timed_out` ([mcp.md](mcp.md#dmx_exec)). Without `--json` the output streams
through and dmx exits with the command's status; `-i` passes stdin (read to its end first).

Docker cannot kill an exec (closing its stream leaves the process running), so on a timeout,
Ctrl-C or MCP cancellation dmx asks dockerd for the process id and kills it and its descendants
from the guest, stopping each before listing its children so none slips out.

`signal` is always null: dockerd reports a killed process as exit code 128 + signal.

## Checkpoints, rollback, fork

- `checkpoint` is `docker commit` with the sandbox paused for that moment: the container's
  filesystem changes become an image layer. It does not include running processes or memory
  (CRIU is not in the guest; restoring processes is out of scope for now), nor mounted host
  directories, which are live host files: a rollback does not undo writes to a `rw` mount.
  `added_mb` is what the sandbox had changed since its image, `size_mb` dockerd's size of the
  image with its base layers (shared, stored once).
- `rollback [CHECKPOINT]` (default the latest) starts a new container from the checkpoint with
  the same policy and expiry, then removes the old one: what ran in it is killed. The sandbox's
  name stays; the container id changes.
- `fork NAME [NEW] [--checkpoint C]` starts a new sandbox with the same policy from a checkpoint,
  or from a commit of the current filesystem. Its TTL starts now (`--ttl` to change it) and its
  base shows as checkpoint `forked`. The copy is independent: overlayfs shares the unchanged
  layers, so a fork costs only what diverges.
- Removing a sandbox removes its checkpoint tags; an image a fork still runs from stays until
  the fork is removed.

## Logs

`dmx sandbox logs TARGET` (MCP `dmx_logs`) reads the logs of a sandbox's main process, or of any
container by name or id (Compose services included). `since` takes a duration back from now
(`10m`), an RFC 3339 time or Unix seconds; `tail` the last N lines. Both streams are capped like
exec output, and `summary` covers the whole log, including what the caps left out: line counts per
stream and `error_lines`, with the first and last 10 lines that look like errors (`error`,
`fatal`, `panic`, `exception`, `traceback`, `failed`, `denied`, `refused`, `cannot`, `oom`,
`killed`, `timeout`, ...; case-insensitive, whole words), each with its stream and line number.
A pattern match, not a model: cheap, deterministic, and wrong now and then.

## What isolation this gives, and what it does not

Sandboxes are containers: namespaces, cgroups, seccomp and dropped capabilities, sharing the
guest's Linux kernel with each other, with dockerd and with everything else in the VM. That is
the isolation Docker gives, no more:

- **A kernel exploit in a sandbox reaches the whole guest**: other sandboxes and containers, and
  dmx's shares, which are the Mac's `/Users`, `/Volumes` and `/private`, read-write by default.
  The VM boundary (Hypervisor.framework) still keeps the guest out of the rest of the Mac:
  processes, memory, other files, the keychain. For code you expect to be hostile, narrow the
  shares (`dmx config set shares ~/sandbox-work`) or wait for per-sandbox VMs (a possible later step; see
  "One long lived VM" in PLAN.md's Decisions).
- Processes run as root inside (the image's user), without user namespaces.
- There is no disk quota: a sandbox can fill the data disk (`disk_size`, 64 GB sparse by
  default).
- `all` reaches the Mac's localhost services through `host.docker.internal` and the local
  network, as any container on Docker Desktop does.
- The allowlist is by address; see its limits above (DNS, rotating addresses).

## Measurements (2026-10-24, 8G, 10 vCPU, host load 10 to 28 from other agents' VMs)

From `make sandboxtest` (`scripts/test-sandbox.py`) runs and by hand:

| What | Result |
|---|---|
| `make sandboxtest` | all checks pass (40, then 41 with the writable mount; 4 runs) |
| First create on a new data disk (boot, dockerd, pull alpine) | 6.2 to 6.9 s |
| Create, image present (`none`, `all`, allowlist with its rules) | 0.21 to 0.53 s |
| Exec of `true` through MCP or the CLI | 35 to 52 ms |
| Checkpoint, small change | 0.17 to 0.27 s; with 3 MB changed 1.0 s |
| Checkpoint size | 4 MB written: `added_mb` 3.8 |
| Rollback | 0.25 to 0.36 s |
| Fork from a checkpoint / from the current state | 0.19 to 0.40 s / 0.36 to 0.69 s |
| Remove | 0.09 to 0.14 s |
| TTL 10 s, creating client gone | removed after 10.3 to 10.5 s |
| Guest memory per idle sandbox (shim, tini, sleep) | 7.0 to 7.8 MB |
| Host footprint, 5 sandboxes after the suite's pulls and checkpoints | 444 to 483 MB (dockerd idle alone: 280 to 306, docker.md) |
