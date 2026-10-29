# Storage/log hardening review and qualification

Actual `claude-opus-5-5` performed three read-only reviews. Initial review requested F1/F2
repairs; second requested R1/R2; the third approved and required the final real-VM checks.
Those source/pin checks passed. [v0.4.1 is published](https://github.com/cothis/dmx/releases/tag/v0.4.1)
from `241aaaecad481276bf7e4342888e8c070450fd7e`, signed/notarized and locally installed.
Both Apple submissions were accepted, the app is stapled, all14 public bytes match the
independent qualified files, and public end-to-end checks pass19/19.

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

## Distribution and installed result

[Publication](publication.json), [final signing/package verification](signed-package-verification.json),
[independent asset hashes](qualified-assets.json), [public checks](public-verification.json),
[public storage64](public-storage.json), and [local installation](local-install-verification.json)
preserve the completed proof. The published app update from0.4.0 keeps the live VM, running
container and named volume; after engine restart, the data disk inode and volume contents persist.
The old unlimited container options remain unchanged and a newly created container gets10m×2.
Fresh public selftest23 and arm64/amd64/386 pass. The final signed app's local install/update
fixture also passes14/14 plus the typed rollback test.

The canonical local app/CLI and guest are0.4.1, Developer ID/Gatekeeper checks pass, and every
boot file matches the pin. `data.img` inode,64GiB logical size and451.5547MiB allocation are unchanged;
no user VM was started. Guest prefetch updated the old0.3.12 release receipt/boot assets without
running it. [Post-verification cleanup](post-verification-cleanup.json) removed downloaded/current
dist duplicates, the old baseline guest/home and accidental root Cargo output. `.build` is now
1.618GiB versus5.437GiB at the resumed preflight; retained qualified reference files are original
pre-upload bytes. APFS block sums are not isolated physical-space savings.

The package verifier initially rejected ordinary tar directory records in its manual extraction
probe. It now admits only regular files and directories under the allowlisted app layout and
still refuses links, special files and unsafe paths. The actual signed archive roundtrip passes.
[Its retained driver](verify-signed-package.py) uses the preserved qualified reference directory.
No product/archive format fix was needed. No hosted workflow was used for this release.

To repeat the public run using the retained independent reference and tagged runtime sources:

```sh
gh release download v0.4.1 --repo cothis/dmx --dir .build/storage-review/public-v0.4.1
python3 -I docs/reviews/2026-10-30-storage-opus55/public-verification/verify.py
```

The public download directory was removed after successful checks; the independent original
reference remains. Re-download before repeating this driver. Tests create isolated engines,
and clean their temporary installations/data; the canonical user engine is not started.
