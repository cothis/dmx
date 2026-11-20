import Foundation

/// `dmx import`: brings images, volumes with their data, user networks and container
/// definitions over from another engine (Docker Desktop, OrbStack, Colima, Rancher Desktop)
/// through its Docker socket. Nothing on the other engine is changed: images go through
/// `docker save | docker load`, volume data through `docker cp` between two helper containers
/// that are created and never started. Containers are created in dmx but not started, so
/// their ports do not fight the other engine's; Compose sees them as its own because the
/// labels come along. What dmx already has (a tag, a volume, a network or a container name)
/// is left alone, so a second run picks up only what is missing.
public enum Import {
    public struct Options: Sendable {
        /// An engine name (`docker-desktop`, `orbstack`, `colima`, `rancher-desktop`) or
        /// `unix:///path/to/docker.sock`; nil looks for the one engine that answers.
        public var from: String?
        /// Only these Compose projects: their containers, the images and volumes they use, and
        /// volumes and networks labelled with the project.
        public var projects: [String] = []
        public var dryRun = false
        public init() {}
    }

    public struct Source: Encodable, Sendable {
        public let name: String
        public let socket: String
        public var serverVersion: String?
        public var architecture: String?
    }

    public struct Item: Encodable, Sendable {
        public let kind: String
        public let name: String
        /// `imported`, `planned` (dry run), `exists` (dmx has it; left alone), `skipped` or `failed`.
        public var action: String
        public var detail: String?
    }

    public struct Report: Encodable, Sendable {
        public var ok = false
        public var dryRun: Bool
        public var source: Source
        public var projects: [String]
        public var items: [Item] = []
        public var warnings: [String] = []
        /// The command to run next, for people and agents.
        public var next: String?
    }

    /// Where each engine keeps its Docker socket, under the user's home.
    public static let knownEngines: [(name: String, path: String)] = [
        ("docker-desktop", ".docker/run/docker.sock"),
        ("orbstack", ".orbstack/run/docker.sock"),
        ("colima", ".colima/default/docker.sock"),
        ("rancher-desktop", ".rd/docker.sock"),
    ]

    static let helperMount = "/dmx-import"

    // MARK: - Choosing the source

    static func resolveSource(_ from: String?, paths: Paths, home: URL) async throws -> (name: String, socket: URL) {
        let dmx = Bench.canonical(paths.dockerSocket)
        let names = knownEngines.map(\.name).joined(separator: ", ")
        if let from {
            let candidate: (String, URL)
            if from.hasPrefix("unix:///") {
                candidate = (from, URL(fileURLWithPath: String(from.dropFirst("unix://".count))))
            } else if let known = knownEngines.first(where: { $0.name == from.lowercased() }) {
                candidate = (known.name, home.appendingPathComponent(known.path))
            } else {
                throw DMXError("import_bad_source", "\"\(from)\" is not an engine dmx knows",
                               hint: "pass --from with one of \(names), or unix:///path/to/docker.sock")
            }
            guard Bench.canonical(candidate.1) != dmx else {
                throw DMXError("import_bad_source", "\(candidate.1.path) is dmx's own socket",
                               hint: "pass --from the other engine's socket, for example --from colima")
            }
            guard await answers(candidate.1) else {
                throw DMXError("import_source_unreachable", "no Docker engine answers at \(candidate.1.path)",
                               hint: "start \(candidate.0) first, then run `dmx import --from \(from)` again")
            }
            return candidate
        }
        var seen = Set<String>([dmx])
        var live: [(String, URL)] = []
        for engine in knownEngines {
            let url = home.appendingPathComponent(engine.path)
            guard seen.insert(Bench.canonical(url)).inserted else { continue }
            if await answers(url) { live.append((engine.name, url)) }
        }
        guard let first = live.first else {
            throw DMXError("import_no_source", "no other engine answers at its usual socket (\(names))",
                           hint: "start the engine to import from, or pass --from unix:///path/to/docker.sock")
        }
        guard live.count == 1 else {
            throw DMXError("import_ambiguous_source", "more than one engine answers: \(live.map(\.0).joined(separator: ", "))",
                           hint: "pick one with `dmx import --from \(live[0].0)`")
        }
        return first
    }

