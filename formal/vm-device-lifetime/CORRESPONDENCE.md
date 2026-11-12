# Correspondence

| Model action | Implementation | Abstraction |
|---|---|---|
| Begin | VirtioBalloon.drain, VirtioMem.drain, VirtioNet.transmit, VirtioVsock.receiveFromGuest | One queued callback covers a finite drain |
| Finish | GuestRAM access and Machine.release/setSPI | Raw memory use followed by one atomic Hypervisor operation |
| Stop | Machine.stop, vCPU halt and threads.notify | All guest intake has ended before barriers |
| Destroy | Device stop barriers followed by Machine.destroyVM | Serial queue sync waits for callback completion; VM alive closes under map lock |
| Reboot | Daemon.running and boot | The next VM occupies the process's global Hypervisor slot |
| External | A captured Machine.setBalloonTarget, resulting setSPI | Late caller independent of queue drain |
| Complete/Terminated | waitUntilStopped and caller completion | Reachability witness, no liveness claim |

Queue draining and the alive guard are independently mutated. The guard alone cannot protect raw
RAM touched by a callback; queue draining alone cannot fence an external stale interrupt caller.
DeviceStopTests demonstrates the real missing barrier; the forced old.release probe also makes a real successor fail to boot when its guard is removed.
The frequency of natural overlap was not measured.
