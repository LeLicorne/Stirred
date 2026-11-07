import Foundation

public struct LaunchOptions: Sendable, Equatable {
    public var latency: LatencyProfile?
    public var hud: Bool
    public var asyncShaders: Bool
    /// Overrides the recipe (e.g. run a game's own launcher/updater through Steam).
    public var launchMode: LaunchMode?

    public init(latency: LatencyProfile? = nil, hud: Bool = false, asyncShaders: Bool = false, launchMode: LaunchMode? = nil) {
        self.latency = latency; self.hud = hud; self.asyncShaders = asyncShaders; self.launchMode = launchMode
    }
}

public enum SteamState: Sendable, Equatable {
    case stopped
    case running   // process exists, not logged on yet (starting up, or login screen)
    case ready     // logged on: games can be launched
}

/// Everything the CLI and the app share: find the engine, read the library, start Steam, launch a game, record it.
public struct Launcher: Sendable {
    public let paths: StirredPaths
    public let recipes: RecipeRepository

    public init(paths: StirredPaths = StirredPaths(), recipesDirectory: URL = Launcher.defaultRecipesDirectory()) {
        self.paths = paths
        self.recipes = RecipeRepository(directory: recipesDirectory)
    }

    /// STIRRED_RECIPES, else the app bundle's `Resources/recipes`, else `./recipes`.
    public static func defaultRecipesDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["STIRRED_RECIPES"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("recipes", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/recipes")
    }

    // MARK: Engine, Steam, library

    public func engine() throws -> Engine {
        guard let engine = EngineLocator.preferred(paths: paths) else { throw StirredError.engineNotFound }
        return engine
    }

    public func runner() throws -> WineRunner { try WineRunner(engine: try engine(), prefix: paths.prefix(named: "steam")) }
    public func steam() throws -> SteamProvider { SteamProvider(runner: try runner(), logsDirectory: paths.logs) }
    public func installedGames() throws -> [Game] { try steam().installedGames() }

    public func recipe(for game: Game) -> Recipe? { game.steamAppID.flatMap { recipes.recipe(forSteamAppID: $0) } }

    public func processNeedle(for game: Game) -> String {
        GameExecutableFinder.candidates(in: game.installDirectory ?? paths.root).first?.lastPathComponent ?? game.name
    }

    public func plan(for game: Game, options: LaunchOptions = LaunchOptions()) -> LaunchPlan {
        let apis = GraphicsDetector.detect(executables: GameExecutableFinder.candidates(in: game.installDirectory ?? paths.root))
        var plan = LaunchPlanner.plan(recipe: recipe(for: game), detectedAPIs: apis, latency: options.latency)
        if let mode = options.launchMode { plan.launchMode = mode }
        return plan
    }

    // MARK: Graphics

    public var dxvkPackage: URL { paths.components.appendingPathComponent("dxvk-macos-1.10.3", isDirectory: true) }

    /// Installs DXVK next to each candidate executable and sets the per-executable Wine overrides. Returns log lines.
    @discardableResult
    public func prepareGraphics(for game: Game, plan: LaunchPlan, options: LaunchOptions) async throws -> [String] {
        guard plan.backend == .dxvk, let dir = game.installDirectory else { return [] }
        guard FileManager.default.fileExists(atPath: dxvkPackage.path) else {
            throw StirredError.blocked("DXVK component missing at \(dxvkPackage.path). Run Scripts/install-components.sh")
        }
        let runner = try runner()
        var lines: [String] = []
        for exe in GameExecutableFinder.candidates(in: dir) {
            let arch = PEInfo.architecture(ofFile: exe)
            guard arch == .x86 || arch == .x64 else { continue }
            try DXVKInstaller.install(package: dxvkPackage, executable: exe, architecture: arch, latency: plan.latency,
                                      hud: options.hud, asyncShaders: options.asyncShaders)
            for command in DXVKInstaller.registryCommands(executableName: exe.lastPathComponent) {
                _ = try await runner.runAndWait(arguments: command)
            }
            lines.append("dxvk installed for \(exe.lastPathComponent) (\(arch))")
        }
        return lines
    }

    // MARK: Steam lifecycle

    public static func isSteamClientRunning(psOutput: String) -> Bool {
        psOutput.split(separator: "\n").contains { line in
            let s = line.lowercased()
            return s.contains("steam.exe") && !s.contains("webhelper") && !s.contains("steamservice") && !s.contains("steamsetup")
        }
    }

    /// True when the last state line of Steam's connection log says "Logged On".
    public static func isLoggedOn(connectionLogTail: String) -> Bool {
        guard let line = connectionLogTail.split(separator: "\n").last(where: {
            $0.contains("[Logged On") || $0.contains("[Logged Off") || $0.contains("[Connecting") || $0.contains("[Logging")
        }) else { return false }
        return line.contains("[Logged On")
    }

    /// `since`: ignore a "Logged On" written before that moment (stale line from an earlier Steam session).
    public func steamState(since: Date = .distantPast) -> SteamState {
        guard Self.isSteamClientRunning(psOutput: SystemSampler.run("/bin/ps", ["-Ao", "command"])) else { return .stopped }
        guard let steam = try? steam() else { return .running }
        let log = steam.steamRoot.appendingPathComponent("logs/connection_log.txt")
        let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard modified >= since, let tail = LogCollector.tail(log, maxBytes: 16_000) else { return .running }
        return Self.isLoggedOn(connectionLogTail: tail) ? .ready : .running
    }

    /// `silent`: start minimised (no Steam window), only sensible once a login is remembered.
    public func startSteam(silent: Bool) throws {
        _ = try steam().launchClient(silent: silent)
    }

    public func waitUntilSteamReady(since: Date, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if steamState(since: since) == .ready { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    /// Opens Steam's main window (login, store, installing games).
    public func openSteamWindow() throws {
        let steam = try steam()
        let process = try steam.runner.makeProcess(
            arguments: [steam.steamRoot.appendingPathComponent("Steam.exe").path, "steam://open/main"],
            workingDirectory: steam.steamRoot)
        try process.run()
    }

    /// Asks Steam to install a game (Steam shows its own confirmation dialog: the user must accept it).
    public func requestInstall(appID: Int) throws {
        let steam = try steam()
        let process = try steam.runner.makeProcess(
            arguments: [steam.steamRoot.appendingPathComponent("Steam.exe").path, "steam://install/\(appID)"],
            workingDirectory: steam.steamRoot)
        try process.run()
    }

    /// Stops Steam and every Wine process of the engine.
    public func quitSteam() async {
        guard let runner = try? runner() else { return }
        let server = runner.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        if let process = try? runner.makeProcess(arguments: [], extraEnvironment: [:]) {
            process.executableURL = server
            process.arguments = ["-k"]
            try? process.run()
            process.waitUntilExit()
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = SystemSampler.run("/usr/bin/pkill", ["-9", "-f", paths.engines.path])
    }

    /// Stops the game and everything started from its folder (launchers, helpers). Steam keeps showing "Stopping"
    /// as long as any process it tracks for the game is alive (e.g. Ubisoft Connect for Trackmania).
    public func stopGame(_ game: Game) {
        for pattern in Self.stopPatterns(for: game, needle: processNeedle(for: game)) {
            _ = SystemSampler.run("/usr/bin/pkill", ["-f", pattern])
        }
    }

    /// `pkill -f` regular expressions: the exe name, anything under `\common\<folder>\`, and Ubisoft's launcher
    /// for games that use it.
    public static func stopPatterns(for game: Game, needle: String) -> [String] {
        var patterns = [NSRegularExpression.escapedPattern(for: needle)]
        if let dir = game.installDirectory {
            patterns.append(NSRegularExpression.escapedPattern(for: "\\common\\\(dir.lastPathComponent)\\"))
            let usesUbisoft = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .contains { $0.lowercased().hasPrefix("upc_r") && $0.lowercased().hasSuffix(".dll") } ?? false
            if usesUbisoft { patterns.append("Ubisoft Game Launcher") }
        }
        return patterns
    }

    // MARK: Play

    /// Starts Steam if needed, prepares graphics, opens a recorded session and asks Steam to launch the game.
    public func play(
        _ game: Game, options: LaunchOptions = LaunchOptions(), onPhase: @Sendable (String) -> Void = { _ in }
    ) async throws -> SessionRecorder {
        let plan = plan(for: game, options: options)
        if let reason = plan.blockedReason { throw StirredError.blocked(reason) }

        var since = Date.distantPast
        if steamState() == .stopped {
            onPhase("Starting Steam…")
            since = Date()
            try startSteam(silent: true)
        }
        onPhase("Waiting for Steam…")
        guard await waitUntilSteamReady(since: since, timeout: 240) else {
            throw StirredError.blocked("Steam did not finish starting (is the account logged in? use Open Steam).")
        }
        onPhase("Preparing graphics…")
        try await prepareGraphics(for: game, plan: plan, options: options)
        let recorder = try SessionRecorder.begin(
            game: game, plan: plan, engine: try engine().name, processNeedle: processNeedle(for: game), paths: paths)
        onPhase("Launching…")
        _ = try steam().launch(game, plan: plan)
        return recorder
    }

    @discardableResult
    public func finish(_ recorder: inout SessionRecorder) throws -> URL {
        try recorder.finish(paths: paths, prefix: try runner().prefix)
    }

    // MARK: Sessions

    public func sessionDirectories() -> [URL] {
        let dir = SessionRecorder.sessionsDirectory(paths)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent != "latest" && $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

extension SessionRecorder {
    /// Samples the game's processes every 3 s: waits for the process to appear, stops when it exits,
    /// after `maxSeconds`, or when `shouldStop` returns true.
    public mutating func watch(
        maxSeconds: Int, waitSeconds: Int = 120, shouldStop: @Sendable () -> Bool = { false },
        onEvent: @Sendable (String) -> Void = { _ in }
    ) async {
        let needle = record.processNeedle
        let waitStart = Date()
        var started: Date?
        var misses = 0
        while !shouldStop() {
            let now = Date()
            if started == nil, now.timeIntervalSince(waitStart) > Double(waitSeconds) { onEvent("game process never appeared"); return }
            if let started, now.timeIntervalSince(started) >= Double(maxSeconds) { return }
            var sample = SystemSampler.sample(processNeedle: needle, at: 0)
            if sample.processCount > 0 {
                if started == nil { started = now; onEvent("game detected") }
                misses = 0
                sample.t = now.timeIntervalSince(started ?? now)
                add(sample)
            } else if started != nil {
                misses += 1
                if misses >= 2 { onEvent("game exited"); return }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
