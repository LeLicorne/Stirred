import Foundation

/// A Wine build (plus graphics backends already overlaid into it) living in `engines/<name>`.
public struct Engine: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var name: String { directory.lastPathComponent }

    /// The optional engine that can run DXMT (Direct3D 11 -> Metal): `stirred-wine-<version>-dxmt`, see docs/DXMT.md.
    public var isDXMT: Bool { name.hasSuffix("-dxmt") }

    /// `lib/wine` of the Wine inside this engine (where the DLLs of the graphics layers live).
    public var libraryDirectory: URL? {
        wineBinary?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/wine", isDirectory: true)
    }

    /// Path to the `wine` launcher. Gcenx builds ship it inside `<Something>.app/Contents/Resources/wine/bin/wine`.
    public var wineBinary: URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent("bin/wine")
        if fm.isExecutableFile(atPath: direct.path) { return direct }
        guard let apps = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for app in apps where app.pathExtension == "app" {
            let candidate = app.appendingPathComponent("Contents/Resources/wine/bin/wine")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

public enum EngineLocator {
    /// Engines assembled by Stirred are named `stirred-*`; raw upstream downloads are ignored.
    public static func installedEngines(paths: StirredPaths = StirredPaths()) -> [Engine] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: paths.engines, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("stirred-") }
            .map(Engine.init(directory:))
            .filter { $0.wineBinary != nil && !$0.isDXMT }
            .sorted { EngineVersion.isNewer(EngineVersion.version(ofEngineNamed: $0.name), than: EngineVersion.version(ofEngineNamed: $1.name)) }
    }

    /// The optional DXMT engine, if the user built or installed one (newest first). Never chosen by default.
    public static func dxmt(paths: StirredPaths = StirredPaths()) -> Engine? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("stirred-") && $0.lastPathComponent.hasSuffix("-dxmt") }
            .map(Engine.init(directory:))
            .filter { $0.wineBinary != nil }
            .sorted { $0.name > $1.name }.first
    }

    /// Name of the engine the running Steam was started with (Steam and the games it launches share one Wine).
    public static let steamEngineFile = "steam-engine.txt"

    /// Same idea for any Windows environment: each prefix has its own wineserver, so each remembers its own engine.
    /// Steam keeps its historical file name.
    public static func sessionFile(forPrefix name: String) -> String { name == "steam" ? steamEngineFile : "session-\(name).txt" }

    public static func preferred(paths: StirredPaths = StirredPaths()) -> Engine? {
        // Debug/experiments: STIRRED_ENGINE=<directory name under engines/> forces a specific engine.
        if let name = ProcessInfo.processInfo.environment["STIRRED_ENGINE"] {
            let engine = Engine(directory: paths.engines.appendingPathComponent(name, isDirectory: true))
            return engine.wineBinary == nil ? nil : engine
        }
        let installed = installedEngines(paths: paths)
        // The engine chosen by an update (or a rollback) wins over "newest installed".
        if let chosen = ActiveEngine.read(paths, "active.txt"), let engine = installed.first(where: { $0.name == chosen }) { return engine }
        return installed.first
    }
}
