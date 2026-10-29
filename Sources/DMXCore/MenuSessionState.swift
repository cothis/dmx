import Foundation

/// The menu's actual lifecycle policy, shared by the AppKit delegate and non-GUI regressions.
/// A failed user operation may be displayed, but never keeps a normally stopped engine's UI up.
public struct MenuSessionState: Sendable {
    public enum Phase: String, Sendable { case starting, running, stopping, stopped, needsAttention }
    public enum FailureScope: Sendable { case lifecycle, operation }
    public var phase: Phase = .starting
    public private(set) var lifecycleFailure: DMXError?
    public private(set) var operationFailure: DMXError?
    public var failure: DMXError? { lifecycleFailure ?? operationFailure }
    public var blocksAutomaticExit: Bool { lifecycleFailure != nil }
    private var pid: Int32?
    private var lastReceipt: EngineActivity?
    private var hasCurrentReceipt = false
    public private(set) var receiptRevision: UInt64 = 0

    public init() {}

    public mutating func bind(pid: Int32) {
        if self.pid != pid { lastReceipt = nil; hasCurrentReceipt = false; receiptRevision &+= 1 }
        self.pid = pid
    }

    public mutating func prepareStart() {
        lifecycleFailure = nil; operationFailure = nil; phase = .starting
        hasCurrentReceipt = false
        // Retain sequence for a same-daemon Retry: stale failure receipts cannot reapply.
    }

    public mutating func failed(_ failure: DMXError, scope: FailureScope) {
        switch scope {
        case .lifecycle: lifecycleFailure = failure; phase = .needsAttention
        case .operation: if phase != .stopped { operationFailure = failure }
        }
    }

    public mutating func operationSucceeded() { operationFailure = nil }

    /// A boot response can have been queued before a newer stopped receipt. Once this start
    /// has received an authoritative event, its phase wins over the older RPC snapshot.
    public mutating func reconcileBoot(state: String) {
        if !hasCurrentReceipt { reconcile(state: state) }
    }

    public mutating func reconcile(state: String) {
        guard lifecycleFailure == nil else { return }
        guard let phase = Phase(rawValue: state) else { return }
        self.phase = phase
        if phase == .stopped { operationFailure = nil }
    }

    @discardableResult
    public mutating func receive(_ receipt: EngineActivity) -> Bool {
        guard receipt.pid == pid else { return false }
        if let previous = lastReceipt {
            if let seq = receipt.sequence, let old = previous.sequence, seq <= old { return false }
            if receipt == previous { return false }
        }
        lastReceipt = receipt
        hasCurrentReceipt = true; receiptRevision &+= 1
        if let failure = receipt.failure {
            failed(DMXError(failure.code, failure.message, hint: failure.hint), scope: .lifecycle)
        } else {
            if receipt.state == "starting" || receipt.state == "running" { lifecycleFailure = nil }
            reconcile(state: receipt.state)
        }
        return true
    }

    public func shouldExit(startupFinished: Bool, busy: Bool, refreshing: Bool) -> Bool {
        startupFinished && !busy && !refreshing && phase == .stopped && !blocksAutomaticExit
    }
}
