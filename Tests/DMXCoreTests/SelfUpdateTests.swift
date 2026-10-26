import Foundation
import Testing
@testable import DMXCore

/// What `dmx update` can decide without the network: where it would download from, that a mirror
/// has no "latest", and whether the binary it replaces is signed with a Developer ID.
@Suite struct SelfUpdateTests {
    private let home = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-update-\(UUID().uuidString)")

    private func updater(base: String? = nil) -> SelfUpdate {
        let environment = base.map { ["DMX_RELEASE_URL": $0] } ?? [:]
        return SelfUpdate(current: "1.2.3", paths: Paths(environment: ["DMX_HOME": home.path]),
                          environment: environment, executable: home.appendingPathComponent("bin/dmx"))
    }

    @Test func downloadsFromTheReleaseItWasAskedFor() throws {
        #expect(try updater().archiveURL("1.2.4").absoluteString ==
                "https://github.com/cothis/dmx/releases/download/v1.2.4/dmx-1.2.4-darwin-arm64.tar.gz")
        #expect(try updater(base: "https://mirror.example.com/dmx/").archiveURL("1.2.4").absoluteString ==
                "https://mirror.example.com/dmx/v1.2.4/dmx-1.2.4-darwin-arm64.tar.gz")
    }

    /// A mirror serves <base>/<tag>/<asset> and nothing else, so there is no newest release to
    /// resolve and the version has to be named.
    @Test func aMirrorHasNoLatest() async throws {
        await #expect(throws: DMXError.self) { try await updater(base: "https://mirror.example.com/dmx").latest() }
        do {
            _ = try await updater(base: "https://mirror.example.com/dmx").latest()
        } catch let error as DMXError {
            #expect(error.code == "update_version_required")
        }
    }

    /// Platform binaries and builds from source carry no Developer ID team, so an update from one
    /// has nothing to compare the download against and says it skipped the check.
    @Test func unsignedBinariesHaveNoTeam() {
        #expect(SelfUpdate.teamIdentifier(of: URL(fileURLWithPath: "/bin/ls")) == nil)
        #expect(SelfUpdate.teamIdentifier(of: URL(fileURLWithPath: "/no/such/binary")) == nil)
    }

    /// `--version` becomes a URL and a directory that is later removed, so only a version shape
    /// is accepted.
    @Test func onlyAVersionIsAccepted() throws {
        #expect(try SelfUpdate.checked(version: "0.3.2") == "0.3.2")
        #expect(try SelfUpdate.checked(version: "1.0.0-rc.2") == "1.0.0-rc.2")
        for bad in ["", "latest", "0.3", "../../etc", "0.3.2/../..", "0.3.2 ", "0.3.2;rm -rf /"] {
            do {
                _ = try SelfUpdate.checked(version: bad)
                Issue.record("accepted \(bad.debugDescription)")
            } catch let error as DMXError {
                #expect(error.code == "update_bad_version")
            }
        }
    }

    /// Without a version named, an update only moves forwards: a dmx newer than the newest
    /// release must not be replaced by it.
    @Test func newerIsNewer() {
        #expect(SelfUpdate.isNewer("0.3.2", than: "0.3.1"))
        #expect(SelfUpdate.isNewer("0.4.0", than: "0.3.9"))
        #expect(SelfUpdate.isNewer("1.0.0", than: "0.30.0"))
        #expect(SelfUpdate.isNewer("0.3.2", than: "0.3.2-rc.1"))
        #expect(!SelfUpdate.isNewer("0.3.1", than: "0.3.2"))
        #expect(!SelfUpdate.isNewer("0.3.2", than: "0.3.2"))
        #expect(!SelfUpdate.isNewer("0.3.2-rc.1", than: "0.3.2"))
        #expect(!SelfUpdate.isNewer("0.2.9", than: "0.10.0"))
    }

    /// Replacing a build from source needs --force: it is not an installed release.
    @Test func refusesToOverwriteASourceBuild() throws {
        let build = URL(fileURLWithPath: "/Users/someone/dmx/.build/release/dmx")
        let updater = SelfUpdate(current: "1.2.3", paths: Paths(environment: ["DMX_HOME": home.path]),
                                 environment: [:], executable: build)
        do {
            try updater.checkDestination(force: false)
            Issue.record("a .build binary was accepted")
        } catch let error as DMXError {
            #expect(error.code == "update_source_build")
        }
    }
}
