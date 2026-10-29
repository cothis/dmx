------------------------------- MODULE Spec -------------------------------
EXTENDS Naturals, FiniteSets, Properties
CONSTANTS Ops, GuardClosed, OwnLease, ReleaseEarly, AtomicAcquire
VARIABLES phase, calls, slot, closed, handle, copySlot
vars == <<phase, calls, slot, closed, handle, copySlot, foreignIO, lateAcquire>>

Init == /\ phase = [o \in Ops |-> "idle"]
        /\ calls = [o \in Ops |-> 0]
        /\ handle = [o \in Ops |-> "none"]
        /\ copySlot = [o \in Ops |-> "free"]
        /\ slot = "original" /\ closed = FALSE
        /\ foreignIO = FALSE /\ lateAcquire = FALSE

\* src: Sources/DMXCore/Agent.swift:360-366
Submit(o) == /\ phase[o] = "idle"
             /\ phase' = [phase EXCEPT ![o] = "pending"]
             /\ UNCHANGED <<calls, slot, closed, handle, copySlot, foreignIO, lateAcquire>>

\* Source: withOpenFD. Guard and dup execute under the same close lock.
\* A dup binds the current open-file description, never the future meaning of slot.
\* src: Sources/DMXCore/Agent.swift:168-177
Acquire(o) ==
    /\ AtomicAcquire
    /\ phase[o] = "pending"
    /\ LET accepted == ~(GuardClosed /\ closed) /\ slot # "free" IN
       /\ phase' = [phase EXCEPT ![o] = IF accepted THEN "active" ELSE "done"]
       /\ handle' = [handle EXCEPT ![o] = IF ~accepted THEN "none" ELSE IF OwnLease THEN "copy" ELSE "raw"]
       /\ copySlot' = [copySlot EXCEPT ![o] = IF accepted /\ OwnLease THEN slot ELSE "free"]
       /\ lateAcquire' = (lateAcquire \/ (accepted /\ closed))
    /\ UNCHANGED <<calls, slot, closed, foreignIO>>

\* Mutation only: moving dup outside closeLock opens a check/dup race.
\* src: Sources/DMXCore/Agent.swift:168-177
CheckOnly(o) == /\ ~AtomicAcquire /\ phase[o] = "pending"
                /\ phase' = [phase EXCEPT ![o] = IF GuardClosed /\ closed THEN "done" ELSE "checked"]
                /\ UNCHANGED <<calls, slot, closed, handle, copySlot, foreignIO, lateAcquire>>
\* src: Sources/DMXCore/Agent.swift:168-177
DuplicateAfterCheck(o) ==
    /\ ~AtomicAcquire
    /\ phase[o] = "checked"
    /\ LET accepted == slot # "free" IN
       /\ phase' = [phase EXCEPT ![o] = IF accepted THEN "active" ELSE "done"]
       /\ handle' = [handle EXCEPT ![o] = IF ~accepted THEN "none" ELSE IF OwnLease THEN "copy" ELSE "raw"]
       /\ copySlot' = [copySlot EXCEPT ![o] = IF accepted /\ OwnLease THEN slot ELSE "free"]
       /\ lateAcquire' = (lateAcquire \/ (accepted /\ closed))
    /\ UNCHANGED <<calls, slot, closed, foreignIO>>


\* Independent lifetime mutation: drop an owned copy before the final syscall.
\* src: Sources/DMXCore/Agent.swift:176-177
DropCopy(o) == /\ ReleaseEarly /\ phase[o] = "active" /\ handle[o] = "copy"
               /\ copySlot[o] = "original"
               /\ copySlot' = [copySlot EXCEPT ![o] = "free"]
               /\ UNCHANGED <<phase, calls, slot, closed, handle, foreignIO, lateAcquire>>
\* src: Sources/DMXCore/Agent.swift:176-177
ReuseCopy(o) == /\ phase[o] = "active" /\ handle[o] = "copy" /\ copySlot[o] = "free"
                /\ copySlot' = [copySlot EXCEPT ![o] = "foreign"]
                /\ UNCHANGED <<phase, calls, slot, closed, handle, foreignIO, lateAcquire>>

\* Observations depend on the descriptor binding at the syscall, not fix selectors.
\* src: Sources/DMXCore/Agent.swift:289-319
Transfer(o) ==
    /\ phase[o] = "active" /\ calls[o] < 2
    /\ LET target == IF handle[o] = "raw" THEN slot ELSE copySlot[o] IN
       /\ foreignIO' = (foreignIO \/ (target = "foreign"))
    /\ calls' = [calls EXCEPT ![o] = @ + 1]
    /\ UNCHANGED <<phase, slot, closed, handle, copySlot, lateAcquire>>
\* src: Sources/DMXCore/Agent.swift:176-177
Finish(o) == /\ phase[o] = "active" /\ calls[o] = 2
             /\ phase' = [phase EXCEPT ![o] = "done"]
             /\ copySlot' = [copySlot EXCEPT ![o] = "free"]
             /\ UNCHANGED <<calls, slot, closed, handle, foreignIO, lateAcquire>>
\* src: Sources/DMXCore/Agent.swift:156-165
Close == /\ ~closed /\ closed' = TRUE /\ slot' = "free"
         /\ UNCHANGED <<phase, calls, handle, copySlot, foreignIO, lateAcquire>>
\* src: formal/frame-connection-lifetime/repro/IsolatedFDProbe.swift:30-38
Reuse == /\ slot = "free" /\ slot' = "foreign"
         /\ UNCHANGED <<phase, calls, closed, handle, copySlot, foreignIO, lateAcquire>>
Done == closed /\ slot = "foreign" /\ \A o \in Ops : phase[o] = "done"
\* Finite harness stuttering; no production statement.
Terminated == Done /\ UNCHANGED vars
Next == (\E o \in Ops : Submit(o) \/ Acquire(o) \/ CheckOnly(o) \/ DuplicateAfterCheck(o) \/ DropCopy(o) \/ ReuseCopy(o) \/ Transfer(o) \/ Finish(o))
        \/ Close \/ Reuse \/ Terminated
Spec == Init /\ [][Next]_vars
TypeOK == /\ phase \in [Ops -> {"idle", "pending", "checked", "active", "done"}]
          /\ calls \in [Ops -> 0..2]
          /\ handle \in [Ops -> {"none", "copy", "raw"}]
          /\ copySlot \in [Ops -> {"free", "original", "foreign"}]
          /\ slot \in {"original", "free", "foreign"}
          /\ closed \in BOOLEAN /\ foreignIO \in BOOLEAN /\ lateAcquire \in BOOLEAN
NeverCompletes == ~Done
NeverReuses == slot # "foreign"
=============================================================================
