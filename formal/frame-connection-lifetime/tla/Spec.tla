------------------------------- MODULE Spec -------------------------------
EXTENDS Naturals, FiniteSets, Properties
CONSTANTS Ops, LeaseFD
VARIABLES phase, calls, slot, closed
vars == <<phase, calls, slot, closed, foreignIO, lateAcquire>>

Init ==
    /\ phase = [o \in Ops |-> "idle"]
    /\ calls = [o \in Ops |-> 0]
    /\ slot = "original"
    /\ closed = FALSE
    /\ foreignIO = FALSE
    /\ lateAcquire = FALSE

\* src: Sources/DMXCore/Agent.swift:327-330 (queued receive; concurrent exec feed also submits writes)
Submit(o) ==
    /\ phase[o] = "idle"
    /\ phase' = [phase EXCEPT ![o] = "pending"]
    /\ UNCHANGED <<calls, slot, closed, foreignIO, lateAcquire>>

\* src: Sources/DMXCore/Agent.swift:162-167 (baseline: no close check or owned duplicate)
Acquire(o) ==
    /\ phase[o] = "pending"
    /\ phase' = [phase EXCEPT ![o] = IF LeaseFD /\ closed THEN "done" ELSE "active"]
    /\ lateAcquire' = (lateAcquire \/ (closed /\ ~LeaseFD))
    /\ UNCHANGED <<calls, slot, closed, foreignIO>>

\* src: Sources/DMXCore/Agent.swift:254-283 (two possible short transfers per frame)
Transfer(o) ==
    /\ phase[o] = "active"
    /\ calls[o] < 2
    /\ calls' = [calls EXCEPT ![o] = @ + 1]
    /\ foreignIO' = (foreignIO \/ (~LeaseFD /\ slot = "foreign"))
    /\ UNCHANGED <<phase, slot, closed, lateAcquire>>

\* src: Sources/DMXCore/Agent.swift:168-169 (frame finishes; fixed implementation releases its lease)
Finish(o) ==
    /\ phase[o] = "active" /\ calls[o] = 2
    /\ phase' = [phase EXCEPT ![o] = "done"]
    /\ UNCHANGED <<calls, slot, closed, foreignIO, lateAcquire>>

\* src: Sources/DMXCore/Agent.swift:150-157 (closed flag and original descriptor close under closeLock)
Close ==
    /\ ~closed
    /\ closed' = TRUE
    /\ slot' = "free"
    /\ UNCHANGED <<phase, calls, foreignIO, lateAcquire>>

\* src: Tests/DMXCoreTests/FrameConnectionTests.swift:23-36 (environment: OS reuses a closed number)
Reuse ==
    /\ slot = "free"
    /\ slot' = "foreign"
    /\ UNCHANGED <<phase, calls, closed, foreignIO, lateAcquire>>

Done == closed /\ slot = "foreign" /\ \A o \in Ops : phase[o] = "done"
Terminated == Done /\ UNCHANGED vars
Next == (\E o \in Ops : Submit(o) \/ Acquire(o) \/ Transfer(o) \/ Finish(o))
        \/ Close \/ Reuse \/ Terminated
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in [Ops -> {"idle", "pending", "active", "done"}]
    /\ calls \in [Ops -> 0..2]
    /\ slot \in {"original", "free", "foreign"}
    /\ closed \in BOOLEAN /\ foreignIO \in BOOLEAN /\ lateAcquire \in BOOLEAN

\* Must fail: completion and descriptor reuse must be reachable with the fix enabled.
NeverCompletes == ~Done
NeverReuses == slot # "foreign"
=============================================================================