    static func answers(_ socket: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: socket.path) else { return false }
        let api = DockerAPI.unix(socket, timeoutSeconds: 5, apiVersion: "")
        return (try? await api.call("GET", "/_ping").status) == 200
    }

    // MARK: - Running

    public static func run(paths: Paths, options: Options, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           progress: @escaping @Sendable (String) -> Void) async throws -> Report {
        let docker = paths.dockerBin.appendingPathComponent("docker")
        guard FileManager.default.isExecutableFile(atPath: docker.path) else {
            throw DMXError("docker_tools_missing", "dmx import moves images and volume data with dmx's docker CLI, which is not installed",
                           hint: "run `dmx tools install`, then `dmx import` again")
        }
        let (sourceName, sourceSocket) = try await resolveSource(options.from, paths: paths, home: home)
        let src = DockerAPI.unix(sourceSocket, timeoutSeconds: 120, apiVersion: "")
        let dst = DockerAPI.host(paths, timeoutSeconds: 120)
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-import-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }
        let srcCLI = DockerCLI(docker: docker, socket: sourceSocket, config: config)
        let dstCLI = DockerCLI(docker: docker, socket: paths.dockerSocket, config: config)

        progress("reading \(sourceName) (\(sourceSocket.path))")
        let srcInfo = try await src.json("GET", "/info", code: "import_source_failed")
        var report = Report(dryRun: options.dryRun,
                            source: Source(name: sourceName, socket: sourceSocket.path,
                                           serverVersion: srcInfo["ServerVersion"]?.string, architecture: srcInfo["Architecture"]?.string),
                            projects: options.projects)
        let source = try await Inventory.read(src)
        let selection = try Selection(source, projects: options.projects)
        // A dry run reads dmx only if its VM is up: booting it would start dockerd and, by their
        // restart policies, containers.
        var dstInfo: JSONValue = .null
        var target = Inventory()
        var dmxRunning = true
        if options.dryRun {
            let client = try await DaemonClient.connect(paths: paths, start: false)
            dmxRunning = (try? await client?.status(timeout: .seconds(10)).state) == "running"
            client?.close()
        }
        if dmxRunning {
            progress("dmx: reading what it has")
            dstInfo = try await dst.json("GET", "/info")
            target = try await Inventory.read(dst)
        } else {
            report.warnings.append("dmx is stopped and a dry run does not start it, so this plan does not know what dmx has already; "
                                   + "`dmx start`, then `dmx import --dry-run` again, to see what would be left alone")
        }
        let shares = (try? Config.load(paths).shareList) ?? Share.defaults

        var run = Runner(src: src, dst: dst, srcCLI: srcCLI, dstCLI: dstCLI, sourceName: sourceName, dryRun: options.dryRun,
                         progress: progress)
        if !options.dryRun { await run.removeStaleHelpers() }
        for image in selection.images { report.items.append(await run.image(image, target: &target)) }
        for volume in selection.volumes {
            report.items.append(await run.volume(volume, source: source, target: &target, selection: selection))
        }
        for network in selection.networks { report.items.append(await run.network(network, selection: selection, target: &target)) }
        let runtimes = Set(dstInfo["Runtimes"]?.object?.keys.map { $0 } ?? [])
        for container in selection.orderedContainers {
            report.items.append(contentsOf: await run.container(container, source: source, selection: selection, target: &target,
                                                                runtimes: runtimes, shares: shares))
        }
        await run.cleanUp()
        report.warnings += run.warnings
        report.ok = !report.items.contains { $0.action == "failed" }
        report.next = nextStep(report, selection: selection)
        return report
    }

    static func nextStep(_ report: Report, selection: Selection) -> String? {
        if report.dryRun { return "dmx import --from \(report.source.name)" + report.projects.map { " --project \($0)" }.joined() }
        if !report.ok { return "dmx import --from \(report.source.name) again after fixing the failures; what dmx has is kept" }
        let projects = Set(selection.containers.compactMap { $0.labels["com.docker.compose.project"] }).sorted()
        if !projects.isEmpty {
            return "stop them in \(report.source.name), then `docker compose -p \(projects[0]) up -d` in the project's directory"
        }
        if let c = selection.containers.first { return "docker start \(c.name)" }
        return nil
    }
}

// MARK: - What an engine has

extension Import {
    struct Image: Sendable {
        let id: String
        let tags: [String]
        /// `repo@sha256:...` names it was pulled by.
        let digests: [String]
        let size: Int
    }

    struct Volume: Sendable {
        let name: String
        let driver: String
        let labels: [String: String]
        let options: [String: String]
        var anonymous: Bool { labels["com.docker.volume.anonymous"] != nil || Import.looksAnonymous(name) }
    }

    struct Network: Sendable {
        let name: String
        let id: String
        let driver: String
        let labels: [String: String]
        let raw: JSONValue
    }

    struct Container: Sendable {
        let id: String
        let name: String
        let imageID: String
        let running: Bool
        let labels: [String: String]
        let inspect: JSONValue

        var hostConfig: [String: JSONValue] { inspect["HostConfig"]?.object ?? [:] }
        var networks: [String: JSONValue] { inspect["NetworkSettings"]?["Networks"]?.object ?? [:] }
        var mounts: [JSONValue] { inspect["Mounts"]?.array ?? [] }
        var volumeNames: [String] { mounts.filter { $0["Type"]?.string == "volume" }.compactMap { $0["Name"]?.string } }
        var networkMode: String { hostConfig["NetworkMode"]?.string ?? "default" }
    }

    struct Inventory: Sendable {
        var images: [Image] = []
        var tags: [String: String] = [:]
        var volumes: [Volume] = []
        var networks: [Network] = []
        var containers: [Container] = []

        static func read(_ api: DockerAPI) async throws -> Inventory {
            var inv = Inventory()
            for i in try await api.json("GET", "/images/json").array ?? [] {
                guard let id = i["Id"]?.string else { continue }
                // The containerd store lists `alpine@sha256:...` among the tags of an image pulled by
                // digest; `docker load` cannot bring that name back, a pull can.
                let names = (i["RepoTags"]?.array ?? []).compactMap(\.string).filter { $0 != "<none>:<none>" }
                let tags = names.filter { !$0.contains("@") }
                let digests = Array(Set(names.filter { $0.contains("@") }
                    + (i["RepoDigests"]?.array ?? []).compactMap(\.string).filter { !$0.hasPrefix("<none>@") })).sorted()
                inv.images.append(Image(id: id, tags: tags, digests: digests, size: i["Size"]?.int ?? 0))
                for tag in tags { inv.tags[tag] = id }
            }
            for v in try await api.json("GET", "/volumes")["Volumes"]?.array ?? [] {
                guard let name = v["Name"]?.string else { continue }
                inv.volumes.append(Volume(name: name, driver: v["Driver"]?.string ?? "local",
                                          labels: strings(v["Labels"]), options: strings(v["Options"])))
            }
            for n in try await api.json("GET", "/networks").array ?? [] {
                guard let name = n["Name"]?.string else { continue }
                inv.networks.append(Network(name: name, id: n["Id"]?.string ?? "", driver: n["Driver"]?.string ?? "",
                                            labels: strings(n["Labels"]), raw: n))
            }
            for c in try await api.json("GET", "/containers/json?all=1").array ?? [] {
                guard let id = c["Id"]?.string else { continue }
                let i = try await api.json("GET", "/containers/\(id)/json")
                inv.containers.append(Container(id: id, name: String((i["Name"]?.string ?? id).drop { $0 == "/" }),
                                                imageID: i["Image"]?.string ?? "", running: i["State"]?["Running"]?.bool ?? false,
                                                labels: strings(i["Config"]?["Labels"]), inspect: i))
            }
            return inv
        }
    }

