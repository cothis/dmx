# Model to code correspondence

Baseline commit: `2ed2c21`. Current map: the fix delivered with this file, 2026-10-29.
The saved `model-before` log contains the original baseline's line tags; current model
tags and this table point to the fixed source. `LeaseFD = FALSE` models the baseline.

| Model element | Code | Kind | Abstraction |
|---|---|---|---|
| `Submit(o)` | `Sources/DMXCore/Agent.swift:327-330` `onQueue` | action | A read is queued; the exec feed can independently submit a write. |
| `Acquire(o)` | `Sources/DMXCore/Agent.swift:162-167` `withOpenFD` | action | The closed check and F_DUPFD_CLOEXEC are one closeLock critical section. Closed/failing acquisitions finish with an error. Baseline has no acquisition guard or duplicate. |
| `Transfer(o)` | `Sources/DMXCore/Agent.swift:254-283` `writeAll`, `readExactly` | action | A syscall is atomic with respect to which open file description it uses; two calls represent header/body or short I/O. With a lease, all calls use the private copy. Baseline re-reads the original fd number for each call. |
| `Finish(o)` | `Sources/DMXCore/Agent.swift:168-169` | action | A frame returns and defer closes its private duplicate. |
| `Close` | `Sources/DMXCore/Agent.swift:150-157` | action | The closed bit and release of the original number share closeLock with acquisition. Fixed close also shuts down the socket; wakeup latency is not modeled. Abort delegates to close. |
| `Reuse` | `Tests/DMXCoreTests/FrameConnectionTests.swift:23-36` | environment action | dup2 forces the same number to name another socket; normal opens can also reuse it. |
| `phase`, `calls` | `Sources/DMXCore/Agent.swift:240-303` | variables | Two frames, each with two system calls; no payload or parsing state. |
| `closed` | `Sources/DMXCore/Agent.swift:141-142` | variable | Boolean, guarded by closeLock. |
| `slot` | `Sources/DMXCore/Agent.swift:125` | variable | OS descriptor-table binding of the original integer: original/free/foreign. |
| `foreignIO`, `lateAcquire` | `Tests/DMXCoreTests/FrameConnectionTests.swift:39-64` | ghost variables | Sticky observation flags for wrong-socket I/O and an operation starting after close. |
| `Done`, `Terminated` | `Sources/DMXCore/Agent.swift:168-169` | abstraction | Both finite operations finished and the environment completed close/reuse; explicit terminal stuttering. |

## Assumptions and granularity

- A1: Swift NSLock makes close versus duplicate acquisition mutually exclusive.
- A2: F_DUPFD_CLOEXEC creates a distinct, owned descriptor referencing the same socket;
  reusing the original descriptor number does not change the duplicate's target.
- A3: Only the frame's defer closes its private copy. External code does not close it.
- A4: The model abstracts each system call as returning; it proves no blocked-I/O liveness.
  Close's shutdown/wakeup behavior is covered by the real socket regression and VM suites.
- A5: Duplication failures are equivalent to a rejected operation for these safety
  properties. Omitting that extra rejection branch cannot hide a wrong-socket access.

Acquire and Close are lock-critical sections; Transfer is one syscall. No interleaving
between separate syscalls is merged. Concurrent reads are serialized in production;
allowing both finite actors to transfer in the model overapproximates that serialization.
Code-level correspondence is reviewed, not a machine-checked Swift refinement proof.
