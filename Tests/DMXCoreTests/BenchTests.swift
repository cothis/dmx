import Foundation
import Testing
@testable import DMXCore

/// `dmx bench` without engines: reading --engine, refusing what would measure the wrong thing,
/// and the SVG it draws.
@Suite struct BenchTests {
    @Test func readsAnEngineSpec() throws {
        let spec = try Bench.EngineSpec(parsing: "orbstack=unix:///Users/me/.orbstack/run/docker.sock,812,77,812")
        #expect(spec.name == "orbstack")
        #expect(spec.socket.path == "/Users/me/.orbstack/run/docker.sock")
        #expect(spec.pids == [77, 812])
    }

    @Test(arguments: ["orbstack", "=unix:///s,1", "dmx=unix:///s,1", "a b=unix:///s,1", "x=/tmp/s,1",
                      "x=unix:///s", "x=unix:///s,abc", "x=unix:///s,1,-2"])
    func rejectsABadEngineSpec(_ text: String) {
        #expect(throws: DMXError.self) { try Bench.EngineSpec(parsing: text) }
        do { _ = try Bench.EngineSpec(parsing: text) } catch let error as DMXError {
            #expect(error.code == "bad_engine_spec")
            #expect(error.hint != nil)
        } catch {}
    }

    @Test func refusesDmxsOwnSocketAndMissingProcessesBeforeMeasuring() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(environment: ["DMX_HOME": root.path])
        var options = Bench.Options()

        // No docker CLI: say how to get it.
        await #expect { try await Bench.run(paths: paths, options: options, progress: { _ in }) } throws: {
            ($0 as? DMXError)?.code == "docker_tools_missing"
        }
        try FileManager.default.createDirectory(at: paths.dockerBin, withIntermediateDirectories: true)
        let docker = paths.dockerBin.appendingPathComponent("docker")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: docker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        // Docker Desktop's path linked to dmx (what `dmx install` does) is still dmx.
        let link = root.appendingPathComponent("desktop.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.dockerSocket)
        options.engines = [Bench.EngineSpec(name: "desktop", socket: link, pids: [getpid()])]
        await #expect { try await Bench.run(paths: paths, options: options, progress: { _ in }) } throws: {
            ($0 as? DMXError)?.code == "bad_engine_spec" && ($0 as? DMXError)?.message.contains("dmx's own socket") == true
        }

        options.engines = [Bench.EngineSpec(name: "gone", socket: root.appendingPathComponent("other.sock"), pids: [Int32.max - 1])]
        await #expect { try await Bench.run(paths: paths, options: options, progress: { _ in }) } throws: {
            ($0 as? DMXError)?.code == "bad_engine_spec" && ($0 as? DMXError)?.message.contains("no process") == true
        }

        let twice = Bench.EngineSpec(name: "a", socket: root.appendingPathComponent("a.sock"), pids: [getpid()])
        options.engines = [twice, twice]
        await #expect { try await Bench.run(paths: paths, options: options, progress: { _ in }) } throws: {
            ($0 as? DMXError)?.message.contains("named twice") == true
        }
    }

    @Test func readsThisProcessesFootprintAndCPU() throws {
        let usage = try #require(Bench.footprint(getpid()))
        #expect(usage.mb > 1)
        #expect(usage.cpuS > 0)
        #expect(Bench.footprint(Int32.max - 1) == nil)
        #expect(Bench.median([3, 1, 2]) == 2)
        #expect(Bench.median([4, 1, 3, 2]) == 2.5)
    }

    @Test func drawsOneLinePerEngineAsValidSVG() throws {
        func engine(_ name: String, _ base: Double) -> Bench.EngineReport {
            var e = Bench.EngineReport(name: name, socket: "/s")
            let timeline = stride(from: -6.0, through: 30.0, by: 0.1).map {
                Bench.Sample(atS: ($0 * 10).rounded() / 10, footprintMb: $0 < -4 || $0 > 2 ? base : base + 2048)
            }
            e.takeAndFree = Bench.TakeAndFree(baselineMb: base, holdingMb: base + 2048, peakMb: base + 2050,
                                              afterTenSecondsMb: base, afterEndMb: base, backToBaselineS: 2, timeline: timeline)
            e.ok = true
            return e
        }
        var report = Bench.Report(at: "2026-11-20T00:00:00Z", host: Bench.Host(macos: "x", cores: 1, memoryGb: 1, loadStart: 0),
                                  image: Bench.image)
        report.engines = [engine("dmx", 300), engine("a<b&c", 2400)]
        let svg = Bench.svg(report)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(svg.components(separatedBy: "<polyline").count == 3)
        #expect(svg.contains("a&lt;b&amp;c 2400 MB"))
        #expect(svg.contains("prefers-color-scheme: dark"))

        report.engines = [engine("dmx", 300)]
        let single = Bench.svg(report)
        #expect(XMLParser(data: Data(single.utf8)).parse())
        #expect(!single.contains("<rect class=\"k1\" x=\"64.0\" y=\"64\""), "one engine needs no legend")
    }
}
