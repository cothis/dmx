# Remaining lifecycle repairs

The 13 outstanding items from the 2026-11-12 review are in scope. G1/G9 share the exec transport
and child lifetime, G2/L3 bound stop, G3/G8/G11 cover network backpressure and lifetime, G4 makes
urgent control independent, G5/G6 protect storage, G7 retries listing, L5 retries a lost spawn.
L6 is a question, not an established bug: the local SDK explicitly guarantees cancellation is
latched before run; an entitled Hypervisor test confirms the next run returns CANCELED before
its 200 ms rescue. Guarding the created vCPU lifetime also prevents exit against an invalid ID.

The finite credit model has a byte window of 4, chunks 1..2, and total input at most 8. Payloads,
FDs, process control, syscall behavior and liveness are abstracted; no fairness/state constraints.
It checks that a compliant host's input is never rejected by the bounded queue. The frame-count
mutation reproduces a transient development defect: four one-byte frames exceed three slots
while remaining within the byte window. Removing the host credit guard independently overflows
the byte queue. This model is not an OS/whole-program correctness proof.

Real evidence: original G1 leaks its stalled child; original L5 fails after 15 s; original G6
returns EIO, aborts ext4's journal and remounts read-only on an isolated full APFS image. The
candidate reaps the child, retries the daemon spawn and retains ENOSPC requests until space
returns. A blocked share callback exits its isolated VM process with code 70 under a 0.5 s
injected teardown deadline (production 20 s). First-boot SIGTERM and three unpack crashes recover.
The unpack durability failure was not reproduced on the old guest; ordering is repaired from
the sync contract and verified with real restarts. Three tested crash offsets do not prove all
power-loss orderings. The 30 s boot grace itself is not a wall-clock exhaustive timing proof.
