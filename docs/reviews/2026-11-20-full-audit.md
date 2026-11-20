# Full code audit (2026-11-20)

The maintainer asked for an audit of the whole code base, not a diff, after the three review
rounds of the unreleased work. Three Opus 5.5 agents (read-only, unit tests allowed) each took an
area: the VMM and the guest (Sources/DMXCore/HV, guest/agent, guest/init, guest/docker,
build-guest.py); the daemon and what it serves (Daemon/, Names/, Sandbox/, MCP/, Import, Bench,
Agent, host services); the CLI, installation, updates, the app and the build/release tooling.
Codex `gpt-6.2-sol` was asked for the whole repository three times and refused each time with
OpenAI's cybersecurity flag (the first two while reading the VMM and FUSE code, the third with
HV/ and guest/ left out), so it contributed nothing this time. All three Opus areas ended with
NO RELEASE BLOCKERS. Some findings are in code released with v0.4.8 (marked *released*).

## Fixed

| Finding | Area | Fix |
|---|---|---|
| A memory ceiling that is not boot RAM plus whole 128 MB blocks (`memory 3000M`) stopped the daemon at every VM boot (a precondition in VirtioMem) — *released* | VMM | The ceiling is rounded down to boot RAM plus whole blocks |
| The shares' open-file limits (4096 each, three shares) and the NAT's sockets add up past the daemon's descriptor limit — *released* | VMM | One budget of 6144 handles for all shares of a process |
| Guest-controlled values could trap or exhaust the daemon: a far timer compare value overflowed a multiplication, balloon statistics overflowed additions, a descriptor chain could make the host copy gigabytes, a guest ignoring vsock credit grew a stream's buffer without bound — *released* | VMM | Saturating arithmetic; chains read up to 1 MiB; a stream that overruns its credit is reset |
| `dmx stop` during a crash-recovery boot counted as a failed boot and booted again | daemon | A stop ends recovery; a cancelled boot is not retried |
| A guest that crashes at every start rebooted every minute for ever | daemon | After ten crashes in a row the VM stays down |
| A sandbox whose egress rules could not be set again after a restart kept running without them; rules were IPv4 only — *released* | daemon | Such a sandbox is stopped; an exec that finds no rule mark sets them or stops it; IPv6 is turned off inside sandboxes and their network is made without it |
| A UDP forward made a guest stream, a thread and descriptors per source port with no limit; TCP forwards had no connection limit (a LAN sender could use up the daemon's descriptors) — *released* | daemon | 512 UDP peers and 1024 TCP connections per forward |
| `dmx mcp` exited on stdin EOF without letting cancelled calls clean up (a sandbox exec's kill, an import's helpers) | daemon | Waits up to 10 s for them |
| Local names: sandboxes got names; each connection's head reader held a thread for up to 10 s with no limit; the boundary with other accounts on the Mac was not documented | daemon | Sandboxes left out; at most 256 head readers; documented |
| A `~/.docker/config.json` that is a symlink was replaced by a file with the link's 0755 mode — *released* | CLI | Changed where it points, keeping that file's mode; unit test |
| The app and `dmx install` downloading the Docker tools at once shared their partial files — *released* | CLI | One install at a time (a lock in DMX_HOME) |
| Failures that are not DMXError (a full disk during an update, a failing move) gave no JSON envelope; `dmx boot --json` with a bad size printed text — *released* | CLI | Every failure becomes a DMXError with a hint (`internal_error`); boot's arguments are parsed inside the report |
| The update hint's install.sh URL named a tag "latest" (404) — *released* | CLI | releases/latest/download/install.sh |
| A hand-edited config.json skipped `config set`'s checks (an emulator name goes on the kernel command line) — *released* | CLI | Checked when loaded |
| `dmx_config_set` (MCP) could change the release and tools URLs and the shares — *released* | CLI | Only cpus, memory and idle_timeout; mcptest checks a refusal |
| The release tag from GitHub's redirect was not checked as a version — *released* | CLI | Same check as a version given by hand |
| Guest and update downloads had no size bound before the hash — *released* | CLI | Bounded while downloading (the pinned size for the guest, 512 MB otherwise; Docker tools their size plus 1 MB) |
| A guest swap (`dmx guest fetch --force`) between the boot's check and the VM opening its files could mix versions — *released* | CLI | The daemon holds the guest lock shared until the VM has its files open |
| Hint-less DMXErrors in the config, guest lock and download paths | CLI | Hints added |

## Not changed

- A device reset while requests are in flight can complete an old request into the new ring
  (VirtioFS, VirtioBlock). The guest only resets devices right before powering off, so no path
  in dmx reaches it; a generation counter would close it if that changes.
- release.py: the aports archive for the GPL source bundle is fetched by commit without a
  pinned hash (its source files are checked against the APKBUILD's sha512 sums), and the
  release keychain's password goes to `security unlock-keychain -p` as an argument (no other
  non-interactive way); both run on the maintainer's Mac only, at release time.

## Checks after the fixes (this Mac, rebuilt guest in a separate DMX_HOME)

Unit 173; namestest 37/37, crashtest 40/40, daemontest 63/63, sandboxtest 44/44, mcptest 39/39
(the new refusal of `release_url`), dockertest 81/81, soaktest 28/28, launchdtest 10/10,
importtest 29/29, selftest 23/23 at 97–98 MB.
