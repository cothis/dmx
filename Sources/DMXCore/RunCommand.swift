import Foundation

/// Boots the guest, runs one command through the agent with this process's stdin, stdout and
/// stderr attached, and powers off through the agent. Returns the command's exit status
/// (128 + signal if it was killed). `timeout` bounds only the wait for the agent, not the command.
@MainActor
public func runInGuest(paths: Paths, spec: MachineSpec, argv: [String], timeout: Duration, echo: Bool) async throws -> Int32 {
    var spec = spec
    if !echo { spec.kernelArgs.append("quiet") }
    let console = Console(fromGuest: echo ? .standardError : FileHandle(forWritingAtPath: "/dev/null")!)
    let machine = try Machine(spec: spec, paths: paths, console: console)
    try await machine.start()

    let status: Int32
    do {
        let agent = try await machine.connectAgent(timeout: timeout)
        _ = try await agent.syncTime()
        var request = ExecRequest(argv: argv)
        request.stdin = true
        let session = try await agent.exec(request)
        pipeStdin(to: session)

        var exit: ExecExit?
        for try await event in session.events {
            switch event {
            case .stdout(let data): FileHandle.standardOutput.write(data)
            case .stderr(let data): FileHandle.standardError.write(data)
            case .exit(let e): exit = e
            }
        }
        guard let exit else {
            throw DMXError("agent_disconnected", "\(argv[0]): connection closed before the process exited")
        }
        status = exit.code ?? 128 + (exit.signal ?? 0)
        try await agent.shutdown()
    } catch {
        await machine.stop()
        throw error
    }
    if case .failed(let error) = await machine.waitUntilStopped() { throw error }
    return status
}

/// Copies stdin to the guest process on a background thread, then signals EOF.
private func pipeStdin(to session: ExecSession) {
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            do { try session.write(Data(buffer[0..<n])) } catch { return }
        }
        try? session.closeStdin()
    }
}
