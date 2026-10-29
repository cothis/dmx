# Focused formal verification

`frame-connection-lifetime/` models close versus framed socket I/O. It found one confirmed
wrong-socket I/O bug in `2ed2c21`; the fix, three real-socket regressions, bounded TLA+ model
and saved before/after evidence accompany this report. This is not whole-program verification.

**Post-release Opus 5.5 review:** the original model misses removal of the closed guard,
and the three socket tests still pass without close's shutdown. A separate RPC-alignment
defect under a frame-lease `EMFILE` was also reproduced. Interpret the historical green
checks with these limits. See [the validated review](../docs/review-2026-10-29-opus55.md),
[evidence](frame-connection-lifetime/evidence/opus55/metadata.json), and
[review reproduction commands](frame-connection-lifetime/repro/opus55/README.md).

Run from the repository root:

```sh
python3 formal/frame-connection-lifetime/check.py
swift test --filter FrameConnectionTests
env -u DMX_HOME make build
env -u DMX_HOME make guest
env -u DMX_HOME make selftest
env -u DMX_HOME make test
env -u DMX_HOME make daemontest
env -u DMX_HOME make mcptest
```

The model runner requires Java 11+ and a locally installed TLA+ tools jar. Set `TLA2TOOLS`
to its path, or put it in `~/.cache/proof-skills/tla2tools.jar`. Obtain tools from the
[official TLA+ tools repository](https://github.com/tlaplus/tlaplus/releases).
The check performs no downloads and writes logs under the concern's `evidence/` directory.
The jar version and sha256 used here are recorded in `evidence/toolchain.log`.

`MC.cfg` must pass. `MC_bug.cfg` must fail on NoForeignIO; `MC_sanity.cfg` must fail on
NeverCompletes; `MC_reuse.cfg` must fail on NeverReuses. The Python runner checks these
exact outcomes and positive action coverage. No fairness or state constraints are used.

See [scope](frame-connection-lifetime/SCOPE.md),
[code correspondence](frame-connection-lifetime/CORRESPONDENCE.md),
[machine-readable results](findings.json), and the self-contained
[report](reports/frame-connection-lifetime.html). Checks remain local, in accordance with
the repository's decision against GitHub CI.
