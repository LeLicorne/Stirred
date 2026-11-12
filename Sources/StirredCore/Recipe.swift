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
/// A game's own updater (e.g. Warframe's launcher), run through Steam. Wine needs it prepared: DXVK provides the Direct3D 11
/// its hardware check wants, while the Direct3D shader compiler is switched off for that one program (its Chromium page
/// stays blank otherwise).
public struct GameUpdater: Codable, Sendable, Equatable {
    /// Path of the updater inside the game's folder, e.g. `Tools/Launcher.exe`.
    public var executable: String
    /// DLLs disabled for the updater only.
    public var disabledDlls: [String]?

    public init(executable: String, disabledDlls: [String]? = nil) {
        self.executable = executable; self.disabledDlls = disabledDlls
    }
}

public struct Recipe: Codable, Sendable, Equatable {
    public var appid: Int
    /// Other stores than Steam: `"store": "epic", "game_id": "Salt"` (`appid` is then 0). Absent means Steam.
    public var store: String?
    public var gameId: String?
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
    /// Extra per-game DXVK settings written to dxvk.conf, e.g. `"d3d11.zeroWorkgroupMemory": "True"`.
    public var dxvkOptions: [String: String]?
    /// The preset suggested for this game (the user's own choice, saved as a personal setting, wins).
    public var preset: QualityPreset?
    public var notes: String?
    /// When set, Stirred offers an "Update game" action that runs the game's own updater.
    public var updater: GameUpdater?

    public init(
        appid: Int, name: String, status: CompatStatus, verified: Bool = false,
        blockers: [String]? = nil, graphics: GraphicsBackend? = nil,
        env: [String: String]? = nil, dllOverrides: [String: String]? = nil,
        launchArgs: [String]? = nil, latency: LatencyProfile? = nil, launchMode: LaunchMode? = nil, dxvkOptions: [String: String]? = nil, preset: QualityPreset? = nil, notes: String? = nil,
        updater: GameUpdater? = nil, store: String? = nil, gameId: String? = nil
    ) {
        self.store = store; self.gameId = gameId
        self.updater = updater
        self.appid = appid; self.name = name; self.status = status; self.verified = verified
        self.blockers = blockers; self.graphics = graphics; self.env = env
        self.dllOverrides = dllOverrides; self.launchArgs = launchArgs; self.latency = latency; self.launchMode = launchMode; self.dxvkOptions = dxvkOptions; self.preset = preset; self.notes = notes
    }
}

public struct RecipeRepository: Sendable {
    public let directory: URL
    /// Recipes the user imported (they win over the bundled ones).
    public let userDirectory: URL?

    public init(directory: URL, userDirectory: URL? = nil) {
        self.directory = directory; self.userDirectory = userDirectory
    }

    public func recipe(forSteamAppID appID: Int) -> Recipe? {
        if let imported = importedRecipe(forSteamAppID: appID) { return imported }
        let url = directory.appendingPathComponent("steam/\(appID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Recipe.self, from: data)
    }

    /// A game of any store: `recipes/<store>/<id>.json`, imported ones first. Steam keeps its own lookup above.
    public func recipe(for key: GameKey) -> Recipe? {
        if let appID = key.steamAppID { return recipe(forSteamAppID: appID) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for base in [userDirectory, directory].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: base.appendingPathComponent("\(key.path).json")),
               let recipe = try? decoder.decode(Recipe.self, from: data) { return recipe }
        }
        return nil
    }
}
