**Verdict: the claim doesn't hold.** The code fix looks plausible: a closed check and an owned duplicate descriptor under `closeLock` (`candidate/Sources/DMXCore/Agent.swift:162-169`), plus `shutdown` on close (`:156`). But neither the model nor the tests show that this fix is what makes them pass, so they aren't ready to act as a regression guard.

## Findings

**1. The model passes because of how it records violations, not because of the fix.**
- The two violation flags are only ever set when `~LeaseFD` is true: `foreignIO' = foreignIO \/ (~LeaseFD /\ slot = "foreign")` (`candidate/formal/frame-connection-lifetime/tla/Spec.tla:33`) and `lateAcquire' = lateAcquire \/ (closed /\ ~LeaseFD)` (`Spec.tla:25`). With `LeaseFD = TRUE` (`MC.cfg:3`), `NoForeignIO` and `NoLateAcquire` hold no matter what the operations do.
- The model has no record of which socket each operation is actually using, so the owned copy never appears in it. The failing trace in `evidence/mutation/tlc.log:36-66` (Acquire → Close → Reuse → Transfer) can also happen in the fixed model. It isn't flagged only because the selector hides it.
- This is the exact anti-pattern in `skills/formal-verify/references/model-sensitivity.md:14-18`. Freezing `Properties.tla` doesn't freeze what the properties mean, because the flag updates live in `Spec.tla`.

**2. The mutation evidence is one all-off switch.**
- `LeaseFD` turns the closed check (`Spec.tla:24`) and the observation (`Spec.tla:33`) on or off together. Nobody tried removing just one defense: closed check without the copy, copy without the closed check, shorter ownership, or no `shutdown`.
- `MC_bug.cfg:5` leaves out `NoLateAcquire`, so that property is never shown to fail.
- There is no sanity config or log for `NeverCompletes`/`NeverReuses`. The coverage numbers do show Close, Reuse and Done are reachable (`model-after/tlc.log:68-86`).
- Bounds: 2 operations, ≤2 transfers each, one close, one reuse; 134 distinct states, depth 13. Safety only.

**3. Test 3 lets the test itself supply the wakeup it then checks for.**
- `FrameConnectionTests.swift:101` calls `shutdown(original[1], SHUT_RDWR)` before the "close must finish the pending read" assertion at `:107`.
- If the production `Darwin.shutdown` (`Agent.swift:156`) were deleted, the reader's copy would keep the socket open. The test's own shutdown would still end the read with EOF, so the test would likely still pass. This is the case warned about in `model-sensitivity.md:41-45`.

**4. The tests probably don't protect the duplicate descriptor (my prediction, not yet run).**
- Tests 1 and 2 (`:39-65`) close the connection and only then do I/O, one step after the other. They exercise the `closed` flag only, which the comment at `Agent.swift:161` itself calls insufficient.
- In test 3 the reader is already blocked inside the body `read` when `close()` runs. Production `shutdown` wakes it before `dup2` (`:97`) reuses the number. So with `body(fd)` instead of a copy, the test would most likely still pass. Only a microsecond window between the two reads can reach the reused number, and nothing in the test holds the reader there.

**5. The tests reuse descriptor numbers unsafely in a shared process.**
- Each test closes a descriptor and then `dup2`s over the same number (`:27`→`:35`, `:96`→`:97`). `@Suite(.serialized)` (`:6`) only orders tests within this suite. Other suites and Dispatch threads can grab the freed number in between, and `dup2` would then silently replace their descriptor.
- If `dup2` fails, the `#expect` doesn't stop the test, and the deferred `Darwin.close(fd)` (`:30`, `:74`) closes a number that may now belong to someone else.
- Per `model-sensitivity.md:47-50`, these tests belong in a dedicated child process.

**6. Suspected, not reproduced: the fix adds a new way to fail after a request is sent.**
- `reply()` writes the request, then `readReply` calls `withOpenFD` again (`Agent.swift:181-182`). If `fcntl(F_DUPFD_CLOEXEC)` fails at that point (for example, the process is out of descriptors), it throws `_disconnected` but leaves the connection open (`:164-167`).
- `AgentClient.call` only replaces the connection on timeout (`:374-375`). `Envelope` has no request id (`:581-585`), so the next call could read the previous call's reply.
- The model doesn't include `fcntl` failure or `shutdown` at all.

**7. Other evidence gaps.**
- No test-run logs, before or after the fix, and no correspondence map.
- The TLC logs parse `/Users/cothis/dev/dockermax/formal/...` (`tlc.log:3`), not `candidate/`. The coverage line/column positions match `candidate/` `Spec.tla`, but I can't prove the files are identical.
- The `Acquire` source tag says "baseline: no close check or owned duplicate" (`Spec.tla:21`), but it points at the fixed code.

## Smallest useful next experiment
Try three one-line code mutations against the existing `FrameConnectionTests`, each in its own fresh process, and save the logs:
- **M1:** remove the `closed ?` check in `withOpenFD`. I predict tests 1 and 2 fail.
- **M2:** call `body(fd)` instead of using the copy. I predict all three tests pass.
- **M3:** delete `Darwin.shutdown`. I predict all three tests pass, because of finding 3.

If M2 and M3 pass, that settles it: the tests don't guard the fix.

After that:
- Move the descriptor-reuse tests into a child process.
- Assert the read finished before any test-side shutdown, and add a hook to pause the reader between header and body.
- Make the model track each operation's socket and compute the violation flags from that, with separate switches per defense.
- Write a lowered-`RLIMIT_NOFILE` child probe for finding 6.

## Limits
I only read the files under `candidate/` and `skills/`, and ran nothing. The predictions in findings 3, 4 and 6 come from my reasoning about Darwin `shutdown`/`close`/`dup` behavior and haven't been checked. Finding 6 is a suspected issue, not a confirmed bug. I can't confirm the TLC logs came from these exact files. A passing TLC run only means no counterexample within those bounds, not that the code is correct.