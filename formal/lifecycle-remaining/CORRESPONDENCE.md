# Credit model correspondence

| Model action | Real code | Abstraction |
|---|---|---|
| Send | FrameConnection.writeStdin credit wait/subtract; InputQueue.push | Socket transit and byte append are one atomic transition; frame sizes 1..2 stand for 1..32768 |
| Take | InputQueue.take | Model takes one original frame; real code coalesces up to 32768 bytes, reducing frame-count overhead |
| Write | stdin writer write_all then stdin_credit; FrameConnection.nextEvent grants credit | Child write and returned credit are combined; no liveness claim for a blocked write |
| Terminated | Idle environment / finished bounded input | Stuttering permits no further external work; no fairness assumption |

Properties are frozen in tla/Properties.tla. The queue-full observation is computed from actual
queued byte or frame counts, independently of the chosen mutation. Fixed capacity rejects when
queued bytes plus the new payload exceed the byte window. The host-credit mutant removes the
send guard; the frame-capacity mutant replaces byte admission with the development three-slot
admission check. Neither mutation changes the property. Model results are bounded safety only.

Other repairs are exercised through real-code failure injection or isolated guest/device tests;
they are not represented by this credit model. See README.md and the measurement record.
