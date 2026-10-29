---
name: tlaplus-model
description: Model and check real code or protocols with TLA+/TLC, PlusCal, Quint or Apalache. Use for .tla/.cfg files, checker output and counterexample traces; bounded exploration of concurrent code, queues, caches, leases, retries, state machines and DAG schedulers; safety, liveness, fairness, state explosion and trace validation. Classify traces as real bugs, model artifacts or overly strong properties. Pair with formal-verify for reproduction and fixes. Not for race detectors, Jepsen, Alloy, Lean/Coq proofs or UI state-machine libraries.
---

# tlaplus-model

<!-- Source: opum-ai/proof-skills v0.1.1, commit 578749fd8baa6456d89d7a0037c88bc09a89213d. Local Codex compatibility adjustments. -->

TLA+ describes a system as **state** plus **actions** (atomic steps). TLC explores every
interleaving of those actions from every initial state, within the bounds you give it, and
returns the *shortest* trace that breaks a property. That exhaustive search is what finds
races no test would hit. The skill's job is to make the model faithful, small, and able to fail.

When the task is a full bug hunt, follow `formal-verify` for the outer loop: scope, properties,
correspondence map, reproduction, fix, and report. This skill covers the modeling and checking inside it.

## Setup

```bash
S=${HOME}/.agents/skills/tlaplus-model/scripts
$S/setup_tla.sh --with-jre        # tla2tools.jar + CommunityModules (+ portable JRE if no Java)
$S/tlc.sh Spec.tla --sany-only    # parse/level-check: the fast inner loop
$S/tlc.sh Spec.tla --config MC.cfg        # model check; writes .tlc-out/MC/{tlc.log,cex.json,trace.md}
$S/tlc.sh Spec.tla --config MC.cfg -- -simulate num=200000 -depth 60   # random walks for big models
```

`tlc.sh` runs SANY, then TLC with `-workers auto`, and saves the JSON counterexample. It also
prints a step table (action, code pointer, changed variables) produced by `parse_tlc_trace.py`.
It exits with TLC's code: 0 ok, 11 deadlock, 12 invariant, 13 temporal/action property,
10 ASSUME/POSTCONDITION false, 150 parse error. Full CLI notes: `references/tlc-cli.md`.

## The modeling loop

1. **Start from a pattern.** `assets/patterns/` has seven small, runnable, checked specs.
   Each has a fix toggle and three configs (`MC.cfg` passes, `MC_bug.cfg` fails, and
   `MC_sanity.cfg` fails on purpose). Copy the closest one, then read `references/patterns.md`.

   | Code shape | Pattern |
   |---|---|
   | read-modify-write, counters, check-then-act, locks | `LostUpdate` |
   | async/await, cache-aside, fill vs. invalidate | `CacheAside` (+ trace validation harness) |
   | retries, webhooks, at-least-once delivery, dedup tables | `IdempotentRetry` |
   | leases, job claiming, leader leases, GC pauses, fencing tokens | `JobLease` |
   | streams, queues, batching, backpressure, end-of-stream | `BatchPipeline` |
   | DAG executors, build systems, workflow engines, graph invariants | `DagScheduler` |
   | persisted status fields, order/payment/ticket lifecycles | `OrderStateMachine` |

2. **Pick the atomicity.** One action is one atomic region of the real code:
   - the code between two `await`s,
   - a locked section,
   - a single shared read or write,
   - a single SQL statement, or
   - one message handler.

   Merging regions the code runs separately hides exactly the race you want. Put
   `\* src: path:lines` above each action. `formal-verify` uses these tags for its
   correspondence map, drift checks, and trace tables.
3. **Model only what the properties need.** Collections become sets or functions, and
   payloads become small ranges. Keep 2 actors and 2–3 values at first. Time becomes an
   `Expire`/`Timeout` action rather than a clock. The environment (network drop, crash, pause)
   becomes explicit actions, so their interleavings are explored too.
