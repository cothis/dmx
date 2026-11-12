---- MODULE Spec ----
EXTENDS Naturals, Sequences
CONSTANTS FrameLimit, HonorCredit
VARIABLES credit, queued, writing, sent, rejected
vars == <<credit, queued, writing, sent, rejected>>
P == INSTANCE Properties
NoLegalInputRejected == P!NoLegalInputRejected
NeverSends == P!NeverSends
RECURSIVE Bytes(_)
Bytes(q) == IF Len(q) = 0 THEN 0 ELSE Head(q) + Bytes(Tail(q))
Init == /\ credit = 4 /\ queued = <<>> /\ writing = 0 /\ sent = 0 /\ rejected = FALSE
\* src: FrameConnection.writeStdin; valid clients consume byte credit before each frame.
Send == \E n \in 1..2:
        /\ (~HonorCredit \/ n <= credit) /\ sent + n <= 8
        /\ credit' = (IF n <= credit THEN credit - n ELSE 0) /\ sent' = sent + n
        /\ rejected' = (rejected \/ (IF FrameLimit THEN Len(queued) >= 3 ELSE Bytes(queued) + n > 4))
        /\ queued' = Append(queued, n)
        /\ UNCHANGED writing
\* src: InputQueue.take. Coalescing is abstracted to one original frame at a time (harder bound).
Take == /\ writing = 0 /\ Len(queued) > 0
        /\ writing' = Head(queued) /\ queued' = Tail(queued)
        /\ UNCHANGED <<credit,sent,rejected>>
\* src: stdin writer grants credit after the child's write completes.
Write == /\ writing > 0 /\ credit' = credit + writing /\ writing' = 0
         /\ UNCHANGED <<queued,sent,rejected>>
Terminated == UNCHANGED vars
Next == Send \/ Take \/ Write \/ Terminated
Spec == Init /\ [][Next]_vars
====
