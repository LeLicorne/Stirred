import Foundation

/// A Wine build (plus graphics backends already overlaid into it) living in `engines/<name>`.
public struct Engine: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var name: String { directory.lastPathComponent }

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
            .filter { $0.wineBinary != nil }
            .sorted { $0.name > $1.name }
    }

    public static func preferred(paths: StirredPaths = StirredPaths()) -> Engine? {
        installedEngines(paths: paths).first
    }
}
