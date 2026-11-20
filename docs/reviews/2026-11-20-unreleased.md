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

## Second round (Opus 5.5 and Codex gpt-6.2-sol, on `80716f3..6cd79a5`)

The maintainer asked for a second round without Mythos: Opus 5.5 (`opus` agent model, read-only)
and Codex `gpt-6.2-sol` (`codex exec -s read-only`), told to check that each fix above closes what
it claims and to look at the whole range again. Opus: NO RELEASE BLOCKERS, with fixes that missed a
path; Codex: RELEASE BLOCKERS ([report](2026-11-20-unreleased/codex-gpt-6.2-sol-round2.md)). Both
are right on these, all fixed:

| Finding | From | Fix and evidence |
|---|---|---|
| The per-name TLS listeners' ports on 127.0.0.1 were still reachable from containers through the host gateway | both | Their ports join the guard; namestest `container_cannot_reach_tls_listeners` (the previous build: all four `open`), with a control port the container does reach |
| The volume race was narrowed, not closed: a create that returns someone else's volume was still taken as new | both | The create carries this run's `dmx.import.run` label; only a reply with it is ours (Compose compares only its config-hash label) |
| A killed import left a half-copied volume or container that the next run called `exists` | Opus, Codex | `~/.dmx/import-journal.json` while copying; the next run reports entries of dead pids as incomplete; rollbacks that fail keep the entry |
| Stale-helper cleanup trusted a label: any container labelled `dmx.import.helper` with a dead pid could be force-removed | Codex (blocker) | Only helpers with this Mac's host id, never started, with the helper's entry point and mount |
| A pulled helper image stayed after an interrupted run; a source volume removed meanwhile was made again by the helper mount | Codex | Pulls are journalled and removed by the next run; the source volume is checked just before |
| A volume with an anonymous-looking name that another container mounts by name was not copied | Codex | Such volumes are selected like named ones |
| `--dry-run` still asked dmx's socket for digest-pinned images | both | Not when dmx is stopped |
| A cancelled MCP import went on creating things | Codex | Stops between items, cleans up, reports it |
| An event after the table was read could still route a name to an address another container took; rename was not followed | both | Events mark the table stale; connections wait for the next listing (up to 3 s, then 503); `rename` joins the events |
| The crash decision's flag could be cleared by a listing asked for before the event | Codex | Cleared only if no event came after that listing was asked for |
| `verify-apk.py`: extra files in the signature stream (packaged, unsigned) passed | Codex (blocker) | The first stream must hold the signature only; a crafted package fails; the 122 pins pass |
| A CA made before the IP exclusion was still used; resolver ownership across homes; remove cancelled midway lost track of the resolver | Codex, Opus | An old CA is refused; setup records whether it wrote the resolver; settings are restored if a dialog fails |
| Names stayed yielded after a `dmx port` forward was removed | Codex | Forwards that stop listening tell names to take the port back |
| DockerAPI: a negative Content-Length trapped; a chunked body ended without its last empty line; 204 with an open connection waited; a garbled list read as empty | both | Negative length ignored; trailers read to the empty line; 204/304 have no body; import's listings must be lists; hints on the remaining errors |
| bench's final cleanup by name; idle warning at 110 s; launchdtest could pass on an inherited variable, and two runs shared a label | Codex | Cleanup by a per-run label; threshold 110 s; launchdtest checks launchd's environment first and uses a label per run |

After the fixes: unit 171 and the agent's 8; namestest 37/37 (36/37 on `6cd79a5`: the new TLS
listener check), crashtest 40/40, daemontest 63/63, sandboxtest 44/44, mcptest 38/38, dockertest
81/81, importtest 29/29, launchdtest 10/10, selftest 23/23 at 96–97 MB; `verify-apk.py` on all
122 new pins.
