# Focused formal verification

The original close/FD bug was fixed in v0.3.11. An independent Opus 5.5 review found a new
RPC alignment defect and verification blind spots. The v0.3.12 repair uses semantic binding
observations, independent mutations and isolated real-syscall probes. See
[why the first check missed them](../docs/formal-verification-miss-2026-10-29.md).
This is scoped bounded safety evidence, not whole-program or unbounded proof.

Run from the root:

```sh
make formaltest
```

This runs the ordinary unit suite, both current models and dedicated child probes against
**freshly built** debug DMXCore. The probe runner also builds Core when invoked directly,
so a stale object is not silently accepted. It injects EMFILE into real fcntl and gates poll
at the header/body boundary; no destructive FD reuse occurs in the unit process. The signed
release executable is checked separately by the actual VM/MCP/release suites.

`formal/check.py` needs Java 11+ and local `tla2tools.jar` at `$TLA2TOOLS` or
`~/.cache/proof-skills/tla2tools.jar`. It performs no downloads. Current logs/results and
input hashes are under `formal/evidence/v0.3.12/`; original logs under
`frame-connection-lifetime/evidence/` remain historical. Input hashes establish which model
and source files a log accompanies, not semantic refinement.

- FD model: 2 operations, 2 transfers each, one close/original reuse. MC passes;
  MC_bug, MC_early and MC_guard_harm violate NoForeignIO; MC_guard violates NoLateAcquire;
  MC_atomic violates NoForeignIO for check/unlock/dup; completion/reuse sanity checks fail.
- RPC model: 2 calls, one dup failure, one malformed response, fresh recovery. MC passes;
  MC_old and MC_id violate NoMismatchedReply; MC_retire violates NoUncertainReuse;
  MC_replay violates NoReplay; completion/failure sanity checks fail.

No fairness or state constraints. Fixed-enabled actions have positive coverage. Each
expected failure must be its named invariant, not a parse/tool error. The original frozen
FD properties are unchanged; the new RPC module is separately frozen before checking.
A hash committed beside a property detects accidental changes; independent review and
immutable Git history are needed to audit changes to both property and hash together.

Additional source mutation checks (use fresh output directories):

```sh
python3 formal/frame-connection-lifetime/repro/check-shutdown-mutation.py --out .build/shutdown-new
python3 formal/frame-connection-lifetime/repro/check-binding-mutation.py --out .build/binding-new
```

They copy Core into temporary packages and remove one mechanism at a time. Missing shutdown
must fail both direct wakeup tests; using self.fd instead of the acquired binding must fail
the safe binding unit test and the gated child probe. They never edit the checkout.

Scopes and manual correspondence:
[FD scope](frame-connection-lifetime/SCOPE.md), [FD map](frame-connection-lifetime/CORRESPONDENCE.md),
[RPC scope](rpc-reply-alignment/SCOPE.md), [RPC map](rpc-reply-alignment/CORRESPONDENCE.md).
The [report](reports/frame-connection-lifetime.html), [results](findings.json),
[historical review](../docs/review-2026-10-29-opus55.md) and
[skill improvements](skill-improvements/README.md) preserve their evidence boundaries.
Checks remain local, per the repository's decision against GitHub CI.
