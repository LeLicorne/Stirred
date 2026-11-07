import Foundation

/// Where Stirred keeps everything on disk (engines, Wine prefixes, downloads, logs).
public struct StirredPaths: Sendable {
    public let root: URL

    public init(root: URL = StirredPaths.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        // STIRRED_ROOT lets tests and scripts use a throw-away data folder.
        if let override = ProcessInfo.processInfo.environment["STIRRED_ROOT"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stirred", isDirectory: true)
    }

    public var engines: URL { root.appendingPathComponent("engines", isDirectory: true) }
    public var prefixes: URL { root.appendingPathComponent("prefixes", isDirectory: true) }
    public var components: URL { root.appendingPathComponent("components", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    public func prefix(named name: String) -> URL {
        prefixes.appendingPathComponent(name, isDirectory: true)
    }
}