4. **Write properties before running.**
   - **Invariants** hold in every state.
   - **Action properties** constrain every step, e.g. `[][status' # status => <<status, status'>> \in Allowed]_vars`.
   - **Liveness** (`<>`, `~>`) needs fairness (see step 6).

   Guard "coherence" invariants with a quiescence predicate when mid-flight staleness is legitimate.
5. **Prove the model can fail.** Before trusting a green run:
   - (a) a **sanity invariant** that must be violated (for example, "the done state is never
     reached"), which shows the interesting states are reachable;
   - (b) the **bug toggle**: turn the fix off and confirm the target property fails;
   - (c) `-coverage 1` shows no action that is never enabled.

   Keep observations independent of implementation selectors, and mutate independent
   guards, ownership lifetimes and error recovery separately. Read
   `~/.agents/skills/formal-verify/references/model-sensitivity.md` for fix validation;
   an all-off toggle can hide a missing guard even with frozen properties.
   A spec that has never failed is not evidence.
6. **Add fairness honestly.** Liveness needs `WF_vars(A)` or `SF_vars(A)` on the actions the
   real system guarantees will eventually run (a scheduler runs ready work, a consumer keeps
   polling). Never put fairness on environment faults, and never add it only to make a
   property pass. Keep liveness and symmetry in separate configs: symmetry reduction is unsound
   for liveness.
7. **Read the counterexample.** Use `trace.md`, then tell the story in domain terms. Decide
   between a real bug, a model artifact (a missing guard, or steps merged or split wrongly),
   and a property that is too strong. Hand real bugs back to `formal-verify` for reproduction.
8. **Scale carefully.** Grow one bound at a time. If the state space explodes:
   - add a `SYMMETRY` set (safety only),
   - add a `VIEW` to drop auxiliary variables,
   - add a `CONSTRAINT` (and report it),
   - switch to `-simulate`,
   - use Apalache for bounded symbolic checks (`references/apalache-quint.md`).

## Hard-won rules

- `None == -1` needs `EXTENDS Integers`; Naturals has no unary minus. Mixing strings, model
  values, and integers in comparisons is legal only for model values; otherwise use one type per variable.
- `IF … THEN … ELSE …` swallows every conjunct after it. Parenthesize: `x' = (IF c THEN a ELSE b)`.
- Every action must mention every variable (primed, or in `UNCHANGED`). A missing one means
  "any value", which gives states that make no sense. `TypeOK` catches it.
- A terminating system deadlocks by design. Add an explicit `Terminated == Done /\ UNCHANGED vars`
  disjunct rather than disabling deadlock checking; `-deadlock` hides real stuck states.
- Only the agent's *own* modeling choices may change freely. Frozen properties (`Properties.tla`),
  `CONSTRAINT`s, and fairness changes are reported in the findings, never quietly edited.

## Beyond checking a model

- **Trace validation** (strongest drift defense): log events from the real system as ndjson
  and replay them through the spec. `assets/patterns/CacheAside/TraceCacheAside.tla` is a
  working harness (`trace-ok.ndjson` is accepted; `trace-drift.ndjson` is rejected with
  exit 10). See `references/trace-validation.md`.
- **Model-based testing:** generate traces from the model and drive the real code with them
  (`quint run --mbt`, or TLC `-simulate` with `-dumpTrace json`).
- **Refinement:** show a detailed spec implements a simple one (`INSTANCE … WITH`, checked as
  a PROPERTY). `proof-simplify` uses refinement to show a simpler design keeps the guarantees.

## Reference files

- `references/patterns.md` — the seven patterns: the bug each one finds, the fix, and how to adapt it.
- `references/tlc-cli.md` — TLC/SANY/PlusCal flags, `.cfg` keywords, exit codes, performance.
- `references/pitfalls.md` — vacuity, over- and under-modeling, liveness traps, agent reward hacking.
- `references/trace-validation.md` — logging events from code and replaying them in TLC.
- `references/apalache-quint.md` — when and how to use Apalache and Quint instead of TLC.
