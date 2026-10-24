import Foundation

/// Runs a command in the daemon's VM with this process's stdin, stdout and stderr attached,
/// booting the VM (and starting the daemon) if needed. Returns the command's exit status, or
/// 128 + signal if it was killed. With `tty` the command gets a pseudo-terminal sized like ours,
/// our terminal goes raw, and window size changes follow. SIGINT, SIGTERM and SIGHUP sent to
/// dmx are passed on to the command instead of killing dmx.
@MainActor
public func execThroughDaemon(paths: Paths, argv: [String], tty: Bool, env: [String], cwd: String?) async throws -> Int32 {
    guard let client = try await DaemonClient.connect(paths: paths, start: true) else {
        throw DMXError("daemon_unreachable", "no dmx daemon is running")
    }
    var request = ExecRequest(argv: argv)
    request.env = env
    request.cwd = cwd
    request.stdin = true
    request.tty = tty
    if tty {
        let (rows, cols) = terminalSize()
        request.rows = rows
        request.cols = cols
        if let term = ProcessInfo.processInfo.environment["TERM"], !env.contains(where: { $0.hasPrefix("TERM=") }) {
            request.env.append("TERM=\(term)")
        }
    }
    let session: ExecSession
    do {
        session = try await client.exec(request)
    } catch {
        client.close()
        throw error
    }
    client.close()

    let terminal = tty ? RawTerminal() : nil
    defer { terminal?.restore() }
    var sources: [DispatchSourceSignal] = []
    defer { for s in sources { s.cancel() } }
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { try? session.signal(number) }
        source.resume()
        sources.append(source)
    }
    if tty {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler {
            let (rows, cols) = terminalSize()
            try? session.resize(rows: rows, cols: cols)
        }
        source.resume()
        sources.append(source)
    }
    pipeStdin(to: session)

    for try await event in session.events {
        switch event {
        case .stdout(let data): FileHandle.standardOutput.write(data)
        case .stderr(let data): FileHandle.standardError.write(data)
        case .exit(let exit): return exit.code ?? 128 + (exit.signal ?? 0)
        }
    }
    throw DMXError("daemon_disconnected", "\(argv[0]): connection closed before the process exited", hint: "see \(paths.daemonLog.path)")
}

private func terminalSize() -> (rows: Int, cols: Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 || ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0,
          size.ws_row > 0, size.ws_col > 0 else { return (24, 80) }
    return (Int(size.ws_row), Int(size.ws_col))
}
