import Foundation
import Testing
@testable import DMXCore

@Suite struct RotatingLogTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func retainsNewestBytesAndBoundsOldFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("console.log")
        let old = Data((0..<10_000).map { UInt8($0 % 251) })
        for suffix in ["", ".1", ".2"] {
            try old.write(to: URL(fileURLWithPath: path.path + suffix))
        }
        let log = try RotatingLog(url: path, limit: 64)
        for suffix in ["", ".1", ".2"] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path.path + suffix)) == old.suffix(64))
        }
        let bytes = Data((0..<1003).map { UInt8($0 % 251) })
        log.append(bytes.prefix(17))
        log.append(bytes.dropFirst(17))
        let retained = try [".2", ".1", ""].reduce(into: Data()) { result, suffix in
            let file = try Data(contentsOf: URL(fileURLWithPath: path.path + suffix))
            #expect(file.count <= 64)
            result.append(file)
        }
        #expect(retained == bytes.suffix(retained.count))
        // Reopening must append rather than overwrite the start of the existing file.
        let before = try Data(contentsOf: path)
        let reopened = try RotatingLog(url: path, limit: 64)
        reopened.append(Data("END".utf8))
        #expect(try Data(contentsOf: path) == before + Data("END".utf8))
    }

    @Test func concurrentConsoleWritersDoNotInterleaveRecords() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("console.log")
        let log = try RotatingLog(url: path, limit: 1023)
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            log.append(Data(String(format: "%07d\n", i).utf8))
        }
        let retained = try [".2", ".1", ""].reduce(into: Data()) { result, suffix in
            let file = try Data(contentsOf: URL(fileURLWithPath: path.path + suffix))
            #expect(file.count <= 1023)
            result.append(file)
        }
        // The retained prefix may start within a record. All complete records must remain
        // intact across rotations whose limits deliberately do not align with record length.
        let lines = String(decoding: retained, as: UTF8.self).split(separator: "\n").dropFirst()
        #expect(lines.count > 300)
        #expect(lines.allSatisfy { $0.count == 7 && Int($0).map { (0..<1000).contains($0) } == true })
        #expect(Set(lines).count == lines.count)
    }

    @Test func failedRotationDropsOutputAndRetriesAfterPermissionsRecover() throws {
        let dir = try directory()
        defer {
            _ = chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let path = dir.appendingPathComponent("daemon.log")
        let log = try RotatingLog(url: path, limit: 64)
        log.append(Data(repeating: 97, count: 64))
        #expect(chmod(dir.path, 0o500) == 0)
        log.append(Data(repeating: 98, count: 1000))
        #expect(try Data(contentsOf: path) == Data(repeating: 97, count: 64))
        #expect(chmod(dir.path, 0o700) == 0)
        log.append(Data("RECOVERED".utf8))
        #expect(try Data(contentsOf: path) == Data("RECOVERED".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path.path + ".1")) == Data(repeating: 97, count: 64))
    }

    @Test func rejectsLinksAndSpecialFilesWithoutChangingTargets() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("keep")
        let log = dir.appendingPathComponent("daemon.log")
        let saved = Data(repeating: 42, count: 1000)
        try saved.write(to: target)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)
        #expect(throws: DMXError.self) { try RotatingLog(url: log, limit: 64) }
        try FileManager.default.removeItem(at: log)
        #expect(link(target.path, log.path) == 0)
        #expect(throws: DMXError.self) { try RotatingLog(url: log, limit: 64) }
        #expect(try Data(contentsOf: target) == saved)
        try FileManager.default.removeItem(at: log)
        #expect(mkfifo(log.path, 0o600) == 0)
        #expect(throws: DMXError.self) { try RotatingLog(url: log, limit: 64) }
    }
}
