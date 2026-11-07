import Foundation

public enum CompatStatus: String, Codable, Sendable {
    case perfect, playable, experimental, unsupported, unknown
    case offlineOnly = "offline-only"
}

public enum GraphicsBackend: String, Codable, Sendable {
    case dxmt      // DX11 -> Metal (LGPL, bundled in the engine)
    case dxvk      // DX9/10/11 -> Vulkan -> MoltenVK
    case vkd3d     // DX12 -> Vulkan -> MoltenVK (experimental)
    case wined3d   // Wine's built-in fallback
}

/// How the game is started. `steam` asks the Steam client (overlay, cloud saves, but Steam may show prompts such as
/// "Grab a controller"); `direct` runs the executable ourselves with SteamAppId set (Steam stays running for Steamworks).
public enum LaunchMode: String, Codable, Sendable {
    case steam, direct
}

/// Per-game compatibility knowledge. Stored as `recipes/steam/<appid>.json` in the repository.
public struct Recipe: Codable, Sendable, Equatable {
    public var appid: Int
    public var name: String
    public var status: CompatStatus
    /// True only once someone actually ran the game on a real machine.
    public var verified: Bool
    public var blockers: [String]?
    public var graphics: GraphicsBackend?
    public var env: [String: String]?
    public var dllOverrides: [String: String]?
    public var launchArgs: [String]?
    public var latency: LatencyProfile?
    public var launchMode: LaunchMode?
    public var notes: String?

    public init(
        appid: Int, name: String, status: CompatStatus, verified: Bool = false,
        blockers: [String]? = nil, graphics: GraphicsBackend? = nil,
        env: [String: String]? = nil, dllOverrides: [String: String]? = nil,
        launchArgs: [String]? = nil, latency: LatencyProfile? = nil, launchMode: LaunchMode? = nil, notes: String? = nil
    ) {
        self.appid = appid; self.name = name; self.status = status; self.verified = verified
        self.blockers = blockers; self.graphics = graphics; self.env = env
        self.dllOverrides = dllOverrides; self.launchArgs = launchArgs; self.latency = latency; self.launchMode = launchMode; self.notes = notes
    }
}

public struct RecipeRepository: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func recipe(forSteamAppID appID: Int) -> Recipe? {
        let url = directory.appendingPathComponent("steam/\(appID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Recipe.self, from: data)
    }
}
