# Local names

`dmx names setup` gives every running container a name on this Mac, over HTTP and HTTPS,
without publishing a port:

```sh
dmx names setup                      # once: two macOS password dialogs
docker run -d --name web nginx
open https://web.dmx.local           # also http://web.dmx.local
docker compose up -d                 # service "api" in project "shop":
curl https://api.shop.dmx.local      # <service>.<project>.dmx.local
dmx names                            # the names and where they lead (--json)
dmx names remove                     # undo all of it
```

New after 0.4.8.

## Names

- `<container>.dmx.local` for every running container, in lower case with `_` as `-`
  (`My_App` is `my-app.dmx.local`). A name that is not a DNS name is left out.
- `<service>.<project>.dmx.local` for every Compose service, from the labels Compose sets, on
  the lowest-numbered replica. When it clashes with a container's own name, the service wins.
  The labels are the container's, which include its image's: an image that carries Compose's
  labels takes the service's name like Compose's own container would. Run images you trust.

Connections go to the container's address in the VM on its web port: the label
`dmx.http-port=<port>` if it has one, else 80 if it exposes 80, else the first of 8080, 3000,
8000, 5000 it exposes, else its lowest exposed TCP port, else 80. A container that exposes
nothing and listens elsewhere needs the label (`docker run -l dmx.http-port=3000 ...`, or
`labels:` in Compose). A name with no running container gets a 404 listing the names there are;
a container that refuses the port gets a 502 naming the label.

Names follow `docker ps`: one is there while its container runs, and gone when the VM stops.
They do not boot the VM.

## How it works

- **DNS.** `/etc/resolver/dmx.local` sends lookups under `dmx.local` to the daemon's DNS on
  `127.0.0.1:53530` (UDP). It answers `127.0.0.1` for every name under `dmx.local` (so a name
  resolves before its container is up), nothing for AAAA, and REFUSED for other names.
- **HTTP and HTTPS.** The daemon listens on ports 80 and 443 and routes each connection by its
  `Host` header or TLS server name to the container, through the guest agent's `connect`, as
  port forwards do. macOS lets a user listen on ports below 1024 only on the wildcard address,
  so the daemon listens on `0.0.0.0` and closes every connection that did not arrive on
  `127.0.0.0/8`: other machines get nothing. Containers get nothing either: their connections to
  the Mac (`host.docker.internal`) are refused on these two ports while names hold them, since
  names reach every container's web port and would skip Docker's network isolation. HTTPS
  listeners exist only for the names of running containers, and accept only names' own
  connections to them. Another DMX_HOME's daemon keeps its containers from these ports too (each
  daemon lists the ports it holds in `$TMPDIR/dmx-guarded-ports`); the block is TCP only. After a container starts, stops, is renamed or changes
  networks, connections wait (up to 3 s, then 503) until the container list is read again, so a
  name never goes to an address another container took meanwhile. No privileged helper runs.
- **TLS.** `dmx names setup` makes a certificate authority in `~/.dmx/names` (ECDSA P-256, key
  mode 0600, not in a keychain) whose name constraints permit `dmx.local` and the names under
  it only, and exclude every IPv4 and IPv6 address: macOS, browsers and curl reject anything
  else it signed, so trusting it cannot vouch for another site or address even if its key leaked.
  A CA made by an earlier dmx without the address exclusion is refused (`dmx names remove`, then
  `dmx names setup`). `dmx names remove` takes out the resolver file only if this DMX_HOME's
  setup wrote it and it is still as that setup wrote it. The daemon issues a leaf for each name on its first
  TLS connection, in memory, valid for 397 days, and offers HTTP/1.1 (ALPN) to the container.
  The CA is trusted for TLS in your login keychain, for your user only.
- **A container that publishes port 80 or 443** (`docker run -p 80:80`) takes the port while it
  runs, as before; names then work over the other port, and take the port back when the
  container stops. `dmx names` shows `yielded` meanwhile.

Settings are in `~/.dmx/names/names.json`; names are on while it exists. `dmx names setup
--dns-port`, `--http-port` and `--https-port` change the ports (with HTTP on another port, the
URLs need it: `http://web.dmx.local:8080`).

## What setup changes on macOS

| Change | Dialog | Undo |
|---|---|---|
| The CA in your login keychain, trusted for SSL for your user | your password (macOS's trust settings dialog) | `dmx names remove`, or delete "dmx local names CA" in Keychain Access |
| `/etc/resolver/dmx.local` (`nameserver 127.0.0.1`, `port 53530`) | an administrator's password | `dmx names remove`, or `sudo rm /etc/resolver/dmx.local` |

Running `dmx names setup` again changes only what is missing. `--no-system` makes the CA and
turns names on without either change: names then work with `curl --resolve
web.dmx.local:80:127.0.0.1 --cacert ~/.dmx/names/ca.pem`, which is how `make namestest` runs.
Firefox and Java keep their own trust stores and do not see the keychain's CA.

## Testing

`make namestest` (`scripts/test-names.py`) runs in a throwaway `DMX_HOME` with ports 18080, 18443
and 15353, macOS left alone: DNS answers, HTTP and HTTPS routing by name (container, Compose
service, the port label, a shared network namespace), 404 and 502, the leaf and ALPN, no trust
without the CA, a refused connection to the Mac's LAN address, 200 parallel HTTPS requests, a
100 MB download each way, a container taking the HTTP port and names taking it back, `dmx stop`,
and `dmx names remove`. `LocalNamesTests` cover the name table, DNS, the parsers and the CA,
including that macOS rejects leaves it signed for other names.
