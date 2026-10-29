# Model and reproduction sensitivity

Use this when a passing model/test is offered as evidence for a code fix. A green run,
a must-fail reachability invariant, and an all-off bug toggle answer different questions.
They do not establish that each independent defense is protected.

## Observe semantics, then select implementations

Derive property observations from accepted operations and concrete modeled state/events.
For a resource handle, distinguish the reusable name from the object it currently names,
the acquired binding, and ownership through the last use. For messages, retain the request
identity through queueing, delivery and recovery.

Audit the backward dependency of each observation. An assignment such as
`foreignIO' = foreignIO \/ (~FixEnabled /\ reused)` makes the green result true by
construction even if the guard or lifetime is wrong. A selector may change an acquisition
or release action; the syscall's target observation should still use the same binding rule.
Freezing `Properties.tla` alone does not freeze its meaning if ghost updates are rewritten.

## Independent mutations

Remove a guard, bypass acquisition, shorten ownership, or reorder a commit/release step
individually, as relevant to the mechanism. Keep the properties and observation rules fixed.
Record the specific violated property and trace. If a mutation passes, explain whether
another defense makes it safe or the model cannot observe it; do not claim sensitivity.
Use code mutations as well when a concrete regression assertion is relied upon.

A correspondence line-range checker checks locations, not semantic refinement. Review the
binding, error and recovery behavior separately; report that mapping as manual unless proved.

## New fallible work across the transaction

For each fallible operation introduced by a fix (dup, allocation, lock acquisition, I/O),
consider failure before and after the first externally visible effect. Model what remains
queued, committed or owned and what the next operation observes. A safe pre-send failure
does not establish safety for failure after sending. Check correlation, retirement/reconnect,
and absence of automatic replay when the original side effect may already have happened.

Keep the claim scoped: bounded safety checking is not a liveness proof or whole-program proof.

## Do not let the harness prove the assertion

Assert wakeup/progress before teardown closes a peer, releases a barrier, cancels a task or
otherwise supplies the event the production code should cause. Only rescue a failed run
after recording the assertion. Remove the production wakeup and confirm that assertion fails.

Tests that deliberately close and reuse process-global names (for example, `dup2` over a
retired FD) belong in a dedicated child process with explicit ownership. A per-suite lock
does not serialize other suites or runtime threads sharing that namespace. Preserve the
isolation in the ordinary test runner, not just a one-off invocation with parallelism off.
