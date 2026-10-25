# Guest network

The guest reaches the outside world through dmx's own virtio-net device (`HV/VirtioNet.swift`)
and a user space NAT in the dmx process (`HV/UserNet.swift`, `HV/UserNetTCP.swift`). The host
gets no network interface, and dmx needs no root and no entitlement beyond
`com.apple.security.hypervisor`. Inbound connections (host to guest ports) are not this; they
go over vsock (port forwarding).

## Why not vmnet.framework

vmnet gives a VM a real L2 network with NAT, DHCP and DNS from macOS, but only to root or to a
binary signed with `com.apple.vm.networking`, an entitlement Apple restricts to "developers of
virtualization software" by request ([socket_vmnet FAQ](https://github.com/lima-vm/socket_vmnet#faq),
quoting Apple's documentation). Tried on macOS 26.6.1 with an ad-hoc signed test program
(2026-10-24):

| Call | Result as a normal user |
|---|---|
| `vmnet_start_interface`, shared mode and host mode | `VMNET_FAILURE` (1001) |
| `vmnet_network_configuration_create` (new in macOS 26) | succeeds |
| `vmnet_network_create` (new in macOS 26) | `VMNET_MEM_FAILURE` (1002), no network |
| `com.apple.vm.networking` in an ad-hoc signature | the process is killed at launch (AMFI) |