    static func strings(_ value: JSONValue?) -> [String: String] {
        (value?.object ?? [:]).compactMapValues(\.string)
    }

    /// Docker names an anonymous volume with 64 hex digits.
    static func looksAnonymous(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }

    static let predefinedNetworks: Set<String> = ["bridge", "host", "none"]

    /// What to bring over, in the order it has to be created.
    struct Selection: Sendable {
        var images: [Image] = []
        var volumes: [Volume] = []
        var networks: [Network] = []
        var containers: [Container] = []

        init(_ source: Inventory, projects: [String]) throws {
            let project = "com.docker.compose.project"
            if projects.isEmpty {
                containers = source.containers
            } else {
                let wanted = Set(projects)
                containers = source.containers.filter { $0.labels[project].map(wanted.contains) ?? false }
                let found = Set(source.containers.compactMap { $0.labels[project] }).union(source.volumes.compactMap { $0.labels[project] })
                guard wanted.isSubset(of: found) else {
                    throw DMXError("import_no_project", "the source has no Compose project named \(wanted.subtracting(found).sorted().joined(separator: ", "))",
                                   hint: found.isEmpty ? "the source has no Compose projects; run `dmx import` without --project"
                                       : "pick from \(found.sorted().joined(separator: ", ")) with --project")
                }
            }
            let usedImages = Set(containers.map(\.imageID))
            images = source.images.filter { projects.isEmpty ? (!$0.tags.isEmpty || usedImages.contains($0.id)) : usedImages.contains($0.id) }
            let usedVolumes = Set(containers.flatMap(\.volumeNames))
            // Anonymous volumes go with their containers (Runner.container).
            volumes = source.volumes.filter {
                !$0.anonymous && (usedVolumes.contains($0.name) || projects.isEmpty || $0.labels[project].map(projects.contains) ?? false)
            }
            let usedNetworks = Set(containers.flatMap { $0.networks.keys })
            networks = source.networks.filter {
                !predefinedNetworks.contains($0.name)
                    && (usedNetworks.contains($0.name) || (projects.isEmpty ? true : $0.labels[project].map(projects.contains) ?? false))
            }
        }

        /// Containers after the ones they name in `--network container:`, `--volumes-from` and links.
        var orderedContainers: [Container] {
            let byName = Dictionary(containers.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var done = Set<String>(), out: [Container] = []
            func visit(_ c: Container, _ depth: Int) {
                guard !done.contains(c.name), depth < 32 else { return }
                done.insert(c.name)
                for dep in Import.dependencies(c, containers: containers) { if let d = byName[dep] { visit(d, depth + 1) } }
                out.append(c)
            }
            // The insert before visiting dependencies breaks cycles; dependencies still land first.
            for c in containers { visit(c, 0) }
            return out
        }
    }

    /// Names of other containers a container refers to.
    static func dependencies(_ c: Container, containers: [Container]) -> [String] {
        var names: [String] = []
        for mode in [c.networkMode, c.hostConfig["IpcMode"]?.string ?? "", c.hostConfig["PidMode"]?.string ?? ""]
        where mode.hasPrefix("container:") {
            names.append(containerName(String(mode.dropFirst("container:".count)), containers))
        }
        for from in c.hostConfig["VolumesFrom"]?.array?.compactMap(\.string) ?? [] {
            names.append(containerName(String(from.split(separator: ":").first ?? ""), containers))
        }
        for link in c.hostConfig["Links"]?.array?.compactMap(\.string) ?? [] {
            names.append(String(link.split(separator: ":").first?.drop { $0 == "/" } ?? ""))
        }
        return names.filter { !$0.isEmpty }
    }

    /// A container named by ID (full or a prefix of at least 12) or by name, as its name.
    static func containerName(_ ref: String, _ containers: [Container]) -> String {
        let r = ref.hasPrefix("/") ? String(ref.dropFirst()) : ref
        if r.count >= 12, let c = containers.first(where: { $0.id.hasPrefix(r) }) { return c.name }
        return r
    }
}

// MARK: - Bringing it over

extension Import {
    struct Runner {
        let src: DockerAPI
        let dst: DockerAPI
        let srcCLI: DockerCLI
        let dstCLI: DockerCLI
        let sourceName: String
        let dryRun: Bool
        let progress: @Sendable (String) -> Void
        var warnings: [String] = []
        /// Source image ID to the ID of the same image in dmx.
        var imageMap: [String: String] = [:]
        var filledAnonymous = Set<String>()
        /// Containers created in this run, by name.
        var targetIDs: [String: String] = [:]
        var helperImages: (src: String?, dst: String?) = (nil, nil)
        /// This run's helpers only, so a run never removes another one's. The value starts with
        /// the pid, so a later run can tell the helpers of an interrupted one.
        let helperValue = "\(getpid())-\(UUID().uuidString.prefix(8))"
        var helperLabel: String { "\(Import.helperKey)=\(helperValue)" }
        /// Images this run pulled into the source to read its volumes, removed again at the end.
        var pulledIntoSource: [String] = []
        /// Volumes whose data did not come over (failed or skipped): containers using them are not created.
        var missingVolumes: [String: String] = [:]

