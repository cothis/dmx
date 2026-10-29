# Storage/log hardening review and qualification

Actual `claude-opus-5-5` performed three read-only reviews. Initial review requested F1/F2
repairs; second requested R1/R2; the third approved and required the final real-VM checks.
Those source/pin checks passed. Signing/notarization/publication remain pending in this commit.

- [Original findings](initial-opus55.md), [second review](second-opus55.md), [approval](third-opus55.md).
- [Model and immutable snapshot identity](review-identity.json), [reviewed source match](reviewed-source.json).
- Historical snapshots can be reconstructed from base `15b077c` and `initial.diff`/`second.diff`;
  `third.diff` applies to the second snapshot. Use a temporary archive directory for reconstruction.
- [Final qualification](final-qualification.json), [full measurements](../../measurements/2026-10-30-storage.json).
  Compatibility records precede final fallback/lock-wait additions; final Core/VM/menu/app/storage
  checks cover the reviewed runtime sources and final guest pin. The normal Docker/emulator payload
  is unchanged. Existing frozen formal results are scoped FD/RPC checks, not a proof of logging.

F1 was independently reproduced with a failed startup descendant retaining stderr; retry failed
with EWOULDBLOCK. Child-owned cancellation now wakes a blocking poll and drains a finite snapshot
of queued bytes before releasing the log lock. A bounded1s flock retry covers normal reaper handoff.
F2 now disables unusable sinks, drains output with fixed memory and keeps engine startup usable.
Host status exposes warnings; disabled sinks retry at the next boot in the same daemon.

`final-storage.json` includes64 checks: old oversized host/guest logs,8MiB console/dockerd floods,
30MB container stdout, valid default/explicit/persisted options, real dockerd crash restart,
legacy stdio descriptors, unsafe/unwritable log startup, target preservation, same-daemon recovery,
and four Rust tests executed in Linux (rotation, retry, deadline contention, inherited stderr).
The final host selftest is23/23, daemon58/58, MCP33/33, menu25/25+typedVM1 and app14/14+typed1;
unit runner97. Earlier x86/Docker/sandbox/images/Java matrix passes53/69/44/24/100.

Retained initial failures and diagnoses:

- `initial-storage-test.*` + `console-failure-diagnosis.json`: LF-only assertion versus measured
  `opost onlcr` and exact `CONSOLE-TAIL\r\n`. The initial review snapshot already had this fix.
- `second-storage-test.*`: the isolated home had no launchd; Docker alone cannot respawn dmx
  after daemon exit. The test now starts the engine explicitly before checking retained options.
- `initial-menu-failure.txt` + `menu-fixture-diagnosis.json`: source test home lacked bin and
  cli-plugins, producing dangling fixture links. Linked the pinned read-only tool cache; final
  menu and app checks pass. This was not a product permission failure.
- `inherited-pipe-before.json`: a product candidate bug; covered by the permanent retry tests.

[Cleanup record](cleanup.json) sums deleted-path allocated blocks; APFS shared extents and other
activity prevent equating it with an isolated physical free-space delta. User VM data, installed
app/CLI and pinned build inputs were preserved. Paired idle samples and interpretation are in
`memory-comparison.json`; Docker guest cache differed by6MiB, so the5.11MiB host difference is
not established fixed logging overhead. No host memory pressure stress was run.

Known diagnostic limitation: guest-agent restart or a surviving descendant's old pipe can stop
that diagnostic stream until VM restart. Container logs remain independent. Existing containers
keep creation-time log policy. Direct Phase12 GUI click acceptance is separate from this work.

The [public verification driver](public-verification/verify.py) checks all14 downloads against
independent qualified local bytes, fresh installation and actual published storage fixes,
arm64/amd64/386, and an update from the previous public app with VM/container/volume and old
logging-policy preservation. Keep `.build/storage-review/qualified-v0.4.1` from final signing;
never construct that reference from the public download being checked. Run from the repo root.
