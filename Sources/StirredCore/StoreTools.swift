import Foundation

/// A command-line tool another store needs (Legendary for Epic...). Pinned by version and SHA-256, downloaded from its
/// official release page only when the user sets the store up, and kept in `<root>/tools/<name>-<version>/`.
public struct StoreTool: Sendable, Equatable {
    public var name: String
    public var version: String
    public var url: URL
    public var sha256: String
    public var license: String

    /// Legendary 0.21.1 (GPL-3.0), the open-source Epic Games client: native Apple-chip binary from its GitHub releases.
    public static let legendary = StoreTool(
        name: "legendary", version: "0.21.1",
        url: URL(string: "https://github.com/legendary-gl/legendary/releases/download/0.21.1/legendary_macOS_arm64")!,
        sha256: "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e", license: "GPL-3.0")

    public func binary(_ paths: StirredPaths) -> URL {
        paths.root.appendingPathComponent("tools/\(name)-\(version)/\(name)")
    }

    public func isInstalled(_ paths: StirredPaths) -> Bool {
        FileManager.default.isExecutableFile(atPath: binary(paths).path)
    }

    /// Downloads, verifies the checksum, then installs. A file that does not match is deleted and never run.
    @discardableResult
    public func install(_ paths: StirredPaths, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let target = binary(paths)
        if isInstalled(paths), (try? SetupManager.sha256Hex(of: target)) == sha256 { return target }
        let setup = SetupManager(paths: paths, wrapper: nil)
        try FileManager.default.createDirectory(at: paths.downloads, withIntermediateDirectories: true)
        let file = try await setup.downloadVerified(url, name: "\(name)-\(version)", sha256: sha256, label: name.capitalized, progress)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: file, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }
}