        init(src: DockerAPI, dst: DockerAPI, srcCLI: DockerCLI, dstCLI: DockerCLI, sourceName: String, dryRun: Bool,
             progress: @escaping @Sendable (String) -> Void) {
            self.src = src
            self.dst = dst
            self.srcCLI = srcCLI
            self.dstCLI = dstCLI
            self.sourceName = sourceName
            self.dryRun = dryRun
            self.progress = progress
        }

        mutating func image(_ image: Image, target: inout Inventory) async -> Item {
            let name = image.tags.isEmpty ? image.digests.first ?? Import.shortID(image.id) : image.tags.joined(separator: ", ")
            var item = Item(kind: "image", name: name, action: "imported", detail: Import.megabytes(image.size))
            // The names go to the docker CLI as arguments; a source could send anything.
            guard (image.tags + image.digests + [image.id]).allSatisfy(Import.validReference) else {
                item.action = "skipped"
                item.detail = "not a reference Docker gives an image"
                return item
            }
            let missing = image.tags.filter { target.tags[$0] == nil }
            let other = image.tags.filter { target.tags[$0].map { $0 != image.id } ?? false }
            if !other.isEmpty {
                // Image IDs are the same in both engines when both use the same image store.
                warnings.append("dmx's \(other.joined(separator: ", ")) is not the image \(sourceName) has under that name (\(Import.shortID(image.id))); "
                                + "containers imported with it use dmx's. To use \(sourceName)'s, `docker rmi` it in dmx and import again")
            }
            if !image.tags.isEmpty && missing.isEmpty {
                item.action = "exists"
                if let id = target.tags[image.tags[0]] { imageMap[image.id] = id }
                return item
            }
            // Untagged but pulled by digest (`image: alpine@sha256:...`): the same digest from the
            // registry is the same image, and keeps the name containers refer to it by. A load
            // would bring the bytes without that name.
            if image.tags.isEmpty, let digest = image.digests.first {
                if let id = try? await dst.json("GET", "/images/\(digest)/json")["Id"]?.string {
                    imageMap[image.id] = id
                    item.action = "exists"
                    return item
                }
                if dryRun { item.action = "planned"; return item }
                progress("image \(digest): pulling it by digest")
                if (try? await dstCLI.run(["pull", "--quiet", "--", digest], timeout: 1800)) != nil,
                   let id = try? await dst.json("GET", "/images/\(digest)/json")["Id"]?.string {
                    imageMap[image.id] = id
                    item.detail = (item.detail ?? "") + ", pulled by digest"
                    return item
                }
            }
            if dryRun { item.action = "planned"; return item }
            progress("image \(name): copying \(Import.megabytes(image.size))")
            let refs = image.tags.isEmpty ? [image.id] : missing
            do {
                var output: String
                do {
                    output = try await DockerCLI.pipe(srcCLI, ["save", "--"] + refs, into: dstCLI, ["load"], timeout: 3600)
                } catch {
                    // An image from a multi-platform index whose other platforms were never pulled:
                    // the containerd store cannot export what it lacks, so ask for the one it has.
                    // If that fails too (an older dockerd has no --platform), the first error is the one to see.
                    guard let platform = try? await Import.platform(of: image.id, src),
                          Import.validReference(platform),
                          let retried = try? await DockerCLI.pipe(srcCLI, ["save", "--platform", platform, "--"] + refs, into: dstCLI, ["load"], timeout: 3600)
                    else { throw error }
                    output = retried
                }
                if let tag = missing.first, let id = try? await dst.json("GET", "/images/\(tag)/json")["Id"]?.string {
                    imageMap[image.id] = id
                } else if let id = output.components(separatedBy: "Loaded image ID: ").dropFirst().first?
                    .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first {
                    imageMap[image.id] = String(id)
                }
                for tag in missing { target.tags[tag] = imageMap[image.id] ?? image.id }
                if missing.count < image.tags.count {
                    item.detail = (item.detail ?? "") + "; dmx already had \(image.tags.filter { !missing.contains($0) }.joined(separator: ", "))"
                }
            } catch {
                item.action = "failed"
                item.detail = Import.message(error)
            }
            return item
        }

        mutating func volume(_ volume: Volume, source: Inventory, target: inout Inventory, selection: Selection) async -> Item {
            var item = Item(kind: "volume", name: volume.name, action: "imported")
            guard Import.validName(volume.name) else {
                item.action = "skipped"
                item.detail = "not a name Docker gives a volume"
                missingVolumes[volume.name] = "its volume \(volume.name) has a name Docker does not give volumes"
                return item
            }
            if target.volumes.contains(where: { $0.name == volume.name }) {
                item.action = "exists"
                item.detail = "dmx has a volume of this name; its data was left alone"
                return item
            }
            guard volume.driver == "local", volume.options.isEmpty else {
                item.action = "skipped"
                item.detail = volume.driver != "local" ? "driver \(volume.driver) is not dmx's"
                    : "its options (\(volume.options.keys.sorted().joined(separator: ", "))) describe storage of \(sourceName)'s VM"
                missingVolumes[volume.name] = "its volume \(volume.name) was not imported (\(item.detail!))"
                return item
            }
            warnIfInUse(volume.name, source: source, redo: "`docker volume rm \(volume.name)` in dmx and import again")
            if dryRun { item.action = "planned"; return item }
            progress("volume \(volume.name): copying its data")
            var created = false
            do {
                // dockerd answers a create for a name it has with that volume, so a volume made
                // since the listing (another import, Compose) is found here and left alone.
                if (try await dst.call("GET", "/volumes/\(volume.name)")).status != 404 {
                    item.action = "exists"
                    item.detail = "dmx has a volume of this name (made during the import); its data was left alone"
                    return item
                }
                _ = try await dst.json("POST", "/volumes/create", body: .object([
                    "Name": .string(volume.name), "Driver": "local", "Labels": .object(volume.labels.mapValues(JSONValue.string)),
                ]))
                created = true
                try await copyData(from: volume.name, into: volume.name)
                target.volumes.append(volume)
            } catch {
                item.action = "failed"
                item.detail = Import.message(error)
                missingVolumes[volume.name] = "its volume \(volume.name) could not be copied"
                if created { _ = try? await dst.call("DELETE", "/volumes/\(queryValue(volume.name))") }
            }
            return item
        }

