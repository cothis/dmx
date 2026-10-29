# RPC reply alignment

Review baseline `7b094ab`; runtime defect reproduced on v0.3.11's actual AgentClient/Core.
Two sequential calls, one optional dup failure, one optional malformed response (unsent ID 3),
finite queued responses and fresh-connection recovery. No retries, fairness or constraints.

Frozen properties (hash in properties.sha256): returned reply ID belongs to its call;
no call is sent more than once; no next acquisition reuses a connection whose alignment
became uncertain. The latter is a recovery contract implemented by retiring the socket.
Request/response identity is observed from queue contents, not an implementation toggle.

The fixed implementation acquires once before transmission and holds that copy across both
frames. Failed initial acquisition sends nothing. RPC I/O/envelope/ID errors retire the
socket; AgentClient may open a fresh connection for later calls but never replays the failed
request. Aligned application errors leave it reusable. Application payload decode failure
after a correlated envelope is not uncertain framing and is not modeled as retirement.

MC_old recreates split leases, no retirement and no correlation with an honest peer: a
post-send duplication failure leaves reply 1 queued; call 2 receives it. MC_id removes only
ID validation, and MC_retire removes only retirement. MC_replay resends the previous request on reconnect and
is rejected by NoReplay (sent counters allow 0..2 so TypeOK cannot mask the violation). The fixed model passes all properties;
those independent mutations fail. Completion and initial acquisition failure are reachable.

Bounds/limits: at most two sends, one acquisition fault, one malformed response. Send and
peer reply queueing are combined; separate delivery delay cannot change this FIFO safety
counterexample, but transport flow control, timeouts, blocked-I/O liveness, reconnect task
races, explicit close and arbitrary Swift scheduling are not proved. Real socket tests
cover ID rejection, application errors, next-call reconnect, explicit close, and an actual
fcntl EMFILE injected only into a child executable. Model/code correspondence is manual.
This does not establish OS correctness, production incidence or whole-program correctness.
