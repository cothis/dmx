# VM device lifetime

Scope: queued device callbacks versus Machine destruction and creation of the next process-wide
Hypervisor VM (L1); related Machine failure cleanup (L2), controller epochs (L4), eager share-root
initialization (G10). The review's remaining 13 items are not repaired by this change.

Frozen properties come from Machine's contract: once waitUntilStopped returns the process may
create another VM. Old callbacks must neither access freed RAM nor operate on that successor VM.
The model checks one queued callback (begin/finish), one external late callback, one stop and one
successor. No liveness, fairness or state constraints. Copying actual data, guest correctness,
OS syscall cancellation and Hypervisor's implementation are abstracted. This is bounded safety,
not whole-program verification. Model properties are in tla/Properties.tla.

Reproduction: DeviceStopTests holds a real net queue callback while stop runs (fails at a0a7922).
Entitled MachineLifecycleTests injects a post-map failure and invalid kernel, and holds an agent
swap response across detach/attach. check-code.py independently removes each related repair and
requires a failing assertion, then restores the code and reruns the four VM tests.
A fourth probe calls old.release after the successor is created: removing the alive guard makes
the real successor fail to boot. This forces the stale-call ordering; it does not measure the
frequency of the natural race.
