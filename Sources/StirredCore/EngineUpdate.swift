import Foundation

// MARK: - Which engines Stirred knows are good

/// One Wine build Stirred offers, pinned by SHA-256 like the first-run setup. The list ships inside the app (`engines.json`),
/// so a new engine only reaches users through a Stirred release that someone tested. Nothing unpinned is ever installed.
public struct EngineRelease: Codable, Sendable, Equatable, Identifiable {
    public var name: String          // folder under engines/, e.g. stirred-wine-11.21
    public var version: String       // 11.21
    public var url: URL
    public var sha256: String
    public var archiveName: String
    public var notes: String?
    public var id: String { name }

    public init(name: String, version: String, url: URL, sha256: String, archiveName: String, notes: String? = nil) {
        self.name = name; self.version = version; self.url = url; self.sha256 = sha256; self.archiveName = archiveName; self.notes = notes
    }
}

public struct EngineCatalog: Codable, Sendable, Equatable {
    public var releases: [EngineRelease]

    public static func load(from url: URL) -> EngineCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(EngineCatalog.self, from: data)
    }
}

public enum EngineVersion {
    /// "11.21" > "11.9" (numeric, not alphabetical). Anything unparsable sorts lowest.
    public static func parts(_ text: String) -> [Int] {
        let digits = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).joined()
        return digits.split(separator: ".").compactMap { Int($0) }
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// `stirred-wine-11.21` -> `11.21`
    public static func version(ofEngineNamed name: String) -> String { name.split(separator: "-").last.map(String.init) ?? name }
}

// MARK: - Which engine is active

public enum ActiveEngine {
    static func file(_ paths: StirredPaths, _ name: String) -> URL { paths.engines.appendingPathComponent(name) }

