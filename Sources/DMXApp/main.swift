import AppKit
import DMXCore

// AppKit owns rendering, keyboard navigation, accessibility, appearance and menu scrolling.
// All engine work stays in DMXCore; the CLI never links AppKit.
@MainActor
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine: MenuEngine
    private var observer: EngineActivityObserver?
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var pid: Int32?
    private var activity: EngineActivity?
    private var status: DaemonStatus?
    private var containers: [MenuEngine.Container]?
    private var error: Error?
    private var errorAlert: NSAlert?
    private var startup: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var containerTask: Task<Void, Never>?
    private var refreshing = false
    private var ready = false
    private var busy = false
    private var quitting = false
    private var mayTerminate = false
    private var automaticExit = false
    private var phase = "Starting…"

    override init() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dmx").path
        engine = MenuEngine(executable: helper)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if error != nil { showError() }
        else { item.button?.performClick(nil) }
        return false
    }

    private func start() {
        guard startup == nil, !quitting else { return }
        dismissError()
        error = nil; ready = false; phase = "Starting…"
        render()
        do {
            if observer == nil {
                observer = try EngineActivityObserver(paths: engine.paths, changed: { [weak self] in self?.changed($0) },
                                                      exited: { [weak self] in self?.exited($0) })
            }
        } catch { fail(error); return }
        startup = Task {
            defer { startup = nil }
            do {
                status = try await engine.start { [weak self] pid in
                    await self?.connected(pid)
                }
                ready = true
                if !quitting {
                    // An external stop can arrive while first-time tools are downloading.
                    // Reconcile a receipt received before ready instead of painting Running.
                    if let receipt = EngineActivity.read(paths: engine.paths), receipt.pid == pid {
                        changed(receipt)
                    } else {
                        phase = status?.state == "running" ? "Running" : "Stopped"
                        render()
                        if phase == "Stopped" { exitAfterIdle() }
                    }
                }
            } catch { if !quitting { fail(error) } }
        }
    }

    private func connected(_ pid: Int32) {
        self.pid = pid
        observer?.watch(pid: pid)
    }

    private func changed(_ receipt: EngineActivity) {
        guard receipt.pid == pid, !quitting else { return }
        activity = receipt
        if let failure = receipt.failure {
            fail(DMXError(failure.code, failure.message, hint: failure.hint))
            return
        }
        switch receipt.state {
        case "starting": phase = "Starting…"
        case "running": phase = "Running"
        case "stopping": phase = "Stopping…"
        case "stopped":
            phase = "Stopped"
            status = nil
            if ready, !busy, !refreshing, error == nil { exitAfterIdle() }
        default: break
        }
        render()
    }

    private func exited(_ pid: Int32) {
        guard self.pid == pid, !quitting, !automaticExit, error == nil else { return }
        if activity?.state == "stopped", activity?.failure == nil, ready, !busy, !refreshing, error == nil {
            terminateNow()
        } else {
            fail(DMXError("daemon_exited", "The dmx engine exited unexpectedly.", hint: "Run `dmx doctor`, then retry."))
        }
    }

    private func exitAfterIdle() {
        guard !automaticExit, let pid else { return }
        automaticExit = true
        Task {
            do {
                let released = try await engine.releaseAfterIdle(pid: pid)
                guard !quitting else { return }
                if released { terminateNow() }
                else { automaticExit = false; phase = "Running"; render() }
            } catch {
                guard !quitting else { return }
                // The daemon may have exited between its stopped receipt and this call.
                if kill(pid, 0) != 0 { terminateNow() }
                else { automaticExit = false; fail(error) }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        refresh()
        trace("menu_opened")
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { trace("menu_closed") }
    }

    /// Opt-in local QA receipt, useful when accessibility automation cannot select a
    /// windowless menu app. It records callbacks only and never drives the interface.
    private func trace(_ event: String) {
        guard ProcessInfo.processInfo.environment["DMX_MENU_TRACE"] == "1" else { return }
        let action = errorAlert?.buttons.first?.action
        let object: [String: Any] = ["event": event, "phase": phase,
                                     "errorButtonAction": action.map(NSStringFromSelector) ?? "",
                                     "items": menu.items.map { ["title": $0.title, "enabled": $0.isEnabled] }]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: engine.paths.activityDirectory.appendingPathComponent("menu-ui.json"), options: [.atomic])
        }
    }

    private func refresh() {
        guard ready, !busy, !refreshing, !quitting, !automaticExit, phase == "Running" else { return }
        refreshing = true
        render()
        refreshTask = Task {
            defer {
                refreshTask = nil
                refreshing = false
                if activity?.state == "stopped", error == nil, !quitting { exitAfterIdle() }
                render()
            }
            do {
                status = try await engine.status()
                guard status?.state == "running", !quitting else { return }
                containers = try await engine.containers()
                guard !quitting else { return }
                // The first listing may start dockerd; show memory after that work.
                status = try await engine.status()
            } catch { if !quitting { fail(error, alert: false) } }
        }
    }

    private func render() {
        let symbol = error != nil ? "exclamationmark.triangle" : (phase == "Running" ? "shippingbox.fill" : "shippingbox")
        item?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "dmx — \(phase)")
        item?.button?.image?.isTemplate = true
        item?.button?.setAccessibilityLabel("dmx — \(phase)")
        item?.button?.toolTip = "dmx — \(phase)"
        menu.removeAllItems()
        add("dmx — \(error == nil ? phase : "Needs attention")")
        if let footprint = status?.hostFootprintMb {
            add("Engine: \(footprint) MiB  ·  Menu: \(HostFootprint.read(pid: getpid())?.footprintMb ?? 0) MiB")
        }
        if let failure = error {
            let message = (failure as? DMXError)?.message ?? failure.localizedDescription
            let detail = add("Show error…", action: #selector(showErrorAction))
            detail.toolTip = message
            if !quitting { add("Retry", action: #selector(retry)) }
        }
        menu.addItem(.separator())
        let count = activity?.containers ?? status?.containers
        add(count.map { "Containers (\($0) running)" } ?? "Containers")
        if let containers {
            if containers.isEmpty { add("No containers yet") }
            for container in containers.prefix(100) {
                let row = add(container.name)
                row.isEnabled = true
                row.image = NSImage(systemSymbolName: container.running ? "play.circle.fill" : "stop.circle", accessibilityDescription: container.state)
                row.toolTip = "\(container.name) — \(container.status)"
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                let image = NSMenuItem(title: shortened(container.image), action: nil, keyEquivalent: "")
                image.isEnabled = false; image.toolTip = container.image
                submenu.addItem(image)
                let state = NSMenuItem(title: container.status, action: nil, keyEquivalent: "")
                state.isEnabled = false; submenu.addItem(state)
                submenu.addItem(.separator())
                let action = NSMenuItem(title: container.running ? "Stop" : "Start", action: #selector(toggleContainer(_:)), keyEquivalent: "")
                action.target = self; action.representedObject = container
                action.isEnabled = !busy && !quitting && phase == "Running"
                submenu.addItem(action)
                row.submenu = submenu
            }
            if containers.count > 100 { add("\(containers.count - 100) more — use docker ps -a") }
        } else { add(refreshing ? "Loading containers…" : "Open menu to load containers") }
        menu.addItem(.separator())
        let refresh = add("Refresh", action: #selector(refreshAction), key: "r")
        refresh.isEnabled = ready && !refreshing && !busy && !quitting && phase == "Running"
        add("Open logs…", action: #selector(openLogs))
        menu.addItem(.separator())
        let quit = add(quitting ? "Stopping dmx…" : "Quit dmx", action: #selector(quitAction), key: "q")
        quit.isEnabled = !quitting
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: shortened(title), action: action, keyEquivalent: key)
        row.target = self; row.isEnabled = action != nil
        menu.addItem(row)
        return row
    }

    private func shortened(_ value: String) -> String {
        let clean = value.components(separatedBy: .newlines).joined(separator: " ")
        return clean.count > 72 ? String(clean.prefix(69)) + "…" : clean
    }

    @objc private func refreshAction() { refresh() }
    @objc private func retry() {
        dismissError()
        if ready, let pid, kill(pid, 0) == 0, activity?.state == "running" { error = nil; phase = "Running"; refresh() }
        else { start() }
    }

    @objc private func toggleContainer(_ sender: NSMenuItem) {
        guard let container = sender.representedObject as? MenuEngine.Container, !busy, !quitting else { return }
        busy = true; render()
        containerTask = Task {
            defer { containerTask = nil }
            await refreshTask?.value
            do {
                try await engine.setRunning(!container.running, container: container)
                if phase == "Running" { error = nil }
            }
            catch { if !quitting { fail(error) } }
            busy = false
            if !quitting {
                if activity?.state == "stopped", error == nil { exitAfterIdle() }
                else { refresh() }
            }
            render()
        }
    }

    @objc private func openLogs() { NSWorkspace.shared.open(engine.paths.logs) }
    @objc private func showErrorAction() { showError() }
    private func showError() {
        guard let error else { return }
        let failure = error as? DMXError
        let isNew = errorAlert == nil
        let alert = errorAlert ?? NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "dmx needs attention"
        alert.informativeText = (failure?.message ?? error.localizedDescription) + (failure?.hint.map { "\n\n\($0)" } ?? "")
        if isNew { alert.addButton(withTitle: "OK") }
        alert.showsHelp = false
        alert.showsSuppressionButton = false
        alert.layout()
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(dismissError)
        errorAlert = alert
        NSApp.activate(ignoringOtherApps: true)
        // A modeless native alert keeps actor tasks and lifecycle callbacks flowing. Never
        // nest runModal() from a startup task and a process-exit callback.
        if isNew { alert.window.center() }
        alert.window.makeKeyAndOrderFront(nil)
        trace("error_shown")
    }

    @objc private func dismissError() {
        if errorAlert != nil { trace("error_dismissed") }
        errorAlert?.window.orderOut(nil)
        errorAlert = nil
    }

    private func fail(_ error: Error, alert: Bool = true) {
        let previous = self.error as? DMXError
        let next = error as? DMXError
        let duplicate = previous != nil && previous?.code == next?.code && previous?.message == next?.message
        self.error = error
        phase = "Needs attention"
        render()
        if alert && !duplicate { showError() }
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        guard !quitting else { return .terminateLater }
        dismissError()
        quitting = true; phase = "Stopping…"; render()
        Task {
            await startup?.value
            // Drain work before the final stop. No in-flight Docker action may start a VM
            // again after Quit has completed, including the paused-container two-step stop.
            await containerTask?.value
            await refreshTask?.value
            do {
                if pid != nil { try await engine.stop() }
                mayTerminate = true
                observer?.close()
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
                NSApp.reply(toApplicationShouldTerminate: false)
                fail(error)
            }
        }
        return .terminateLater
    }

    private func terminateNow() {
        mayTerminate = true
        observer?.close()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = MenuApp()
app.delegate = delegate
app.run()
