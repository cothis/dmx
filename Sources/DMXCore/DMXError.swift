/// Every failure dmx reports carries a stable code and, where possible, the next step to take.
/// The shape is the same in text and `--json` output so humans and agents read the same thing.
public struct DMXError: Error, Encodable, Sendable {
    public let code: String
    public let message: String
    public let hint: String?

    public init(_ code: String, _ message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}
