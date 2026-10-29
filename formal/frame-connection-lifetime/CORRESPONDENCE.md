# Model to code correspondence

Rebuilt after review of `7b094ab`. The original logs under `evidence/model-*` are historical;
current logs are under `formal/evidence/v0.3.12`. Correspondence is manual, not refinement.

| Model element | Current code | Meaning / abstraction |
|---|---|---|
| Submit | `Sources/DMXCore/Agent.swift:360-366` | Queue a read; exec input can independently write. Two finite actors overapproximate serialized reads. |
| Acquire; handle; copySlot | `Sources/DMXCore/Agent.swift:168-177` | Lock, reject closed, duplicate the current binding, unlock. Dup failure rejects; successful dup owns the same open-file description. |
| Transfer; calls; foreignIO | `Sources/DMXCore/Agent.swift:289-319` | Two syscalls stand for header/body or short transfers; target is the binding of the acquired handle. No fix selector appears in the observation. |
| Finish | `Sources/DMXCore/Agent.swift:176-177` | Defer releases the private copy after the last use. |
| Close; closed; slot | `Sources/DMXCore/Agent.swift:145-165` | Same lock guards closed state, shutdown and original-number release. Shutdown wakeup itself is not modeled. |
| Reuse | `formal/frame-connection-lifetime/repro/IsolatedFDProbe.swift:30-38` | OS reuses the released number; child-only dup2 forces it. |
| DropCopy; ReuseCopy | `Sources/DMXCore/Agent.swift:176-177` | Mutation only: release too early and let another open reuse the private number. |
| lateAcquire | `Sources/DMXCore/Agent.swift:168-175` | Observe an accepted acquisition after close, independent of variant selection. |
| Done; Terminated | Finite harness (no production statement) | Finite harness termination with both operations finished and close/reuse completed. |

Assumptions: NSLock exclusion, dup binding semantics, no external close of private copies.
Payload parsing, blocked I/O scheduling and failure recovery are abstracted. See SCOPE.md
and the separate RPC model before making any transaction-level claim.
