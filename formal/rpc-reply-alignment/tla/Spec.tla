------------------------------- MODULE Spec -------------------------------
EXTENDS Naturals, Sequences, Properties
CONSTANTS WholeLease, Correlate, Retire, AllowPoison, Replay
VARIABLES call, phase, replies, live, uncertain, failedDup, poisoned
vars == <<call, phase, replies, live, uncertain, failedDup, poisoned, delivered, sent, badReuse>>
Init == /\ call = 1 /\ phase = "acquire" /\ replies = <<>> /\ live = TRUE
        /\ uncertain = FALSE /\ failedDup = FALSE /\ poisoned = FALSE
        /\ delivered = [c \in 1..2 |-> 0] /\ sent = [c \in 1..2 |-> 0] /\ badReuse = FALSE
\* src: Sources/DMXCore/Agent.swift:168-177
Acquire == /\ phase = "acquire" /\ live
           /\ phase' = "send" /\ badReuse' = (badReuse \/ uncertain)
           /\ UNCHANGED <<call, replies, live, uncertain, failedDup, poisoned, delivered, sent>>
\* src: Sources/DMXCore/Agent.swift:168-175
FailBeforeSend == /\ phase = "acquire" /\ live /\ ~failedDup
                  /\ failedDup' = TRUE /\ phase' = "finish"
                  /\ UNCHANGED <<call, replies, live, uncertain, poisoned, delivered, sent, badReuse>>
\* src: Sources/DMXCore/Agent.swift:185-212
Send == /\ phase = "send"
        /\ sent' = [sent EXCEPT ![call] = @ + 1]
        /\ replies' = Append(replies, call)
        /\ phase' = IF WholeLease THEN "receive" ELSE "readAcquire"
        /\ UNCHANGED <<call, live, uncertain, failedDup, poisoned, delivered, badReuse>>
\* Mutation only: historical per-frame acquisition, absent from current whole exchange.
ReadAcquire == /\ phase = "readAcquire" /\ phase' = "receive"
               /\ UNCHANGED <<call, replies, live, uncertain, failedDup, poisoned, delivered, sent, badReuse>>
\* Mutation only: historical split acquisition, absent from the current exchange.
FailAfterSend == /\ phase = "readAcquire" /\ ~failedDup
                 /\ failedDup' = TRUE /\ phase' = "finish" /\ uncertain' = TRUE
                 /\ live' = IF Retire THEN FALSE ELSE live
                 /\ UNCHANGED <<call, replies, poisoned, delivered, sent, badReuse>>
\* A malformed peer is independent of the implementation variant. ID 3 is never sent.
\* src: Tests/DMXCoreTests/FrameConnectionTests.swift:128-141
PoisonReply == /\ AllowPoison /\ phase = "receive" /\ Len(replies) > 0 /\ ~poisoned
               /\ replies' = <<3>> \o Tail(replies) /\ poisoned' = TRUE
               /\ UNCHANGED <<call, phase, live, uncertain, failedDup, delivered, sent, badReuse>>
\* src: Sources/DMXCore/Agent.swift:342-357
Receive == /\ phase = "receive" /\ Len(replies) > 0
           /\ LET response == Head(replies) IN
              /\ delivered' = IF Correlate /\ response # call THEN delivered ELSE [delivered EXCEPT ![call] = response]
              /\ uncertain' = (uncertain \/ (response # call))
              /\ live' = IF Retire /\ Correlate /\ response # call THEN FALSE ELSE live
           /\ replies' = Tail(replies) /\ phase' = "finish"
           /\ UNCHANGED <<call, failedDup, poisoned, sent, badReuse>>
\* src: Sources/DMXCore/Agent.swift:185-189
NextCall == /\ phase = "finish" /\ call = 1
            /\ call' = 2 /\ phase' = "acquire"
            /\ UNCHANGED <<replies, live, uncertain, failedDup, poisoned, delivered, sent, badReuse>>
\* src: Sources/DMXCore/Agent.swift:412-462
Reconnect == /\ phase = "acquire" /\ ~live
             /\ live' = TRUE /\ uncertain' = FALSE
             /\ LET replaying == Replay /\ call = 2 /\ sent[1] > 0 IN
                /\ replies' = IF replaying THEN <<1>> ELSE <<>>
                /\ sent' = IF replaying THEN [sent EXCEPT ![1] = @ + 1] ELSE sent
             /\ UNCHANGED <<call, phase, failedDup, poisoned, delivered, badReuse>>
Done == phase = "finish" /\ call = 2
\* Finite harness stuttering; no production statement.
Terminated == Done /\ UNCHANGED vars
Next == Acquire \/ FailBeforeSend \/ Send \/ ReadAcquire \/ FailAfterSend \/ PoisonReply \/ Receive \/ NextCall \/ Reconnect \/ Terminated
Spec == Init /\ [][Next]_vars
TypeOK == /\ call \in 1..2 /\ phase \in {"acquire", "send", "readAcquire", "receive", "finish"}
          /\ replies \in Seq(1..3) /\ Len(replies) <= 2
          /\ live \in BOOLEAN /\ uncertain \in BOOLEAN /\ failedDup \in BOOLEAN /\ poisoned \in BOOLEAN
          /\ delivered \in [1..2 -> 0..3] /\ sent \in [1..2 -> 0..2] /\ badReuse \in BOOLEAN
NeverCompletes == ~Done
NeverFailsBeforeSend == ~failedDup
=============================================================================
