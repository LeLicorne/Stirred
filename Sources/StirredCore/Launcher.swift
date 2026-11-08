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
    public let resourcesDirectory: URL

    public init(
        paths: StirredPaths = StirredPaths(), recipesDirectory: URL = Launcher.defaultRecipesDirectory(),
        resourcesDirectory: URL = Launcher.defaultResourcesDirectory()
    ) {
        self.paths = paths
        self.recipes = RecipeRepository(directory: recipesDirectory)
        self.resourcesDirectory = resourcesDirectory
    }

    /// STIRRED_RESOURCES, else the app bundle's Resources (when it holds `wrappers/`), else `./Resources`.
    public static func defaultResourcesDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["STIRRED_RESOURCES"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("wrappers").path) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources")
    }

    /// The precompiled Steam display fix shipped with Stirred (nil if missing from this build).
    public var wrapperURL: URL? {
        let url = resourcesDirectory.appendingPathComponent("wrappers/steamwebhelper_wrapper.exe")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var setup: SetupManager { SetupManager(paths: paths, wrapper: wrapperURL) }

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
    /// Steam also installs technical components that are not games (shown nowhere in Stirred).
    static let hiddenAppIDs: Set<String> = ["228980", "4099820"]   // Steamworks Common Redistributables, Ubisoft Connect Services

    public func installedGames() throws -> [Game] {
        try steam().installedGames().filter { !Self.hiddenAppIDs.contains($0.storeID) }
    }

    public var overrides: OverrideStore { OverrideStore(paths: paths) }

    /// The recipe with the user's personal settings (fixes applied by the diagnosis) on top.
    public func recipe(for game: Game) -> Recipe? {
        overrides.apply(to: game.steamAppID.flatMap { recipes.recipe(forSteamAppID: $0) }, game: game)
    }

    public func processNeedle(for game: Game) -> String {
        GameExecutableFinder.candidates(in: game.installDirectory ?? paths.root).first?.lastPathComponent ?? game.name
    }

    /// The preset in effect for a game: the user's choice, else the recipe's suggestion, else none (the recipe's own settings apply).
    public func preset(for game: Game) -> QualityPreset? { recipe(for: game)?.preset }

    public func plan(for game: Game, options: LaunchOptions = LaunchOptions()) -> LaunchPlan {
        let apis = GraphicsDetector.detect(executables: GameExecutableFinder.candidates(in: game.installDirectory ?? paths.root))
        let recipe = recipe(for: game)
        let preset = recipe?.preset.map { PresetCatalog.settings(for: $0, hardware: .current) }
        // Authority for latency: this run's option > personal setting > preset > recipe > default.
        let personalLatency = game.steamAppID.flatMap { overrides.read($0).latency }
        var plan = LaunchPlanner.plan(recipe: recipe, detectedAPIs: apis, latency: options.latency ?? personalLatency ?? preset?.latency)
        if let mode = options.launchMode { plan.launchMode = mode }
        let isUnity = game.installDirectory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("UnityPlayer.dll").path) } ?? false
        if let preset {
            plan.dxvkOptions = preset.dxvkOptions.merging(plan.dxvkOptions) { _, existing in existing }
        }
        // Recent Unity versions pick Vulkan by default: through MoltenVK it shows missing texture tiles. DirectX 11 (through DXVK)
        // renders correctly, so force it unless the recipe already chose a graphics API.
        if isUnity, !plan.gameArguments.contains(where: { $0.hasPrefix("-force-") }) {
            plan.gameArguments.insert("-force-d3d11", at: 0)
        }
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
                                      hud: options.hud, asyncShaders: options.asyncShaders, extra: plan.dxvkOptions)
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

    /// Chromium helpers left behind when Steam was closed from its own window or crashed (nothing else would stop them).
    /// Only call when Steam is known to be stopped. Returns true if something was killed.
    @discardableResult
    public func reapOrphans() -> Bool {
        let before = SystemSampler.run("/bin/ps", ["-Ao", "command"]).lowercased()
        guard before.contains("steamwebhelper") else { return false }
        _ = SystemSampler.run("/usr/bin/pkill", ["-9", "-f", #"steamwebhelper(_real)?\.exe"#])
        return true
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
        let steam = try steam()
        if let wrapper = wrapperURL { _ = try? WebHelperWrapper.ensure(steamRoot: steam.steamRoot, wrapper: wrapper) }
        // A windowless start only works when a login is remembered; otherwise the user must see the sign-in window.
        _ = try steam.launchClient(silent: silent && steam.hasRememberedLogin)
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

    /// Installs a game from Stirred: starts Steam if needed, waits until it is signed in, then asks it to install.
    /// Steam still shows its own confirmation window ("Install"): the user accepts it there.
    /// Returns true if Stirred started Steam for this.
    @discardableResult
    public func install(appID: Int, onPhase: @Sendable (String) -> Void = { _ in }) async throws -> Bool {
        var started = false
        var since = Date.distantPast
        var timeout: TimeInterval = 240
        if steamState() == .stopped {
            let remembered = (try? steam().hasRememberedLogin) ?? false
            onPhase(remembered ? "Starting Steam…" : "Sign in to Steam in the window that opens…")
            if !remembered { timeout = 600 }
            since = Date(); started = true
            try startSteam(silent: true)
        }
        onPhase("Waiting for Steam…")
        guard await waitUntilSteamReady(since: since, timeout: timeout) else {
            throw StirredError.blocked("Steam did not finish starting. Use Open Steam to check that you are signed in.")
        }
        onPhase("Accept the install window Steam shows…")
        try requestInstall(appID: appID)
        return started
    }

    /// Stops Steam and every Wine process of the engine. Graceful first (`steam.exe -shutdown` lets Steam finish
    /// syncing cloud saves and playtime), then whatever is left is killed.
    public func quitSteam(graceful: Bool = true) async {
        guard let runner = try? runner() else { return }
        if graceful, steamState() != .stopped, let steam = try? steam(),
           let shutdown = try? runner.makeProcess(
               arguments: [steam.steamRoot.appendingPathComponent("Steam.exe").path, "-shutdown"],
               workingDirectory: steam.steamRoot) {
            try? shutdown.run()
            for _ in 0..<20 {
                if steamState() == .stopped { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        let server = runner.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        if let process = try? runner.makeProcess(arguments: [], extraEnvironment: [:]) {
            process.executableURL = server
            process.arguments = ["-k"]
            try? process.run()
            process.waitUntilExit()
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = SystemSampler.run("/usr/bin/pkill", ["-9", "-f", paths.engines.path])
        // Orphans whose command line is a Windows path (Steam's Chromium helpers) are not matched by the line above.
        _ = SystemSampler.run("/usr/bin/pkill", ["-9", "-f", #"steamwebhelper(_real)?\.exe"#])
    }

    /// Stops the game and everything started from its folder (launchers, helpers). Steam keeps showing "Stopping"
    /// as long as any process it tracks for the game is alive (e.g. Ubisoft Connect for Trackmania).
    /// After a game ended: remove what it left behind (launchers, helpers) and, if Stirred started Steam only for
    /// this game, close Steam too, unless the user keeps it or another game is still running.
    public func cleanUpAfterGame(_ game: Game, startedSteam: Bool, keepSteam: Bool, otherGamesRunning: Bool) async {
        stopGame(game)
        guard startedSteam, !keepSteam, !otherGamesRunning else { return }
        await quitSteam(graceful: true)
    }

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
        var timeout: TimeInterval = 240
        if steamState() == .stopped {
            let remembered = (try? steam().hasRememberedLogin) ?? false
            onPhase(remembered ? "Starting Steam…" : "Sign in to Steam in the window that opens…")
            if !remembered { timeout = 600 }
            since = Date()
            try startSteam(silent: true)
        }
        onPhase("Waiting for Steam…")
        guard await waitUntilSteamReady(since: since, timeout: timeout) else {
            throw StirredError.blocked("Steam did not finish starting. Use Open Steam to check that you are signed in.")
        }
        onPhase("Preparing graphics…")
        try await prepareGraphics(for: game, plan: plan, options: options)
        var recorder = try SessionRecorder.begin(
            game: game, plan: plan, engine: try engine().name, processNeedle: processNeedle(for: game), paths: paths)
        recorder.record.startedSteam = since != .distantPast
        try recorder.save()
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
            if started == nil, now.timeIntervalSince(waitStart) > Double(waitSeconds) { record.neverDetected = true; onEvent("game process never appeared"); return }
            if let started, now.timeIntervalSince(started) >= Double(maxSeconds) { return }
            var sample = SystemSampler.sample(processNeedle: needle, at: 0)
            if sample.processCount > 0 {
                if started == nil { started = now; record.neverDetected = false; onEvent("game detected") }
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
