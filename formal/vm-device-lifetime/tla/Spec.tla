---- MODULE Spec ----
EXTENDS Naturals
CONSTANTS Drain, AliveGuard
VARIABLES owner, alive, ram, job, stop, destroyed, rebooted, external,
          foreignHV, freedRAM, done
vars == <<owner, alive, ram, job, stop, destroyed, rebooted, external,
          foreignHV, freedRAM, done>>
P == INSTANCE Properties
NoForeignHV == P!NoForeignHV
NoFreedRAM == P!NoFreedRAM
NeverCompletes == P!NeverCompletes
Init == /\ owner = 1 /\ alive = TRUE /\ ram = TRUE /\ job = "queued"
        /\ stop = FALSE /\ destroyed = FALSE /\ rebooted = FALSE
        /\ external = FALSE /\ foreignHV = FALSE /\ freedRAM = FALSE /\ done = FALSE
\* src: VirtioBalloon.drain / VirtioNet.transmit: callbacks may be in flight at stop.
Begin == /\ job = "queued" /\ job' = "running"
         /\ UNCHANGED <<owner,alive,ram,stop,destroyed,rebooted,external,foreignHV,freedRAM,done>>
\* src: device completion: raw guest RAM access, then Machine.release/setSPI.
Finish == /\ job = "running" /\ job' = "done"
          /\ freedRAM' = (freedRAM \/ ~ram)
          /\ foreignHV' = (foreignHV \/ ((~AliveGuard \/ alive) /\ owner # 1))
          /\ UNCHANGED <<owner,alive,ram,stop,destroyed,rebooted,external,done>>
\* src: Machine.stop: halt vCPUs, no further guest intake.
Stop == /\ ~stop /\ stop' = TRUE
        /\ UNCHANGED <<owner,alive,ram,job,destroyed,rebooted,external,foreignHV,freedRAM,done>>
\* src: stop barriers precede Machine.destroyVM; mapping lock closes the alive gate.
Destroy == /\ stop /\ ~destroyed /\ (~Drain \/ job = "done")
           /\ destroyed' = TRUE /\ alive' = FALSE /\ owner' = 0 /\ ram' = FALSE
           /\ UNCHANGED <<job,stop,rebooted,external,foreignHV,freedRAM,done>>
\* src: the daemon can create the next VM after waitUntilStopped returns.
Reboot == /\ destroyed /\ ~rebooted /\ rebooted' = TRUE /\ owner' = 2
          /\ UNCHANGED <<alive,ram,job,stop,destroyed,external,foreignHV,freedRAM,done>>
\* src: stale controller callback / old device interrupt, independently of queue draining.
External == /\ rebooted /\ ~external /\ external' = TRUE
            /\ foreignHV' = (foreignHV \/ ((~AliveGuard \/ alive) /\ owner # 1))
            /\ UNCHANGED <<owner,alive,ram,job,stop,destroyed,rebooted,freedRAM,done>>
Complete == /\ rebooted /\ external /\ job = "done" /\ ~done /\ done' = TRUE
            /\ UNCHANGED <<owner,alive,ram,job,stop,destroyed,rebooted,external,foreignHV,freedRAM>>
Terminated == done /\ UNCHANGED vars
Next == Begin \/ Finish \/ Stop \/ Destroy \/ Reboot \/ External \/ Complete \/ Terminated
Spec == Init /\ [][Next]_vars
====
