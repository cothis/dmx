# FrameConnection descriptor lifetime

Original finding baseline: `2ed2c21`. Review-gap baseline: `7b094ab` (v0.3.11).
Current model was rebuilt after the independent Opus 5.5 review, 2026-10-29.

One connection, two finite operations with two syscalls each, one close and original-number
reuse. The descriptor table (`slot`), acquired handle (`handle`) and private copy binding
(`copySlot`) are distinct. A duplicate captures the current open-file description under
`closeLock`. Transfer observes its actual binding. Observations do not read fix selectors.

The original protocol properties in `tla/Properties.tla` remain byte-for-byte frozen:

- `NoForeignIO`: an operation never accesses an unrelated socket.
- `NoLateAcquire`: a closed connection never accepts a new operation on a live descriptor.

Independent mutations remove the closed guard, bypass the private duplicate, and release
the duplicate before the final use, and move duplication outside the close lock. A separate
guard-harm check requires NoForeignIO even without the earlier NoLateAcquire alarm. All must fail the frozen properties with unchanged
observation logic. Completion and descriptor reuse must also be reachable. Fixed-enabled
actions have positive coverage; early release and copy reuse are intentionally disabled in
the fixed variant. No fairness, symmetry or state constraints are used.

Syscalls return in one step; error/EOF may end real operations earlier. This is bounded
safety checking, **not** blocked-I/O liveness or a Swift refinement proof. Shutdown wakeup
is tested separately in real sockets, before peer teardown, including a source mutation
removing only shutdown. Destructive `dup2` probes execute only in dedicated children.

The FD identity model abstracts duplication failure as rejection. That abstraction cannot
justify request/reply safety after transmission; the separate
[RPC model](../rpc-reply-alignment/SCOPE.md) explicitly includes duplication failures and
queued reply identity across calls. The earlier blanket assumption of safe rejection was
insufficient for the RPC transaction and was withdrawn.

Out of scope: raw `FrameConnection.fd` consumers (splice/relay, Docker HTTP), vsock credit
flow, VM destruction, external closes of an owned private descriptor, process crashes,
OS implementation correctness, unbounded inputs, production failure frequency. Current
proofs assume lock mutual exclusion and Darwin's dup/open-file-description semantics.
