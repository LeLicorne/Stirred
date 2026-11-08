import Foundation

/// The user's own settings for one game. They live next to the data (never inside the app bundle, whose recipes are read-only)
/// and are merged over the recipe, so a fix applied by the diagnosis survives updates of Stirred.
public struct GameOverride: Codable, Sendable, Equatable {
    /// Added after the recipe's own launch arguments.
    public var launchArgs: [String]?
    public var launchMode: LaunchMode?
    public var graphics: GraphicsBackend?
    public var latency: LatencyProfile?
    public var dxvkOptions: [String: String]?
    public var preset: QualityPreset?

    public init(launchArgs: [String]? = nil, launchMode: LaunchMode? = nil, graphics: GraphicsBackend? = nil,
                latency: LatencyProfile? = nil, dxvkOptions: [String: String]? = nil, preset: QualityPreset? = nil) {
        self.launchArgs = launchArgs; self.launchMode = launchMode; self.graphics = graphics
        self.latency = latency; self.dxvkOptions = dxvkOptions; self.preset = preset
    }

    public var isEmpty: Bool { self == GameOverride() }
}

public struct OverrideStore: Sendable {
    public let directory: URL

    public init(paths: StirredPaths = StirredPaths()) {
        directory = paths.root.appendingPathComponent("overrides/steam", isDirectory: true)
    }

    private func file(_ appID: Int) -> URL { directory.appendingPathComponent("\(appID).json") }

    public func read(_ appID: Int) -> GameOverride {
        guard let data = try? Data(contentsOf: file(appID)),
              let value = try? JSONDecoder().decode(GameOverride.self, from: data) else { return GameOverride() }
        return value
    }

    public func update(_ appID: Int, _ change: (inout GameOverride) -> Void) throws {
        var value = read(appID)
        change(&value)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if value.isEmpty { try? FileManager.default.removeItem(at: file(appID)); return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file(appID))
    }

    /// Forgets every personal setting for the game (the recipe applies again).
    public func reset(_ appID: Int) throws {
        if FileManager.default.fileExists(atPath: file(appID).path) { try FileManager.default.removeItem(at: file(appID)) }
    }

    /// The recipe with the user's settings on top. Without any override the recipe is returned untouched (including nil).
    public func apply(to recipe: Recipe?, game: Game) -> Recipe? {
        guard let appID = game.steamAppID else { return recipe }
        let override = read(appID)
        guard !override.isEmpty else { return recipe }
        var merged = recipe ?? Recipe(appid: appID, name: game.name, status: .unknown)
        var args = merged.launchArgs ?? []
        for arg in override.launchArgs ?? [] where !args.contains(arg) { args.append(arg) }
        merged.launchArgs = args.isEmpty ? nil : args
        merged.launchMode = override.launchMode ?? merged.launchMode
        merged.graphics = override.graphics ?? merged.graphics
        merged.latency = override.latency ?? merged.latency
        merged.preset = override.preset ?? merged.preset
        if let options = override.dxvkOptions { merged.dxvkOptions = (merged.dxvkOptions ?? [:]).merging(options) { _, new in new } }
        return merged
    }
}
