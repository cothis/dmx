/// The version of this binary, and the tag of the release it belongs to (`v<version>`).
///
/// It lives here rather than in `Sources/dmx` because the daemon reports it over the control
/// socket and `DaemonClient` compares it with the daemon that answers: after an update the old
/// daemon keeps serving until it exits, and a user who does not know that would think the new
/// version is running. `scripts/release.py` reads this line to check the version it was asked for.
public let dmxVersion = "0.3.6"
