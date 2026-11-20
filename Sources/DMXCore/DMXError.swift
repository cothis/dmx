/// Every failure dmx reports carries a stable code and, where possible, the next step to take.
/// The shape is the same in text and `--json` output so humans and agents read the same thing.
public struct DMXError: Error, Codable, Sendable {
    public let code: String
    public let message: String
    public let hint: String?

    public init(_ code: String, _ message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

extension DMXError {
    /// For a failure raised without a hint of its own: every failure names a next command.
    public static let defaultHint = "run `dmx doctor`; if it finds nothing wrong, see `dmx status` and ~/.dmx/logs/daemon.log"
}
