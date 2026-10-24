import Foundation
import Testing
@testable import DMXCore

/// The parts of sandboxes that need no VM: policy parsing and checks, mounts against the shares,
/// image references, Docker's multiplexed stream, and the log summary.
@Suite struct SandboxTests {
    @Test func networkValues() throws {
        var p = SandboxPolicy()
        #expect(p.network == "none")
        try p.setNetwork("all")
        #expect(p.network == "all" && p.allow.isEmpty)
        try p.setNetwork("example.com, 10.0.0.0/8")
        #expect(p.network == "allowlist" && p.allow == ["example.com", "10.0.0.0/8"])
        try p.validate()
        #expect(throws: DMXError.self) { try p.setNetwork(" , ") }
        p.network = "some"
        #expect(throws: DMXError.self) { try p.validate() }
    }

    @Test func policyLimits() throws {
        var p = SandboxPolicy()
        try p.validate()
        p.ttlS = 5
        #expect(throws: DMXError.self) { try p.validate() }
        p = SandboxPolicy()
        p.memory = "lots"
        #expect(throws: DMXError.self) { try p.validate() }
        p = SandboxPolicy()
        p.mounts = [SandboxMount(host: "/a", path: "/x", writable: false), SandboxMount(host: "/b", path: "/x", writable: false)]
        #expect(throws: DMXError.self) { try p.validate() }
        p = SandboxPolicy()
        p.env = ["NOEQUALS"]
        #expect(throws: DMXError.self) { try p.validate() }
    }

    @Test func mountParsingAndShares() throws {
        #expect(try SandboxMount.parse("/src") == SandboxMount(host: "/src", path: "/src", writable: false))
        #expect(try SandboxMount.parse("/src:/app:rw") == SandboxMount(host: "/src", path: "/app", writable: true))
        #expect(try SandboxMount.parse("/src:ro") == SandboxMount(host: "/src", path: "/src", writable: false))
        #expect(throws: DMXError.self) { try SandboxMount.parse("/a:/b:/c") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The temporary directory is under /private (through /var/folders, a link into it).
        let m = try SandboxMount(host: dir.path, path: "/w", writable: true).resolved(shares: Share.defaults)
        #expect(m.host.hasPrefix("/private/"))
        #expect(throws: DMXError.self) { try SandboxMount(host: dir.path, path: "/w", writable: true).resolved(shares: [Share(path: "/private", readOnly: true)]) }
        #expect(throws: DMXError.self) { try SandboxMount(host: "/System", path: "/w", writable: false).resolved(shares: Share.defaults) }
        #expect(throws: DMXError.self) { try SandboxMount(host: dir.path + "/missing", path: "/w", writable: false).resolved(shares: Share.defaults) }
    }

    @Test func names() throws {
        try Sandboxes.checkName("build-1")
        try Sandboxes.checkName("a.b_c")
        for bad in ["", "Build", "-x", "a b", String(repeating: "a", count: 41), "a/b"] {
            #expect(throws: DMXError.self) { try Sandboxes.checkName(bad) }
        }
    }

    @Test func imageReferences() {
        #expect(Sandboxes.imageForCreate("alpine:3.24@sha256:abc") == "alpine@sha256:abc")
        #expect(Sandboxes.imageForCreate("localhost:5000/x@sha256:abc") == "localhost:5000/x@sha256:abc")
        #expect(Sandboxes.imageForCreate("alpine:3.24") == "alpine:3.24")
    }

    @Test func multiplexedStreamInPieces() {
        func frame(_ stream: UInt8, _ s: String) -> Data {
            let n = s.utf8.count
            return Data([stream, 0, 0, 0, UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]) + Data(s.utf8)
        }
        let all = frame(1, "hello ") + frame(2, "oops\n") + frame(1, "world\n")
        // Fed one byte at a time, the pieces still add up to each stream's bytes.
        var frames = DockerFrames()
        var out = Data(), err = Data()
        for byte in all {
            for (s, d) in frames.feed(Data([byte])) { if s == 2 { err += d } else { out += d } }
        }
        #expect(String(decoding: out, as: UTF8.self) == "hello world\n")
        #expect(String(decoding: err, as: UTF8.self) == "oops\n")
    }

    @Test func logSummary() {
        let reader = LogReader(limit: 64)
        var text = ""
        for i in 1...30 { text += i % 3 == 0 ? "step \(i) failed: no space\n" : "step \(i) ok\n" }
        // Split mid-line: lines are counted across pieces.
        let bytes = Data(text.utf8)
        reader.append(1, bytes.prefix(37))
        reader.append(1, bytes.dropFirst(37))
        reader.append(2, Data("panic: boom".utf8))
        let s = reader.summary()
        #expect(s.stdoutLines == 30 && s.stderrLines == 1)
        #expect(s.errorLines == 11)
        #expect(s.errors.count == 11)
        #expect(s.errors.first?.text == "step 3 failed: no space" && s.errors.first?.line == 3)
        #expect(s.errors.last?.stream == "stderr" && s.errors.last?.text == "panic: boom")
        #expect(reader.out.total == bytes.count)
        #expect(!LogReader.looksLikeError("all good, 0 warnings"))
        #expect(LogReader.looksLikeError("Traceback (most recent call last):"))
    }

    @Test func since() throws {
        #expect(try Sandboxes.parseSince("1700000000") == "1700000000")
        let tenMinutes = Int(try Sandboxes.parseSince("10m"))!
        #expect(abs(tenMinutes - (Int(Date().timeIntervalSince1970) - 600)) <= 1)
        #expect(try Sandboxes.parseSince("2026-10-24T12:00:00Z") == "1792843200")
        #expect(throws: DMXError.self) { try Sandboxes.parseSince("yesterday") }
    }
}
