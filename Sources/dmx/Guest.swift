import ArgumentParser
import DMXCore
import Foundation

struct GuestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guest",
        abstract: "Show or download the Linux guest (kernel, initramfs, Docker image).",
        discussion: """
            A released dmx knows the sha256 of the guest it was released with and downloads it into
            ~/.dmx/guest on the first boot, or after an upgrade. The release_url setting (or
            DMX_RELEASE_URL) replaces the base
            URL (default \(GuestRelease.defaultBaseURL); files are <base>/<tag>/<archive>).
            A guest built from source with `make guest` is never replaced unless --force is given.
            """,
        subcommands: [Status.self, Fetch.self],
        defaultSubcommand: Status.self
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Where the guest came from and whether the next boot downloads one.")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            try await report(global) {
                let store = GuestStore(paths: Paths())
                let state = store.state()
                let url = store.pin.flatMap(store.url(of:))?.absoluteString
                var text: String
                switch state.source {
                case .missing: text = "no guest in \(state.path)"
                case .local: text = "guest built locally (kernel \(state.kernel ?? "?")) in \(state.path)"
                case .release: text = "guest from release \(state.tag ?? "?") (kernel \(state.kernel ?? "?")) in \(state.path)"
                }
                if state.needsFetch, let url { text += "\nthe next boot downloads \(state.pinnedTag ?? "?") from \(url)" }
                if store.pin == nil { text += "\nthis dmx has no pinned guest release; `make guest` builds one" }
                return (GuestStatusReport(guest: state, pinned: store.pin, url: url), text, true)
            }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and verify the guest this dmx was released with, if needed.")
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Download even if the guest is current or was built locally, replacing it.") var force = false

        @MainActor
        func run() async throws {
            let quiet = global.json
            try await report(global) {
                let result = try await GuestStore(paths: Paths()).fetch(force: force) { message in
                    if !quiet { FileHandle.standardError.write(Data("dmx: \(message)\n".utf8)) }
                }
                let g = result.guest
                let text = result.fetched
                    ? "guest \(g.tag ?? "?") ready in \(g.path)"
                    : "guest already in place (\(g.source == .local ? "built locally; --force replaces it" : "release \(g.tag ?? "?")"))"
                return (GuestFetchResult(fetched: result.fetched, url: result.url, bytes: result.bytes, ms: result.ms, guest: g), text, true)
            }
        }
    }
}

struct GuestStatusReport: Encodable {
    let ok = true
    let guest: GuestState
    let pinned: GuestRelease?
    let url: String?
}

struct GuestFetchResult: Encodable {
    let ok = true
    let fetched: Bool
    let url: String?
    let bytes: Int?
    let ms: Int?
    let guest: GuestState
}