    public static func read(_ paths: StirredPaths, _ name: String) -> String? {
        (try? String(contentsOf: file(paths, name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func write(_ paths: StirredPaths, _ name: String, value: String?) throws {
        let url = file(paths, name)
        if let value { try value.write(to: url, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Prefix snapshots (what a new Wine may rewrite)

/// A new Wine rewrites the prefix's registry and Windows system files the first time it runs. Before switching, these are
/// copied with APFS cloning (instant, no extra space until they differ) so the old engine can get its prefix back.
/// Games and Steam's own files are never part of it.
public enum PrefixSnapshot {
    static let items = ["system.reg", "user.reg", "userdef.reg", ".update-timestamp", "drive_c/windows"]

    public static func directory(_ paths: StirredPaths, engine: String) -> URL {
        paths.prefixes.appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent(engine, isDirectory: true)
    }

    public static func exists(_ paths: StirredPaths, engine: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(paths, engine: engine).appendingPathComponent("system.reg").path)
    }

    static func clone(_ from: URL, _ to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SetupManager.runChecked("/bin/cp", ["-cR", from.path, to.path], what: "Copying \(from.lastPathComponent)")
    }

    public static func take(_ paths: StirredPaths, engine: String) throws {
        let prefix = paths.prefix(named: "steam"), target = directory(paths, engine: engine)
        try? FileManager.default.removeItem(at: target)
        do {
            for item in items where FileManager.default.fileExists(atPath: prefix.appendingPathComponent(item).path) {
                try clone(prefix.appendingPathComponent(item), target.appendingPathComponent(item))
            }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    public static func restore(_ paths: StirredPaths, engine: String) throws {
        let prefix = paths.prefix(named: "steam"), source = directory(paths, engine: engine)
        guard exists(paths, engine: engine) else { throw EngineUpdateError.noSnapshot(engine) }
        for item in items {
            let saved = source.appendingPathComponent(item), live = prefix.appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            try? FileManager.default.removeItem(at: live)
            try clone(saved, live)
        }
    }
}

// MARK: - Updating

public enum EngineUpdateError: Error, CustomStringConvertible, Sendable {
    case unknownRelease(String), notInstalled(String), nothingToRollBack, noSnapshot(String), smokeTestFailed(String), isActive(String)

    public var description: String {
        switch self {
        case .unknownRelease(let name): "\(name) is not in Stirred's list of tested engines."
        case .notInstalled(let name): "\(name) is not installed. Install it first."
        case .nothingToRollBack: "There is no previous engine to go back to."
        case .noSnapshot(let name): "No saved Windows environment for \(name), so Stirred cannot restore it."
        case .smokeTestFailed(let why): "The new engine did not pass the start-up check (\(why))."
        case .isActive(let name): "\(name) is the engine in use."
        }
    }
}

public struct EngineStatus: Sendable {
    public var active: Engine?
    public var previous: String?
    public var installed: [Engine]
    /// Tested releases newer than the active engine.
    public var updates: [EngineRelease]
}

public struct EngineUpdater: Sendable {
    public let paths: StirredPaths
    public let catalog: EngineCatalog
    public let wrapper: URL?

    public init(paths: StirredPaths, catalog: EngineCatalog, wrapper: URL? = nil) {
        self.paths = paths; self.catalog = catalog; self.wrapper = wrapper
    }

    public func status() -> EngineStatus {
        let active = EngineLocator.preferred(paths: paths)
        let installed = EngineLocator.installedEngines(paths: paths)
        let activeVersion = active.map { EngineVersion.version(ofEngineNamed: $0.name) } ?? "0"
        let updates = catalog.releases
            .filter { EngineVersion.isNewer($0.version, than: activeVersion) }
            .sorted { EngineVersion.isNewer($0.version, than: $1.version) }
        return EngineStatus(active: active, previous: ActiveEngine.read(paths, "previous.txt"), installed: installed, updates: updates)
    }

    /// Downloads and unpacks a tested release next to the current engine. The current one keeps running.
    public func install(_ name: String, progress: @escaping @Sendable (String) -> Void) async throws {
        guard let release = catalog.releases.first(where: { $0.name == name }) else { throw EngineUpdateError.unknownRelease(name) }
        if EngineLocator.installedEngines(paths: paths).contains(where: { $0.name == name }) { return }
        // Without an explicit choice the newest installed engine is the one in use: pin the current one so that merely
        // downloading a newer engine does not switch to it.
        if ActiveEngine.read(paths, "active.txt") == nil, let current = EngineLocator.preferred(paths: paths) {
            try ActiveEngine.write(paths, "active.txt", value: current.name)
        }
        try await SetupManager(paths: paths, wrapper: wrapper).installEngine(release, progress)
    }

    /// The new engine must start Wine in the real prefix and run a program before it is kept.
    func smokeTest(_ engine: Engine) async throws {
        let runner = try WineRunner(engine: engine, prefix: paths.prefix(named: "steam"))
        let log = paths.logs.appendingPathComponent("engine-check.log")
        let status: Int32
        do { status = try await runner.runAndWait(arguments: ["cmd", "/c", "echo stirred-ok"], logFile: log) }
        catch { throw EngineUpdateError.smokeTestFailed("\(error)") }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard status == 0, output.contains("stirred-ok") else { throw EngineUpdateError.smokeTestFailed("exit \(status)") }
    }

    private func stopWine(using engine: Engine) {
        guard let wine = engine.wineBinary else { return }
        let process = Process()
        process.executableURL = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        process.arguments = ["-k"]
        process.environment = ["WINEPREFIX": paths.prefix(named: "steam").path]
        try? process.run(); process.waitUntilExit()
    }

    /// Switches to an installed engine: snapshot the prefix, switch, check it works, and go back by itself if it does not.
    /// Steam and games must be closed first (the caller does that).
    public func use(_ name: String, onPhase: @Sendable (String) -> Void = { _ in }) async throws {
        guard let target = EngineLocator.installedEngines(paths: paths).first(where: { $0.name == name }) else { throw EngineUpdateError.notInstalled(name) }
        guard let current = EngineLocator.preferred(paths: paths) else { throw StirredError.engineNotFound }
        if current.name == name { throw EngineUpdateError.isActive(name) }
        onPhase("Saving the Windows environment…")
        try PrefixSnapshot.take(paths, engine: current.name)
        stopWine(using: current)
        try ActiveEngine.write(paths, "previous.txt", value: current.name)
        try ActiveEngine.write(paths, "active.txt", value: name)
        onPhase("Checking the new engine…")
        do { try await smokeTest(target) } catch {
            onPhase("The new engine failed: going back…")
            stopWine(using: target)
            try? PrefixSnapshot.restore(paths, engine: current.name)
            try? ActiveEngine.write(paths, "active.txt", value: current.name)
            try? ActiveEngine.write(paths, "previous.txt", value: nil)
            throw error
        }
    }

    /// Back to the engine used before the last switch, with the Windows environment it had.
    public func rollback(onPhase: @Sendable (String) -> Void = { _ in }) async throws {
        guard let previousName = ActiveEngine.read(paths, "previous.txt"),
              let previous = EngineLocator.installedEngines(paths: paths).first(where: { $0.name == previousName }) else {
            throw EngineUpdateError.nothingToRollBack
        }
        guard let current = EngineLocator.preferred(paths: paths) else { throw StirredError.engineNotFound }
        guard PrefixSnapshot.exists(paths, engine: previousName) else { throw EngineUpdateError.noSnapshot(previousName) }
        onPhase("Restoring the Windows environment…")
        stopWine(using: current)
        try PrefixSnapshot.restore(paths, engine: previousName)
        try ActiveEngine.write(paths, "active.txt", value: previousName)
        try ActiveEngine.write(paths, "previous.txt", value: nil)
        onPhase("Checking the restored engine…")
        try await smokeTest(previous)
    }

    /// Deletes an engine that is not in use (and its saved snapshot). The one you could roll back to can be deleted too.
    public func remove(_ name: String) throws {
        guard EngineLocator.preferred(paths: paths)?.name != name else { throw EngineUpdateError.isActive(name) }
        try? FileManager.default.removeItem(at: paths.engines.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: PrefixSnapshot.directory(paths, engine: name))
        if ActiveEngine.read(paths, "previous.txt") == name { try? ActiveEngine.write(paths, "previous.txt", value: nil) }
    }

    // MARK: Newer upstream builds (information only)

    /// Version number from GitHub's "latest release" answer (nil if unreadable).
    public static func upstreamVersion(fromReleaseJSON data: Data) -> String? {
        struct Release: Decodable { var tag_name: String }
        return (try? JSONDecoder().decode(Release.self, from: data))?.tag_name
    }

    /// Asks GitHub which Wine build Gcenx published last. Only reports: Stirred installs nothing it has not pinned.
    public static func checkUpstream() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return upstreamVersion(fromReleaseJSON: data)
    }
}

extension Launcher {
    public static func defaultEngineCatalogURL(resources: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["STIRRED_ENGINE_CATALOG"] { return URL(fileURLWithPath: override) }
        return resources.appendingPathComponent("engines.json")
    }

    public var engineUpdater: EngineUpdater {
        let catalog = EngineCatalog.load(from: Self.defaultEngineCatalogURL(resources: resourcesDirectory)) ?? EngineCatalog(releases: [])
        return EngineUpdater(paths: paths, catalog: catalog, wrapper: wrapperURL)
    }

    /// Closes Steam and games' Wine, then runs the switch.
    public func useEngine(_ name: String, onPhase: @Sendable (String) -> Void = { _ in }) async throws {
        if steamState() != .stopped { onPhase("Closing Steam…"); await quitSteam(graceful: true) }
        backupGameData(.engineChange)
        try await engineUpdater.use(name, onPhase: onPhase)
    }

    public func rollbackEngine(onPhase: @Sendable (String) -> Void = { _ in }) async throws {
        if steamState() != .stopped { onPhase("Closing Steam…"); await quitSteam(graceful: true) }
        backupGameData(.engineChange)
        try await engineUpdater.rollback(onPhase: onPhase)
    }
}