        mutating func warnIfInUse(_ volume: String, source: Inventory, redo: String) {
            let users = source.containers.filter { $0.running && $0.volumeNames.contains(volume) }.map(\.name)
            guard !users.isEmpty else { return }
            warnings.append("volume \(volume) was copied while \(users.joined(separator: ", ")) ran in \(sourceName); "
                            + "for a consistent copy stop \(users.count == 1 ? "it" : "them") there, then \(redo)")
        }

        /// Copies a volume's files, owners and modes through a container on each side with the
        /// volume mounted, created and never started, so `docker cp` reads and writes the volume
        /// without running anything. Any image will do: the smallest one each engine has, or the
        /// pinned alpine pulled if it has none. The helpers go before it returns or throws, so a
        /// caller can delete a half-filled volume.
        mutating func copyData(from sourceVolume: String, into targetVolume: String) async throws {
            if helperImages.src == nil { helperImages.src = try await helperImage(src, srcCLI, side: sourceName) }
            if helperImages.dst == nil { helperImages.dst = try await helperImage(dst, dstCLI, side: "dmx") }
            // volume-nocopy: an empty volume must not get the helper image's files at that path
            // (dockerd's copy-up), neither the source's nor dmx's.
            func create(_ cli: DockerCLI, _ image: String, _ volume: String, ro: Bool) async throws -> String {
                try await cli.run(["create", "--network", "none", "--entrypoint", helperMount, "--label", helperLabel,
                                   "--mount", "type=volume,src=\(volume),dst=\(helperMount),volume-nocopy\(ro ? ",readonly" : "")",
                                   "--", image], timeout: 120)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let s = try await create(srcCLI, helperImages.src!, sourceVolume, ro: true)
            var d: String?
            do {
                d = try await create(dstCLI, helperImages.dst!, targetVolume, ro: false)
                _ = try await DockerCLI.pipe(srcCLI, ["cp", "\(s):\(helperMount)", "-"], into: dstCLI, ["cp", "-a", "-", "\(d!):/"], timeout: 7200)
            } catch {
                _ = try? await src.call("DELETE", "/containers/\(s)?force=1&v=1")
                if let d { _ = try? await dst.call("DELETE", "/containers/\(d)?force=1&v=1") }
                throw error
            }
            // v=1 takes only volumes of the helper's own image; the mounted one is named. Both go
            // whatever the other did; one left behind is found by its label at the end.
            _ = try? await src.call("DELETE", "/containers/\(s)?force=1&v=1")
            _ = try? await dst.call("DELETE", "/containers/\(d!)?force=1&v=1")
        }

        mutating func helperImage(_ api: DockerAPI, _ cli: DockerCLI, side: String) async throws -> String {
            let images = try await api.json("GET", "/images/json").array ?? []
            if let smallest = images.filter({ $0["Id"]?.string != nil }).min(by: { ($0["Size"]?.int ?? 0) < ($1["Size"]?.int ?? 0) }),
               let id = smallest["Id"]?.string {
                return id
            }
            progress("\(side) has no image to read volumes with; pulling alpine")
            _ = try await cli.run(["pull", "--quiet", Bench.image], timeout: 600)
            // The source is left as it was: what was pulled there goes again at the end.
            if side != "dmx" { pulledIntoSource.append(Bench.image) }
            return Bench.image
        }

        mutating func network(_ network: Network, selection: Selection, target: inout Inventory) async -> Item {
            var item = Item(kind: "network", name: network.name, action: "imported")
            if target.networks.contains(where: { $0.name == network.name }) {
                item.action = "exists"
                return item
            }
            guard network.driver == "bridge" else {
                item.action = "skipped"
                item.detail = "driver \(network.driver); dmx imports bridge networks"
                return item
            }
            if dryRun { item.action = "planned"; return item }
            do {
                let body = Import.networkBody(network, selection: selection)
                _ = try await dst.json("POST", "/networks/create", body: body)
                target.networks.append(network)
            } catch {
                item.action = "failed"
                item.detail = Import.message(error)
            }
            return item
        }

        mutating func container(_ c: Container, source: Inventory, selection: Selection, target: inout Inventory,
                                runtimes: Set<String>, shares: [Share]) async -> [Item] {
            var item = Item(kind: "container", name: c.name, action: "imported", detail: c.running ? "running in \(sourceName); created here, not started" : "created, not started")
            if targetIDs[c.name] != nil || target.containers.contains(where: { $0.name == c.name }) {
                item.action = "exists"
                item.detail = "dmx has a container of this name"
                return [item]
            }
            for bind in Import.unsharedBinds(c, shares: shares) {
                warnings.append("\(c.name): \(bind) is a Mac path dmx does not share; add it with `dmx config set shares ...` before starting it")
            }
            guard Import.validName(c.name) else {
                item.action = "skipped"
                item.detail = "not a name Docker gives a container"
                return [item]
            }
            // Its data did not come over: created anyway, it would get an empty volume of that
            // name, and the next run would count it as imported.
            let missingVolumes = self.missingVolumes
            if let missing = c.volumeNames.compactMap({ missingVolumes[$0] }).first {
                item.action = "failed"
                item.detail = "not created: \(missing)"
                return [item]
            }
            let anonymous = Import.anonymousVolumes(c, containers: source.containers)
            if dryRun {
                item.action = "planned"
                return [item] + anonymous.map { Item(kind: "volume", name: $0.volume, action: "planned", detail: "anonymous, of \(c.name)") }
            }
            // By the name it was created with while that name still means its image (so `docker ps`
            // reads the same), else by the ID its image got in dmx.
            let configImage = c.inspect["Config"]?["Image"]?.string ?? c.imageID
            let image: String
            if (try? await src.json("GET", "/images/\(configImage)/json")["Id"]?.string) == c.imageID,
               (try? await dst.json("GET", "/images/\(configImage)/json")) != nil {
                image = configImage
            } else if let mapped = imageMap[c.imageID] {
                image = mapped
            } else {
                item.action = "failed"
                item.detail = "its image \(configImage) is not in dmx; import it first"
                return [item]
            }
            // dockerd keeps `container:NAME` as written while Compose expects the ID it would pass,
            // so references to other containers name them by their ID in dmx.
            let ids = targetIDs, existing = target.containers
            // Compose labels a container with its image's digest as it computes it, which differs
            // between the classic and the containerd image store for the same image. A label that
            // was current in the source is made current in dmx, so Compose does not recreate the
            // container; an outdated one stays outdated.
            var composeImage: String?
            if let label = c.labels["com.docker.compose.image"], label == (await Import.composeImageDigest(src, configImage)) {
                var dst148 = dst
                dst148.apiVersion = "v1.48"
                composeImage = await Import.composeImageDigest(dst148, image)
            }
            let body = Import.containerBody(c, image: image, composeImage: composeImage, containers: source.containers,
                                            runtimes: runtimes) { name in
                ids[name] ?? existing.first { $0.name == name }?.id
            }
            let created: JSONValue
            do {
                created = try await dst.json("POST", "/containers/create?name=\(queryValue(c.name))", body: body)
                targetIDs[c.name] = created["Id"]?.string
            } catch {
                item.action = "failed"
                item.detail = Import.message(error)
                return [item]
            }
            // dockerd made new anonymous volumes for the container; they get the old ones' files,
            // and stay anonymous, so `docker rm -v` and `compose down -v` remove them as before.
            guard !anonymous.isEmpty else { return [item] }
            var items = [item]
            var copied = true
            let mounts = (try? await dst.json("GET", "/containers/\(created["Id"]?.string ?? c.name)/json"))?["Mounts"]?.array ?? []
            for (dest, volume) in anonymous {
                var v = Item(kind: "volume", name: volume, action: "imported", detail: "anonymous, of \(c.name)")
                guard let new = mounts.first(where: { $0["Destination"]?.string == dest && $0["Type"]?.string == "volume" })?["Name"]?.string else {
                    v.action = "failed"
                    v.detail = "dmx made no volume at \(dest) for \(c.name)"
                    copied = false
                    items.append(v)
                    continue
                }
                guard filledAnonymous.insert(new).inserted else { continue }
                warnIfInUse(volume, source: source, redo: "remove \(c.name) with `docker rm -v` in dmx and import again")
                progress("volume \(volume) (anonymous, \(c.name) \(dest)): copying its data")
                do {
                    try await copyData(from: volume, into: new)
                    v.detail = "anonymous, of \(c.name), now \(Import.shortID(new))"
                } catch {
                    v.action = "failed"
                    v.detail = Import.message(error)
                    copied = false
                }
                items.append(v)
            }
            // A container with an empty anonymous volume would count as imported next time; take
            // it out with its volumes, so running the import again tries the whole of it.
            if !copied, let id = created["Id"]?.string {
                _ = try? await dst.call("DELETE", "/containers/\(id)?force=1&v=1")
                targetIDs[c.name] = nil
                items[0].action = "failed"
                items[0].detail = "removed again: an anonymous volume could not be copied"
            }
            return items
        }

        /// Helpers this run left behind (an error between create and removal), and what it pulled
        /// into the source.
        func cleanUp() async {
            guard !dryRun else { return }
            for api in [src, dst] { await Import.removeHelpers(api, label: helperLabel) }
            for image in pulledIntoSource { _ = try? await src.call("DELETE", "/images/\(image)?noprune=0") }
        }

        /// Helpers of earlier runs that did not finish (interrupted, or the engine went away):
        /// their pid in the label is no longer a process.
        func removeStaleHelpers() async {
            for api in [src, dst] {
                guard let list = try? await api.json("GET", "/containers/json?all=1&filters=\(queryValue("{\"label\":[\"\(Import.helperKey)\"]}"))").array else { continue }
                for c in list {
                    guard let id = c["Id"]?.string, let value = c["Labels"]?[Import.helperKey]?.string,
                          let pid = Int32(value.prefix { $0 != "-" }), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
                    _ = try? await api.call("DELETE", "/containers/\(id)?force=1&v=1")
                }
            }
        }
    }

