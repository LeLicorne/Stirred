import Foundation

/// A game as shown in the library, whichever store it comes from.
public struct Game: Sendable, Equatable, Identifiable {
    public var store: String
    public var storeID: String
    public var name: String
    public var installDirectory: URL?
    /// From the manifest: bytes the game takes on disk.
    public var sizeOnDisk: Int64? = nil
    /// 0...1 while Steam is downloading or updating it, nil once fully installed.
    public var downloadProgress: Double? = nil
    public var id: String { "\(store):\(storeID)" }

    public var steamAppID: Int? { store == "steam" ? Int(storeID) : nil }
}

/// Each store (Steam now; Epic, GOG, Ubisoft later) plugs in here.
public protocol GameStoreProvider: Sendable {
    var storeName: String { get }
    /// True when the store's client (or tool) is set up in its Windows environment.
    var isInstalled: Bool { get }
    /// True when an account is signed in (the sign-in itself always happens on the store's own page).
    var isSignedIn: Bool { get }
    func installedGames() throws -> [Game]
    func launch(_ game: Game, plan: LaunchPlan) throws -> Process
}

extension GameStoreProvider {
    public var displayName: String { Stores.displayName(storeName) }
    /// Name of the Windows environment (prefix) this store's games live in.
    public var prefixName: String { Stores.prefixName(forStore: storeName) }
}

public struct SteamProvider: GameStoreProvider {
    /// Flags that make the Steam client (Chromium Embedded Framework) behave under Wine.
    /// `-noverifyfiles -nobootstrapupdate` stop Steam from restoring the original `steamwebhelper.exe`
    /// over our wrapper (see Wrapper/ and Scripts/install-webhelper-wrapper.sh). The wrapper is what
    /// fixes the black window; GPU-related CEF flags alone did not.
    public static let clientFlags = ["-no-cef-sandbox", "-noverifyfiles", "-nobootstrapupdate"]

    public let runner: WineRunner
    public let logsDirectory: URL

    public init(runner: WineRunner, logsDirectory: URL) {
        self.runner = runner
        self.logsDirectory = logsDirectory
    }

    public var storeName: String { "steam" }

    public var isSignedIn: Bool { hasRememberedLogin }

    public var steamRoot: URL {
        runner.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
    }

    private var steamExecutable: URL { steamRoot.appendingPathComponent("Steam.exe") }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: steamExecutable.path)
    }

    public func installedGames() throws -> [Game] {
        let steamapps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
        return try files
            .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
            .compactMap { url -> Game? in
                let manifest = try VDF.parse(String(contentsOf: url, encoding: .utf8))
                guard let state = manifest["AppState"],
                      let appID = state["appid"]?.stringValue,
                      let name = state["name"]?.stringValue else { return nil }
                let dir = state["installdir"]?.stringValue
                    .map { steamapps.appendingPathComponent("common/\($0)", isDirectory: true) }
                let flags = Int(state["StateFlags"]?.stringValue ?? "") ?? 4
                let toDownload = Double(state["BytesToDownload"]?.stringValue ?? "") ?? 0
                let downloaded = Double(state["BytesDownloaded"]?.stringValue ?? "") ?? 0
                // StateFlags bit 4 = fully installed; Steam clears it while downloading or updating.
                let progress: Double? = (flags & 4) == 0 ? (toDownload > 0 ? min(1, downloaded / toDownload) : 0) : nil
                return Game(store: "steam", storeID: appID, name: name, installDirectory: dir,
                            sizeOnDisk: Int64(state["SizeOnDisk"]?.stringValue ?? ""), downloadProgress: progress)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Starts the Steam client alone (used for first login and warm-up).
    /// True when Steam remembers a signed-in account, so a silent (windowless) start can log in by itself.
    public var hasRememberedLogin: Bool {
        let file = steamRoot.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let doc = try? VDF.parse(text), case .object(let users)? = doc["users"] else { return false }
        return users.values.contains { $0["RememberPassword"]?.stringValue == "1" }
    }

    /// `firstRun`: Steam must be allowed to update itself, so no `-noverifyfiles -nobootstrapupdate`.
    public func launchClient(silent: Bool = false, firstRun: Bool = false) throws -> Process {
        guard isInstalled else { throw StirredError.steamNotInstalled }
        // Set at Steam start because games inherit Steam's environment: DXVK then logs every game to one folder.
        let dxvkLogs = logsDirectory.appendingPathComponent("dxvk", isDirectory: true)
        try FileManager.default.createDirectory(at: dxvkLogs, withIntermediateDirectories: true)
        let process = try runner.makeProcess(
            arguments: [steamExecutable.path] + (firstRun ? ["-no-cef-sandbox"] : Self.clientFlags) + (silent ? ["-silent"] : []),
            extraEnvironment: ["WINEMSYNC": "1", "DXVK_LOG_PATH": dxvkLogs.path, "DXVK_LOG_LEVEL": "info"],
            workingDirectory: steamRoot,
            logFile: logsDirectory.appendingPathComponent("steam-client.log"))
        try process.run()
        return process
    }

    /// Asks Steam to start a game. If Steam is not running yet, it starts first.
    /// The plan's environment is inherited by the game through Steam.
    public func launch(_ game: Game, plan: LaunchPlan) throws -> Process {
        guard isInstalled else { throw StirredError.steamNotInstalled }
        if let reason = plan.blockedReason { throw StirredError.blocked(reason) }
        if plan.launchMode == .direct { return try launchDirect(game, plan: plan) }
        var arguments = [steamExecutable.path] + Self.clientFlags + ["-applaunch", game.storeID]
        arguments += plan.gameArguments
        let process = try runner.makeProcess(
            arguments: arguments, extraEnvironment: plan.environment,
            workingDirectory: steamRoot,
            logFile: logsDirectory.appendingPathComponent("game-\(game.storeID).log"))
        try process.run()
        return process
    }

    /// Runs the game's executable ourselves. Steam must already be running; SteamAppId lets Steamworks find it.
    func launchDirect(_ game: Game, plan: LaunchPlan) throws -> Process {
        guard let dir = game.installDirectory, let exe = GameExecutableFinder.candidates(in: dir).first else {
            throw StirredError.blocked("No game executable found for direct launch.")
        }
        var env = plan.environment
        env["SteamAppId"] = game.storeID
        env["SteamGameId"] = game.storeID
        // A directly launched game does not inherit Steam's environment: give it the DXVK log folder explicitly.
        env["DXVK_LOG_PATH"] = logsDirectory.appendingPathComponent("dxvk", isDirectory: true).path
        env["DXVK_LOG_LEVEL"] = "info"
        let process = try runner.makeProcess(
            arguments: [exe.path] + plan.gameArguments, extraEnvironment: env, workingDirectory: dir,
            logFile: logsDirectory.appendingPathComponent("game-\(game.storeID).log"))
        try process.run()
        return process
    }
}
