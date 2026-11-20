# Review of the unreleased work after v0.4.8 (2026-11-20)

The maintainer asked for a full audit with Mythos 5.2 (run as the `fable` agent model,
`claude-fable-5-2`, read-only, `swift test` allowed) and a review with Codex `gpt-6.2-sol`
(`codex exec -s read-only`). Scope: `5cb05c3..80716f3` (everything since v0.4.8: bench, soak,
crash recovery, import and `dmx_import`, local names, the DockerAPI changes, MallocSettings,
vCPU QoS, the agent's restart rule, re-pinned guest inputs). Both said RELEASE BLOCKERS. Every
finding was checked against the code; all but one were real. Codex's report is
[here](2026-11-20-unreleased/codex-gpt-6.2-sol.md); Mythos's findings are summarised below.

## Fixed

| Finding | From | Fix and evidence |
|---|---|---|
| A TLS listener and leaf per SNI name, never freed: any page or program, or a container, could exhaust the daemon's fds | both (blocker) | Listeners only for running containers' names, closed with them. namestest `tls_unknown_names_refused` and `tls_failures_leave_no_fds`: the previous build went 41 → 441 fds, this one 37 → 37 |
| A handshake that fails before `.ready` (an untrusting client, a scan) leaked a socket | both | The pump closes the socket and cancels the connection; same check |
| Containers reach any container's web port through `host.docker.internal` and names, skipping network isolation (`--internal` too) | both | UserNet refuses guest flows to the host ports names hold (GuestHostPorts); namestest `container_cannot_reach_names` fails on the previous build |
| The CA's name constraints did not bind IP SANs, so a leaked key could sign `https://<address>` | both (blocker for Codex) | excludedSubtrees for 0.0.0.0/0 and ::/0; unit test, which fails without them on this Mac's trust evaluation |
| Network connect/disconnect did not refresh the names table: a name could route to another container that took the address | Codex (blocker) | The events subscription includes network connect and disconnect |
| `dmx names remove` in another DMX_HOME removed the real resolver file | Codex | Only a home whose setup changed macOS removes it; a CA without its key keeps its certificate so the trust can still be found |
| Import changed the source: a pulled alpine stayed, and dockerd's copy-up could write the helper image's files into an empty source volume | Codex (blocker) | Helpers mount with `volume-nocopy`; what was pulled into the source is removed at the end |
| A volume made in dmx during an import was copied over (or deleted on failure) | Codex (blocker) | Checked again just before create; existing ones are left alone |
| A container was created on a volume whose copy failed or was skipped (then counted as imported) | Codex, Mythos | Not created, reported as failed; a rerun tries it |
| `--volumes-from` hid a container's own anonymous volumes; an inspect failure after create left a container without its data | Codex | Only the inherited volumes are left out; any copy problem removes the new container again; unit test |
| Interrupted imports and cleanup errors left helpers on both engines | Codex, Mythos | Helpers are labelled with the run's pid; each real run removes those of dead pids first; helpers are removed through the API whatever the other side did |
| `--dry-run` booted a stopped dmx (and so its restart-policy containers) | Codex | A dry run reads dmx only if its VM runs, and says so otherwise |
| Strings from the source went to the docker CLI as arguments | Mythos | Image references, volume and container names are checked (Docker's own rules) and passed after `--`; unit test |
| DockerAPI: a negative chunk size trapped; a complete chunked reply on an open connection waited; short replies were not errors | Codex | `chunks()` returns complete/incomplete/malformed; reading stops at the last chunk; short Content-Length and missing last chunk are errors; unit tests |
| A crash right after the first container started could skip the reboot | Codex | An event after the last listing counts as one running container for the crash decision |
| `on-failure:N` counted after its retries were spent | both | The agent compares the stored RestartCount with N; agent unit test |
| `verify-apk.py`: a fourth gzip stream (packaged, not signed) passed; key names unchecked; the minirootfs read from cache unchecked | both (blocker for Codex) | Exactly three streams, plain key names, the minirootfs fetched through build-guest.py's sha256 check; a crafted fourth stream fails; the 122 new pins pass |
| `dmx bench` removed a same-named container it had not made | Codex | A random suffix in the name |
| A forward that failed to listen kept names yielded on its port | Mythos | `holdsTCP` counts only forwards that listen; names look again 1 s after yielding |
| No check that launchd socket activation survives MallocSettings' re-exec | Mythos | `make launchdtest` (`scripts/test-launchd-reexec.py`), a launchd agent of its own label: 9/9, through both the control and the Docker socket |
| bench's idle window vs a short `idle_timeout`; hint-less DMXErrors; stale comment; docs saying import "only reads" the source; names docs | Mythos | A bench warning; hints added; comment and docs corrected |

## Not changed

- Image labels can claim a Compose service's name (`com.docker.compose.project/service` in an
  image): containers carry their image's labels and nothing marks which a user set. Kept as a
  limitation in docs/names.md's terms (names follow labels, as Compose does).
- `dmx names setup`/`remove` wait on macOS's dialogs without a time limit, also with `--json`: an
  approved design (the dialogs are the user's answer), not changed.
- Image tags have the same race as volumes between listing and `docker load`; a tag made in
  that window would be overwritten. Not changed (a narrower window than the volume one, and a
  load cannot be told not to).

## Checks after the fixes (this Mac, rebuilt guest in a separate DMX_HOME)

Unit 168 and the agent's 8; namestest 35/35 (32/35 on the previous build: the three new checks);
crashtest 40/40; daemontest 63/63 (twice); sandboxtest 44/44; mcptest 38/38; dockertest 81/81;
importtest 29/29; launchdtest 9/9; selftest 23/23 at 96 MB.
