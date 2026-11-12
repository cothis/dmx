import Foundation

/// An uninterruptible host syscall cannot be made safe by freeing its guest RAM underneath it.
/// Bound the whole process instead; launchd or the next CLI request can create a fresh engine.
final class TeardownWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var active = false

    func arm(after seconds: Double) {
        lock.withLock {
            guard !active else { return }
            active = true
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.setEventHandler { [weak self] in
                self?.lock.withLock {
                    guard self?.active == true else { return }
                    // A diagnostic sink can itself be on a hung filesystem. It must not
                    // prevent the fail-stop deadline from terminating the process.
                    DispatchQueue.global().async {
                        Diagnostics.write(Data("dmx: shutdown_timeout: host device work did not finish; exiting without freeing live guest RAM. Run `dmx doctor`, then `dmx start`.\n".utf8))
                    }
                    usleep(10_000)
                    _exit(70)
                }
            }
            timer.schedule(deadline: .now() + seconds)
            timer.resume()
            self.timer = timer
        }
    }

    func cancel() { lock.withLock { active = false; timer?.cancel(); timer = nil } }
    deinit { timer?.cancel() }
}
