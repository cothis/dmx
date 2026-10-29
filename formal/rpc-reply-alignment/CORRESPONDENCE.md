# RPC model to code correspondence

| Action / state | Current source | Meaning / abstraction |
|---|---|---|
| Acquire; FailBeforeSend | `Sources/DMXCore/Agent.swift:168-177` | One lock-protected duplication; failure before the request is sent leaves the connection aligned. |
| Send; sent; replies | `Sources/DMXCore/Agent.swift:185-212` | Encode/write once. Model combines successful send with peer FIFO reply queueing; sent counts are observed events. |
| ReadAcquire; FailAfterSend | Historical split exchange in [review R1](../../docs/review-2026-10-29-opus55.md) | Old split per-frame lease can fail after sending. Disabled in whole-exchange variant. |
| PoisonReply | `Tests/DMXCoreTests/FrameConnectionTests.swift:128-141` | Environment supplies an unexpected ID; ID 3 was never sent. |
| Receive; delivered; uncertain | `Sources/DMXCore/Agent.swift:342-357` | Pop queued reply, compare its ID to current request; record only accepted results. |
| Retire (within Receive / FailAfterSend) | `Sources/DMXCore/Agent.swift:196-205` | Close on uncertain transport/protocol exchange, without replay. |
| NextCall | `Sources/DMXCore/Agent.swift:185-189` | Connection queue serializes request/reply exchanges. Model has exactly two calls. |
| Reconnect | `Sources/DMXCore/Agent.swift:412-462` | Fresh socket drops old queue; failed request is not replayed. Task scheduling/close races are tested, not proved here. |
| Done; Terminated | Finite harness (no production statement) | Finite two-call harness finishes. |

The model abstracts remote application errors as aligned completion. IDs and FIFO queues
are protocol-level semantics; no observation is directly gated by a fix selector. There
is no machine-checked Swift refinement, and resolving these line ranges alone cannot prove it.

Call/response IDs are logical exchange identities. After reconnect, production nextID starts
at 1 again; the model normalizes the fresh connection's IDs to the logical caller. Fresh
queue replacement is essential to that correspondence; global wire-ID uniqueness is not
assumed or claimed.