    static func platform(of image: String, _ api: DockerAPI) async throws -> String? {
        let i = try await api.json("GET", "/images/\(image)/json")
        guard let os = i["Os"]?.string, let arch = i["Architecture"]?.string else { return nil }
        return [os, arch, i["Variant"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func shortID(_ id: String) -> String {
        String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    static func megabytes(_ bytes: Int) -> String {
        bytes >= 1 << 30 ? String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) : "\(max(1, bytes >> 20)) MB"
    }

    static func message(_ error: Error) -> String {
        (error as? DMXError)?.message ?? "\(error)"
    }

    /// The create request for a user network: its settings and labels (Compose finds its own
    /// networks by label). Subnets only when a container had a fixed address in one, because
    /// the other engine's automatic ranges may collide with dmx's.
    static func networkBody(_ n: Network, selection: Selection) -> JSONValue {
        var body: [String: JSONValue] = ["Name": .string(n.name), "Driver": "bridge",
                                         "Labels": .object(n.labels.mapValues(JSONValue.string))]
        for key in ["Internal", "Attachable", "EnableIPv6", "EnableIPv4"] { if let v = n.raw[key] { body[key] = v } }
        // The Linux bridge's name belongs to the other VM.
        let options = (n.raw["Options"]?.object ?? [:]).filter { $0.key != "com.docker.network.bridge.name" }
        if !options.isEmpty { body["Options"] = .object(options) }
        let fixed = selection.containers.contains { c in
            guard let ipam = c.networks[n.name]?["IPAMConfig"]?.object else { return false }
            return ipam.values.contains { ($0.string ?? "").isEmpty == false }
        }
        if fixed, let ipam = n.raw["IPAM"] { body["IPAM"] = ipam }
        return .object(body)
    }

    /// The create request for a container: its own Config and HostConfig as the source has
    /// them, with what belonged to the old container (its ID as hostname, its MAC, a runtime
    /// dmx lacks) taken out and references to other containers by ID turned into names.
    static func containerBody(_ c: Container, image: String, composeImage: String? = nil, containers: [Container],
                              runtimes: Set<String>, targetID: (String) -> String?) -> JSONValue {
        /// Another container, named by its ID in dmx when it is there.
        func ref(_ source: String) -> String {
            let name = containerName(source, containers)
            return targetID(name) ?? name
        }
        var config = c.inspect["Config"]?.object ?? [:]
        config["Image"] = .string(image)
        if let composeImage, var labels = config["Labels"]?.object {
            labels["com.docker.compose.image"] = .string(composeImage)
            config["Labels"] = .object(labels)
        }
        // A container in another's network namespace shows that one's names, and dockerd refuses
        // them on create.
        if c.networkMode.hasPrefix("container:") {
            config.removeValue(forKey: "Hostname")
            config.removeValue(forKey: "Domainname")
        } else if let host = config["Hostname"]?.string, c.id.hasPrefix(host) {
            config.removeValue(forKey: "Hostname")
        }
        config.removeValue(forKey: "MacAddress")

        var host = c.hostConfig
        if let runtime = host["Runtime"]?.string, !runtimes.isEmpty, !runtimes.contains(runtime) { host.removeValue(forKey: "Runtime") }
        let mode = c.networkMode
        for key in ["NetworkMode", "IpcMode", "PidMode"] {
            if let value = host[key]?.string, value.hasPrefix("container:") {
                host[key] = .string("container:" + ref(String(value.dropFirst("container:".count))))
            }
        }
        if let from = host["VolumesFrom"]?.array?.compactMap(\.string) {
            host["VolumesFrom"] = .array(from.filter { !$0.isEmpty }.map { entry in
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                return .string(([ref(parts[0])] + parts.dropFirst()).joined(separator: ":"))
            })
        }
        config["HostConfig"] = .object(host)

        if !(mode == "host" || mode == "none" || mode.hasPrefix("container:")) {
            var endpoints: [String: JSONValue] = [:]
            for (name, ep) in c.networks {
                var out: [String: JSONValue] = [:]
                let aliases = (ep["Aliases"]?.array ?? []).compactMap(\.string).filter { !c.id.hasPrefix($0) }
                if !aliases.isEmpty { out["Aliases"] = .array(aliases.map(JSONValue.string)) }
                if let ipam = ep["IPAMConfig"]?.object, ipam.values.contains(where: { ($0.string ?? "").isEmpty == false }) {
                    out["IPAMConfig"] = .object(ipam)
                }
                for key in ["Links", "DriverOpts"] { if let v = ep[key], v != .null { out[key] = v } }
                endpoints[name] = .object(out)
            }
            if !endpoints.isEmpty { config["NetworkingConfig"] = .object(["EndpointsConfig": .object(endpoints)]) }
        }
        return .object(config)
    }

    /// The container's volumes that have no name of their own (from the image's VOLUME, `-v /path`
    /// or a `--mount` without a source): mount point and the volume's name in the source.
    static func anonymousVolumes(_ c: Container, containers: [Container] = []) -> [(dest: String, volume: String)] {
        let host = c.hostConfig
        // `-v name:/path` and `-v /host:/path` name what is mounted; so does a --mount with a source.
        let named = Set((host["Binds"]?.array ?? []).compactMap(\.string).compactMap(bindTarget)
            + (host["Mounts"]?.array ?? []).filter { !($0["Source"]?.string ?? "").isEmpty }.compactMap { $0["Target"]?.string })
        // --volumes-from brings another container's volumes; that container owns them, the rest
        // are this one's. Unknown sources (not listed) leave nothing to tell them apart by.
        let from = (host["VolumesFrom"]?.array ?? []).compactMap(\.string).map { containerName(String($0.split(separator: ":").first ?? ""), containers) }
        let sources = from.compactMap { name in containers.first { $0.name == name } }
        guard sources.count == from.count else { return [] }
        let inherited = Set(sources.flatMap(\.volumeNames))
        return c.mounts.compactMap { m in
            guard m["Type"]?.string == "volume", let name = m["Name"]?.string, let dest = m["Destination"]?.string,
                  !named.contains(dest), !inherited.contains(name) else { return nil }
            return (dest, name)
        }
    }

    static let helperKey = "dmx.import.helper"

    /// Docker's own rule for volume and container names: [a-zA-Z0-9][a-zA-Z0-9_.-]+.
    static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count >= 2, name.count <= 255,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
    }

    /// An image reference or ID as an argument: no leading dash, no space or control characters.
    static func validReference(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.hasPrefix("-") && ref.count <= 512
            && ref.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7f && $0 != "," }
    }

    static func removeHelpers(_ api: DockerAPI, label: String) async {
        guard let list = try? await api.json("GET", "/containers/json?all=1&filters=\(queryValue("{\"label\":[\"\(label)\"]}"))").array else { return }
        for c in list {
            if let id = c["Id"]?.string { _ = try? await api.call("DELETE", "/containers/\(id)?force=1&v=1") }
        }
    }

    /// The image digest Compose records in `com.docker.compose.image` (its localContentDigest):
    /// with per-manifest data (the containerd store, API 1.48 and later) the available image
    /// manifest for linux/arm64, or the only available one; otherwise the image ID.
    static func composeImageDigest(_ api: DockerAPI, _ ref: String) async -> String? {
        guard let i = try? await api.json("GET", "/images/\(ref)/json?manifests=1") else { return nil }
        let available = (i["Manifests"]?.array ?? []).filter { $0["Kind"]?.string == "image" && $0["Available"]?.bool == true }
        if let m = available.first(where: {
            $0["ImageData"]?["Platform"]?["os"]?.string == "linux" && $0["ImageData"]?["Platform"]?["architecture"]?.string == "arm64"
        }) {
            return m["ID"]?.string
        }
        if available.count == 1 { return available[0]["ID"]?.string }
        return i["Id"]?.string
    }

    /// The container path of a `-v` bind: `src:dst[:opts]`.
    static func bindTarget(_ bind: String) -> String? {
        let parts = bind.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// Host paths of binds that name the Mac's files but are not under one of dmx's shares.
    static func unsharedBinds(_ c: Container, shares: [Share]) -> [String] {
        let mac = ["/Users", "/Volumes", "/private", "/tmp", "/var/folders", "/Applications", "/Library", "/opt/homebrew"]
        var covered = shares.map(\.path)
        if covered.contains("/private") { covered += ["/tmp", "/var/folders"] }
        func under(_ path: String, _ dirs: [String]) -> Bool { dirs.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
        return c.mounts.filter { $0["Type"]?.string == "bind" }.compactMap { $0["Source"]?.string }
            .filter { under($0, mac) && !under($0, covered) }
    }
}

extension DockerCLI {
    /// `self args | other otherArgs`, the bytes going straight from one process to the other;
    /// returns the second one's output. The first failure is the one reported.
    static func pipe(_ a: DockerCLI, _ aArgs: [String], into b: DockerCLI, _ bArgs: [String], timeout: Double) async throws -> String {
        try await onThread {
            let first = a.process(aArgs), second = b.process(bArgs)
            let link = Pipe(), out = Pipe(), err1 = Pipe(), err2 = Pipe()
            first.standardInput = FileHandle.nullDevice
            first.standardOutput = link
            first.standardError = err1
            second.standardInput = link
            second.standardOutput = out
            second.standardError = err2
            do {
                try first.run()
                try second.run()
            } catch {
                if first.isRunning { first.terminate() }
                throw DMXError("docker_failed", "cannot run \(a.docker.path): \(error.localizedDescription)", hint: "run `dmx tools install`")
            }
            // Only the two children may hold the pipe, or the second never sees the end of it.
            try? link.fileHandleForWriting.close()
            try? link.fileHandleForReading.close()
            let timedOut = LockedData()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.setEventHandler { timedOut.set(Data()); first.terminate(); second.terminate() }
            timer.schedule(deadline: .now() + timeout)
            timer.resume()
            let e1 = LockedData(), e2 = LockedData()
            Thread { e1.set(err1.fileHandleForReading.readDataToEndOfFile()) }.start()
            Thread { e2.set(err2.fileHandleForReading.readDataToEndOfFile()) }.start()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            first.waitUntilExit()
            second.waitUntilExit()
            timer.cancel()
            while !e1.done || !e2.done { Thread.sleep(forTimeInterval: 0.01) }
            func failure(_ p: Foundation.Process, _ cli: DockerCLI, _ args: [String], _ err: Data) -> DMXError {
                let killed = timedOut.done || p.terminationReason == .uncaughtSignal
                let message = String(decoding: err.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return DMXError(killed ? "docker_timeout" : "docker_failed",
                                "docker \(args.prefix(2).joined(separator: " ")) against \(cli.socket.path) "
                                + (killed ? "stopped (timeout \(Int(timeout)) s or a broken pipe)" : "failed: \(message)"),
                                hint: "check the engine with `DOCKER_HOST=unix://\(cli.socket.path) docker info`")
            }
            if first.terminationStatus != 0, first.terminationReason == .exit { throw failure(first, a, aArgs, e1.value) }
            if second.terminationStatus != 0 { throw failure(second, b, bArgs, e2.value) }
            if first.terminationStatus != 0 { throw failure(first, a, aArgs, e1.value) }
            return String(decoding: output, as: UTF8.self)
        }
    }
}
