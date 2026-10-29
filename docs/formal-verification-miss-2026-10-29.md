# Why the first formal verification missed the review findings

The first investigation found and fixed a real wrong-socket I/O bug, but its green model
and three socket tests overstated their regression coverage. Opus 5.5 then found a newly
introduced RPC defect and model/test gaps. The parent reproduced those findings and a
shared-FD test hazard. This repair addresses R1–R5 of the
[validated historical review](review-2026-10-29-opus55.md).

## Causal gaps and repairs

| Finding | Why it escaped | Repair and falsifiable evidence |
|---|---|---|
| R1: a second dup can fail after sending, leaving the old reply queued | The frame model treated dup failure as safe rejection. That is true before one frame, but insufficient after a request has an external effect. Request/reply identity across calls was absent. | One lease covers the whole RPC, acquired before sending. Validate reply IDs and retire on uncertain transport/protocol errors. Reconnect only for future calls; never replay. The new two-call FIFO model reproduces the old failure. A real fcntl EMFILE child probe shows the failed call is unsent and the next reply belongs to its own request. |
| R2: removing the closed guard still passed | Sticky observations directly read `~LeaseFD`. With the fix enabled, observations could never report a violation. Frozen property text did not prevent its meaning being made tautological. One all-off mutation changed both implementation and oracle. | Model original name, acquired handle and captured copy binding separately. Compute wrong-target observations from that binding and late acquisition from acceptance after close. Independently remove guard, use raw binding, and release early. The original frozen properties reject all three without changing observations. |
| R3: removing shutdown still passed | The test shut the peer down before checking completion, supplying the wakeup that production close was supposed to cause. | Read and blocked-write assertions run before any peer teardown. Removing only shutdown now fails both assertions; rescue cleanup follows the recorded failures. |
| R4: descriptor reuse tests could replace an unrelated test's file | Suite serialization did not serialize other suites or runtime opens in the process-global FD namespace. `close -> other open -> dup2` was legal. | No destructive reuse in the unit suite. Dedicated children own all forced reused numbers. Gated syscall probes also run only in children. |
| R5: same archive hash but changed tag kept the old receipt | The receipt condition compared only archive hash, although tag/archive metadata is also part of the receipt contract. This was not represented in the FD model. | Compare the full receipt when boot files match. The original same-archive reproduction and an offline unit regression now observe the new tag without altering boot files. The official prior release pair had different archives and did not hit this edge. |

A blind forward evaluation of the improved skills also predicted that ordinary tests could
miss substituting `body(fd)` for `body(copy)`. This was independently confirmed: the eight
current FrameConnection tests pass that mutation. A new child interposes the **second poll**,
pauses exactly after the header and before the body, closes/reuses the original number,
then resumes. Correct Core leaves the unrelated body unread; the raw-binding mutant fails
`cannot splice a frame from two sockets`. This probe is part of the current check command,
so ordinary unit tests are not presented as sufficient by themselves.

The next review found two more concrete P3 paths. The parent reproduced both before fixing:
daemon application errors gained a duplicate method prefix, and an actual candidate daemon
whose reply dup failed left its client waiting. Daemon errors now preserve message/code/hint;
serving-side send retires on failure, preventing a next-request wait or an appended error
frame after partial output. The same child-only EMFILE experiment now observes EOF instead
of a timeout. This server-side defect was outside the original frame safety model; it is
not presented as a mathematically proved server implementation.

The final suite also asserts retirement for wrong frame kind, broken JSON and bad length,
so moving retirement into only the wrong-ID branch cannot silently pass those assertions.
Guard-harm, check/unlock/dup and replay-on-reconnect model mutations were added after review.

## What the new mathematics establishes

`formal/check.py` runs two separate finite safety models, with no fairness or state
constraints. FD: two operations, two transfers each, one close/original reuse; fixed model
290 generated / 134 distinct states, depth 13. RPC: two calls, one optional dup failure and
one optional unexpected response; fixed model 33 generated / 26 distinct states, depth 10.
Thirteen must-fail mutation/reachability checks accompany the two green checks. The original
FD Properties.tla hash is unchanged. RPC properties are frozen in a separate module.

The FD model's state count happens to match the old count; the observations and binding
semantics differ. A state count alone cannot show correspondence or mutation sensitivity.
Every expected failing run is required to report its named invariant; tool/parse errors do
not count as counterexamples. Enabled fixed actions have positive coverage. Source pointer
checks only resolve files/ranges; the semantic map remains manually reviewed.

These are bounded checks of explicit models, not unbounded Lean theorems, blocked-I/O
liveness, a proof of Swift refinement, OS correctness or whole-program correctness. Raw-FD
relay/Docker paths, transport flow control, arbitrary close/reconnect scheduling and crashes
remain outside the mathematical models. Their integration tests provide different evidence.
The missed two-call EMFILE bug was small enough to model; it escaped through abstraction and
an observation oracle, not merely because the state bound was small.

## A release-test failure was retained and investigated

The post-review daemon suite first passed 57/58; its critical-balloon test resampled 157 MiB
against an exclusive 157 MiB limit. It had waited for a joint balloon/footprint predicate,
then discarded that tuple and gated on another status response. Deterministic replay of the
actual original assertion block with synthetic successive footprints 156/157 demonstrates
a legal false rejection. The original run did not retain the accepted sample, so attributing
that exact failure to this race remains an inference, supported by the recorded trim age.
Five instrumented repetitions of the original isolated memory path all passed; they do not
distinguish the old/new assertion or reproduce the full preceding suite history.

The test now retains and reports the tuple that satisfies the same original balloon and
footprint limits within the same 15-second deadline. It does not claim sustained stability
or full balloon-target convergence. The scoped Opus review accepts that repair conditional
on a passing corrected full daemon/MCP run, and requires the evidence limits above. See
[original failure, diagnostic/replay and review](../formal/evidence/v0.3.12/memory-gate/README.md).
The application memory controller was not changed to make a test pass.

## Skills and evidence

Installed `formal-verify` and `tlaplus-model` now route to a focused sensitivity reference:
trace observations from semantic state, mutate independent defenses with unchanged oracles,
check new fallible operations across transaction boundaries, and prevent teardown/isolation
from invalidating the reproduction. Portable patches, final snapshots, schema validation and
blind Opus 5.5 evaluation are [preserved here](../formal/skill-improvements/README.md).

Current model logs and results: `formal/evidence/v0.3.12/`. Original evidence remains under
`formal/frame-connection-lifetime/evidence/`, including the original failing reproductions.
The EMFILE and gated-poll probes inject into an unsigned executable linked to actual debug
Core, not the signed hardened released executable; they do not exhaust the host FD table or
measure production incidence. Full release/published-binary validation is recorded separately.

Run the present guard from the root after `make test`:

```sh
python3 formal/check.py
python3 formal/frame-connection-lifetime/repro/check-code.py
python3 formal/frame-connection-lifetime/repro/check-shutdown-mutation.py --out .build/shutdown-mutation-new
python3 formal/frame-connection-lifetime/repro/check-binding-mutation.py --out .build/binding-mutation-new
```

Mutation output directories must be fresh so earlier evidence is preserved. The source
mutations use temporary packages; the checked-out Core and frozen properties stay unchanged.
