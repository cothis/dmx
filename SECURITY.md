# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: on
[github.com/cothis/dmx](https://github.com/cothis/dmx), open **Security**, then
**Report a vulnerability**. Please do not open a public issue for them.

Include the dmx version (`dmx --version`), the macOS version, and the steps or code that show the
problem. You should get a first answer within a week. Fixes ship in a new release; the report is
published as a GitHub security advisory once a fix is out, crediting you unless you ask otherwise.

## Supported versions

dmx is in early development (0.x). Only the latest release gets security fixes; upgrade by running
the install script of the newest release.

## Scope

In scope: anything that lets a guest, a container, a sandbox, or another local user reach what dmx
should not give them, for example host files outside the configured shares, writes to a share
mounted read-only, the dmx control socket or `docker.sock` of another user, a sandbox escaping its
network policy (other than by DNS lookups, a documented limitation), or a downloaded guest or tool
used without its pinned sha256 matching.

Out of scope, as documented behavior: containers and sandboxes in the one VM share its kernel, so a
guest kernel exploit reaches every container and the shared directories (see
[docs/sandbox.md](docs/sandbox.md)); the default shares are read-write as on Docker Desktop;
Docker's published ports listen on all interfaces unless bound to an address. Vulnerabilities in
dockerd, containerd, runc, QEMU or the Linux kernel belong upstream, but tell us too if dmx needs
a new release to pick up the fix.