The macOS 26 API (`vmnet_network_*`, used by Apple's `container`) is gated the same way. A
privileged helper (what socket_vmnet does) would need sudo at install time, which dmx avoids.

## Why a passt-like NAT

Options without privileges:

- **A full TCP/IP stack on the host** (libslirp in C, gVisor's netstack in gvisor-tap-vsock in
  Go). Proven, but a second language or process, and a stack that buffers per connection on its
  own.
- **Socket calls forwarded over vsock** (libkrun's TSI). No Ethernet at all, but it needs guest
  kernel patches that are not upstream, and changes how sockets behave in the guest.
- **Map guest flows onto host sockets without a TCP stack** ([passt](https://passt.top/passt/about/)).
  The host socket does the real TCP to the far end; dmx only speaks enough TCP to the guest:
  handshake, sequence numbers, acknowledgements, window, FIN and RST. Retransmits on the guest's
  side are the guest's job. Small, in Swift, inside dmx.

dmx takes the third. Traffic leaves as dmx's own sockets, so VPNs, the firewall and proxies
treat it like any app's.

## How it works

Addresses (static, set by `guest/init`; no DHCP or router advertisements, so eth0 is up before
the agent):

| Address | What |
|---|---|
| 192.168.127.2, fd64:646d:7800::2 | the guest (eth0, MAC 02:64:6d:78:00:02) |
| 192.168.127.1, fd64:646d:7800::1 | gateway. DNS over UDP is answered by macOS's own resolver through `DNSServiceQueryRecord` (`HostDNS.swift`), so the guest sees what Mac apps see: a VPN's per-domain servers (split DNS), `.local` names over multicast DNS, and the current network's servers after the Mac moves. CNAMEs come back as part of the answer; the Mac's loopback (its own `.local` name) becomes 192.168.127.254 or fd64:646d:7800::254, other loopback and link-local addresses are left out, and so are IPv6 addresses the Mac has no route to (a UDP `connect` looks the route up without sending anything), as Docker Desktop leaves out AAAA records on a Mac without IPv6; replies too large for the client's UDP limit (512 bytes, or its EDNS size) are truncated, and the retry over TCP goes to the first `nameserver` of `/etc/resolv.conf`, read at each boot. mDNSResponder reports a missing name and a missing record type alike, so a name that does not exist gets an empty NOERROR rather than NXDOMAIN. `host.docker.internal`, `host.dmx.internal` (192.168.127.254, fd64:646d:7800::254) and `gateway.docker.internal` (192.168.127.1, fd64:646d:7800::1) the gateway answers itself (`UserNetDNS.swift`). Answers ping. |
| 192.168.127.254, fd64:646d:7800::254 | the host: connections go to the host's 127.0.0.1 and ::1 (`host.dmx.internal` and `host.docker.internal` in the guest's /etc/hosts, IPv4 only) |
| anything else | the outside world, through host sockets |

- **ARP**: answered for .1 and .254 with the gateway's MAC.
- **IPv6**: the prefix is unique local (fd64:646d:7800::/64), so the guest's resolvers sort by
  RFC 6724 as they would behind any NAT66: a name with both A and AAAA records is reached over
  IPv4 first (a ULA source does not match a global destination's label), a name with only AAAA
  over IPv6. A Mac without IPv6 gets no AAAA records (above), so nothing changes there. Neighbor
  solicitations for ::1 and ::254 are answered with the gateway's MAC; duplicate address detection
  and router solicitations are off in the guest (no one else is on the link). Other ICMPv6
  messages and extension headers other than hop-by-hop, routing and destination options are
  dropped. Docker networks created with `--ipv6` reach out through dockerd's ip6tables NAT and
  then this one.
- **TCP**: a guest SYN opens a non-blocking host socket; the SYN-ACK goes back once `connect`
  succeeds (RST if it fails). Guest data is written to the socket as it arrives in order and
  acknowledged only as far as the socket took it; the window we advertise is the room left in the
  socket's 512 KB send buffer, so nothing from the guest is buffered in dmx. Host data waits in a
  per-connection buffer of at most 256 KB until the guest acknowledges it, so it can be sent again
  (three duplicate ACKs or 250 ms without progress, backing off). A closed guest window is
  probed; the guest's own probes are answered. MSS and window scaling are negotiated; SACK and
  timestamps are not.
- **UDP**: one connected host socket per guest flow, closed after 60 s idle (10 s for DNS); at most
  512, the least recently used goes first.
- **ICMP**: echo requests go out through an unprivileged ICMP socket (`SOCK_DGRAM`,
  `IPPROTO_ICMP` or `IPPROTO_ICMPV6`), which keeps the identifier and sequence; the gateway
  answers its own. macOS fills in ICMPv6 checksums and hands back no IPv6 header; an ICMPv6
  socket also receives its own requests to the loopback, so only replies are passed on.
- **Not handled**: IP fragments (the MTU makes them unnecessary), ICMP errors to the guest.

The device:

- **MTU 65520** (like passt): a 64 KB TCP segment crosses as one frame, with no TSO or
  segmentation code on either side. IPv6 headers are 20 bytes longer, so its MSS is 65460.
- **Mergeable receive buffers**: a large frame spans several small guest buffers, so the guest
  does not preallocate 64 KB per ring slot. All buffers of a frame are published to the used ring
  with one index update; publishing them one by one let the guest see a partial frame and drop
  it (about 500 drops per 500 MB before the fix).
- **64-entry receive ring**: Linux sizes each receive buffer by the average frame it got, so after
  a bulk transfer every posted buffer takes a whole 32 KB page fragment, and they stay posted
  while the guest is idle: 8 MB of guest memory with 256 entries, 2 MB with 64 (kpageflags:
  +220 vs +47 order-1 pages after 3 × 500 MB). Host to guest throughput did not drop (500 MB
  in a median 0.37 s with 256, 0.28 s with 64, 12 runs each, interleaved).
- **Checksums skipped both ways** (`CSUM`, `GUEST_CSUM`; frames to the guest carry
  `DATA_VALID`): the NAT ends every flow, so no one would check them. IP header checksums are
  still computed, and UDP over IPv6 always gets one: a zero UDP checksum is invalid in IPv6 and
  Linux drops the datagram before it looks at `DATA_VALID` (the first IPv6 DNS replies went
  missing this way). If containers ever forward these frames somewhere that checks, compute them
  (the code path exists for drivers without `GUEST_CSUM`; with both offloads off, 500 MB took
  0.53 to 0.57 s down and 2.9 s up through busybox nc, against 0.25 to 0.5 s and 2.4 to 3 s, on a
  noisy host).
- **Memory**: frames waiting for guest buffers are capped (TCP stops producing at 512 KB, other
  frames are dropped past 4 MB), TCP buffers are capped per connection, and scratch buffers are
  reused. dmx's own memory does not grow with traffic.

## Measurements (2026-10-24, 8G, 10 vCPU, host load 7 to 20)

| What | Result |
|---|---|
| Idle footprint with the device | 115 to 118 MB (114 to 117 without) |
| 500 MB host → guest (`wget` from a server on the host's 127.0.0.1) | 0.25 to 0.5 s (1 to 2 GB/s) |
| 500 MB guest → host (`dd bs=64k \| nc`, Python receiver) | 0.9 to 1.4 s (380 to 600 MB/s) |
| 394 MB from the internet over HTTP | 32.1 s in the guest, 32.07 s with curl on the host |
| DNS (`dmx exec -- nslookup`) | 70 to 100 ms per call, `dmx exec` included |
| ping host / gateway | 0.2 to 0.3 ms |
| Footprint after traffic | +15 to 17 MB after 3 × 394 MB from the internet, flat after that; dmx's own malloc 3 to 5 MB. The rest is guest memory freed in blocks below the free page reporting order (512 KB), left fragmented by network buffers. Since the idle sweep (2026-10-24), what stays is mostly the posted receive buffers: guest used +8 to 9 MB and footprint +11 to 12 MB after 3 × 500 MB with a 256-entry ring, +3 to 4 and +5 to 6 MB with 64. |

HTTPS: busybox `wget` needs `ssl_client`, OpenSSL and the CA bundle, which the initramfs drops.
Keeping them (all in the pinned minirootfs) makes HTTPS work with certificate checking, at
+2.8 MB of initramfs and about +12 MB of idle footprint (128 to 129 MB in that experiment).
The base guest omits them; containers provide their own TLS libraries and certificates, and
dockerd's delivery image includes the CA bundle for registry access.
