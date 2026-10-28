# FrameConnection descriptor lifetime

Baseline: `2ed2c21` (2026-10-29). Workflow: W1 bug hunt.

## Triage

1. Connection close versus queued/in-flight framing I/O: shared descriptor numbers can
   be reused by unrelated connections; affects agent, daemon and exec streams. Selected.
2. VM stop/start versus asynchronous memory-controller callbacks: old callbacks can
   outlive their attachment. Not modeled or classified as a finding in this investigation.
3. Virtio block request/flush ordering across concurrent workers: disk durability has
   high impact, but needs the guest's submission rules in scope. Deferred, not a finding.

## In scope

One FrameConnection, two concurrent frame operations, close/abort, and one unrelated
socket reusing the original descriptor number. Each operation performs two system calls
(representing header/body or a short transfer). Close can happen before or between them.

Protocol properties are frozen in `tla/Properties.tla` before checking:

- NoForeignIO: framing I/O must never access another connection's socket. Source:
  `Sources/DMXCore/Agent.swift:113-115` (one connection speaking one peer's protocol),
  `:155-161` (explicit protection against reused descriptor numbers).
- NoLateAcquire: after the connection closes, a new frame operation must not acquire
  a live descriptor. Source: `:130` (close releases the connection), `:146-161`
  (abort ends the connection; closed is irreversible).

Code-level checks: finite variable domains (`TypeOK`), reachable completion/reuse
(must-fail sanity invariants), nonzero action coverage, and the unfixed mutation.

## Abstractions and limits

Payloads, framing syntax, time, descriptor numbers, and kernel scheduling are abstracted.
A syscall returns data/error/EOF in one step; blocked-I/O liveness is **not proved**.
The fixed model treats descriptor duplication and the closed check as one locked action.
A private duplicate remains bound to its original open file description until released.
The model permits both finite transfer steps even if a real EOF/error would return earlier;
this overapproximates possible I/O for the safety check rather than proving error handling.
No fairness, symmetry reduction or state constraints are used.

Out of scope: raw `FrameConnection.fd` users (splice/relay and Docker HTTP), guest vsock
credit flow, VM destruction, process crashes, and malicious code externally closing an
owned descriptor. This is a focused code-path finding, not a demonstrated guest escape.

The real reproduction forces legal OS descriptor reuse with `dup2`; it does not assert
how frequently production scheduling hits the ordering. Before/after VM selftests measure
the process's `ri_phys_footprint`; no whole-program correctness claim is made.
