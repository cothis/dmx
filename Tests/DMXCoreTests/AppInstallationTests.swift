import Foundation
import Testing
@testable import DMXCore

/// Uses a real signed bundle, including its runnable CLI; make apptest builds this fixture.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DMX_APP_TEST_BUNDLE"] != nil))
struct AppInstallationTests {
    @Test func rollbackRestoresBothEntriesAfterLinkCommitFails() throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DMX_APP_TEST_BUNDLE"]))
        let work = fm.temporaryDirectory.appendingPathComponent("dmx-transaction-\(UUID())")
        defer { try? fm.removeItem(at: work) }
        let app = work.appendingPathComponent("dmx.app"), bin = work.appendingPathComponent("bin")
        _ = try AppInstallation.install(bundle: source, destination: app, binDirectory: bin)
        let helper = app.appendingPathComponent("Contents/MacOS/dmx")
        let digest = try sha256Hex(of: helper)
        let oldInode = try fm.attributesOfItem(atPath: app.path)[.systemFileNumber] as? UInt64
        let cli = bin.appendingPathComponent("dmx")
        let originalLink = try fm.destinationOfSymbolicLink(atPath: cli.path)
        do {
            try AppInstallation.replace(source: source, destination: app, binDirectory: bin) { _, _ in
                // Production's atomic link rename has failed after the app exchange.
                throw CocoaError(.fileWriteNoPermission)
            }
            Issue.record("accepted a failed terminal-link rename")
        } catch let error as DMXError { #expect(error.code == "app_install_failed") }
        #expect(try sha256Hex(of: helper) == digest)
        #expect(try fm.attributesOfItem(atPath: app.path)[.systemFileNumber] as? UInt64 == oldInode)
        #expect(try fm.destinationOfSymbolicLink(atPath: cli.path) == originalLink)
        #expect(try AppInstallation.verify(app) == dmxVersion)
        #expect(try fm.contentsOfDirectory(atPath: work.path).allSatisfy { !$0.contains("previous") })
    }
}
