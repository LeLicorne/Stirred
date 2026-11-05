import Foundation

/// A game as shown in the library, whichever store it comes from.
public struct Game: Sendable, Equatable, Identifiable {
    public var store: String
    public var storeID: String
    public var name: String
    public var installDirectory: URL?
    public var id: String { "\(store):\(storeID)" }

    public var steamAppID: Int? { store == "steam" ? Int(storeID) : nil }
}

/// Each store (Steam now; Epic, GOG, Ubisoft later) plugs in here.
public protocol GameStoreProvider: Sendable {
    var storeName: String { get }
    var isInstalled: Bool { get }
    func installedGames() throws -> [Game]
    func launch(_ game: Game, plan: LaunchPlan) throws -> Process
}

public struct SteamProvider: GameStoreProvider {
    /// Flags that make the Steam client (Chromium Embedded Framework) behave under Wine.
    public static let clientFlags = ["-no-cef-sandbox", "-cef-disable-gpu-compositing"]

    public let runner: WineRunner
    public let logsDirectory: URL

    public init(runner: WineRunner, logsDirectory: URL) {
        self.runner = runner
        self.logsDirectory = logsDirectory
    }

    public var storeName: String { "steam" }

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
                return Game(store: "steam", storeID: appID, name: name, installDirectory: dir)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Starts the Steam client alone (used for first login and warm-up).
    public func launchClient() throws -> Process {
        guard isInstalled else { throw StirredError.steamNotInstalled }
        let process = try runner.makeProcess(
            arguments: [steamExecutable.path] + Self.clientFlags,
            extraEnvironment: ["WINEMSYNC": "1"],
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
        var arguments = [steamExecutable.path] + Self.clientFlags + ["-applaunch", game.storeID]
        arguments += plan.gameArguments
        let process = try runner.makeProcess(
            arguments: arguments, extraEnvironment: plan.environment,
            workingDirectory: steamRoot,
            logFile: logsDirectory.appendingPathComponent("game-\(game.storeID).log"))
        try process.run()
        return process
    }
}
