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
        self.recipes = RecipeRepository(directory: recipesDirectory, userDirectory: paths.root.appendingPathComponent("recipes", isDirectory: true))
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

    /// The engine Steam currently runs under (it chose it when it started), else the preferred one.
    public func engine() throws -> Engine { try engine(forPrefix: "steam") }

    /// The engine a Windows environment currently runs under (chosen when its client or first game started), else the preferred one.
    public func engine(forPrefix prefix: String) throws -> Engine {
        if let name = ActiveEngine.read(paths, EngineLocator.sessionFile(forPrefix: prefix)) {
            let engine = Engine(directory: paths.engines.appendingPathComponent(name, isDirectory: true))
            if engine.wineBinary != nil { return engine }
        }
        guard let engine = EngineLocator.preferred(paths: paths) else { throw StirredError.engineNotFound }
        return engine
    }

    /// The engine a game needs: the optional DXMT one for the DXMT backend, the normal one otherwise.
    public func engine(for backend: GraphicsBackend) throws -> Engine {
        if backend == .dxmt {
            guard let engine = EngineLocator.dxmt(paths: paths) else {
                throw StirredError.blocked("The DXMT engine is not installed. Build it with Scripts/build-dxmt-engine.sh (see docs/DXMT.md).")
            }
            return engine
        }
        guard let engine = EngineLocator.preferred(paths: paths) else { throw StirredError.engineNotFound }
        return engine
    }

    public func runner() throws -> WineRunner { try runner(forPrefix: "steam") }

    public func runner(forPrefix prefix: String) throws -> WineRunner {
        try WineRunner(engine: try engine(forPrefix: prefix), prefix: paths.prefix(named: prefix))
    }

    /// The runner for the Windows environment a store's games live in.
    public func runner(forStore store: String) throws -> WineRunner { try runner(forPrefix: Stores.prefixName(forStore: store)) }
    public func steam() throws -> SteamProvider { SteamProvider(runner: try runner(), logsDirectory: paths.logs) }
    /// Steam also installs technical components that are not games (shown nowhere in Stirred).
    static let hiddenAppIDs: Set<String> = ["228980", "4099820"]   // Steamworks Common Redistributables, Ubisoft Connect Services

    public func installedGames() throws -> [Game] {
        try steam().installedGames().filter { !Self.hiddenAppIDs.contains($0.storeID) }
    }

    public var overrides: OverrideStore { OverrideStore(paths: paths) }

    /// The recipe with the user's personal settings (fixes applied by the diagnosis) on top.
    public func recipe(for game: Game) -> Recipe? {
        overrides.apply(to: recipes.recipe(for: game.key), game: game)
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
        let personalLatency = overrides.read(game.key).latency
        var plan = LaunchPlanner.plan(recipe: recipe, detectedAPIs: apis, latency: options.latency ?? personalLatency ?? preset?.latency)
        if let mode = options.launchMode { plan.launchMode = mode }
        // Unreal Engine games draw nothing in 3D through DXVK + MoltenVK (no geometry shaders) and default to DirectX 12, which
        // fails under Wine. Without a recipe choice: DirectX 11 (-dx11), and DXMT when the optional engine is installed.
        if recipe?.graphics == nil, Self.isUnreal(game.installDirectory) {
            if !plan.gameArguments.contains(where: { ["-dx11", "-dx12", "-d3d11", "-d3d12"].contains($0.lowercased()) }) {
                plan.gameArguments.insert("-dx11", at: 0)
            }
            if EngineLocator.dxmt(paths: paths) != nil {
                plan.backend = .dxmt
                plan.requiredComponents.removeAll { $0 == "dxvk" || $0 == "vkd3d-proton" }
                plan.warnings.append("Unreal Engine game: started with DXMT (Direct3D 11 to Metal) so the 3D scene is drawn.")
            } else {
                plan.backend = .dxvk
                plan.requiredComponents.removeAll { $0 == "vkd3d-proton" }
                if !plan.requiredComponents.contains("dxvk") { plan.requiredComponents.append("dxvk") }
                plan.warnings.append("Unreal Engine game: the 3D scene may stay black without the optional DXMT engine (docs/DXMT.md).")
            }
        }
        // Recipes are shared: without the optional DXMT engine, fall back to DXVK instead of failing.
        if plan.backend == .dxmt, EngineLocator.dxmt(paths: paths) == nil {
            plan.backend = .dxvk
            plan.requiredComponents = plan.requiredComponents.filter { $0 != "dxvk" } + ["dxvk"]
            plan.warnings.append("This game is best with the optional DXMT engine, which is not installed: using DXVK (3D scenes may stay black).")
        }
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

    /// Unreal games ship `<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe` next to an `Engine` folder.
    static func isUnreal(_ directory: URL?) -> Bool {
        guard let directory else { return false }
        return GameExecutableFinder.candidates(in: directory).contains { $0.lastPathComponent.hasSuffix("-Win64-Shipping.exe") }
    }

    // MARK: Graphics

    public var dxvkPackage: URL { paths.components.appendingPathComponent("dxvk-macos-1.10.3", isDirectory: true) }

    /// Installs DXVK next to each candidate executable and sets the per-executable Wine overrides. Returns log lines.
    @discardableResult
    public func prepareGraphics(for game: Game, plan: LaunchPlan, options: LaunchOptions) async throws -> [String] {
        if plan.backend == .dxmt { return try await prepareDXMT(for: game) }
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

    // MARK: Game updater

    /// DXMT: the engine's own Direct3D DLLs must win, so DXVK's copies and overrides are removed from the game's folder, and
    /// `winemetal.dll` (the bridge to Metal) is placed in the Windows system folders of the prefix.
    @discardableResult
    func prepareDXMT(for game: Game) async throws -> [String] {
        let engine = try engine(for: .dxmt)
        guard let lib = engine.libraryDirectory else { throw StirredError.engineNotFound }
        let prefix = paths.prefix(named: "steam")
        var lines: [String] = []
        for (source, target) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let from = lib.appendingPathComponent("\(source)/winemetal.dll")
            let to = prefix.appendingPathComponent("drive_c/windows/\(target)/winemetal.dll")
            guard FileManager.default.fileExists(atPath: from.path) else { throw StirredError.blocked("winemetal.dll missing in the DXMT engine.") }
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: from, to: to)
        }
        guard let dir = game.installDirectory else { return lines }
        let runner = try runner()
        for exe in GameExecutableFinder.candidates(in: dir) {
            let folder = exe.deletingLastPathComponent()
            var removed = false
            for name in DXVKInstaller.dlls + ["dxvk.conf"] {
                let file = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file); removed = true }
            }
            if removed {
                _ = try? await runner.runAndWait(arguments: ["reg", "delete", "HKCU\\Software\\Wine\\AppDefaults\\\(exe.lastPathComponent)", "/f"])
                lines.append("DXVK removed for \(exe.lastPathComponent)")
            }
        }
        lines.append("dxmt ready")
        return lines
    }

    public func updater(for game: Game) -> GameUpdater? { recipe(for: game)?.updater }

    /// Gets the game's own updater ready for Wine (see `GameUpdater`) and returns the lines describing what was done.
    @discardableResult
    public func prepareUpdater(for game: Game) async throws -> [String] {
        guard let updater = updater(for: game), let dir = game.installDirectory else {
            throw StirredError.blocked("\(game.name) has no updater known to Stirred.")
        }
        let exe = dir.appendingPathComponent(updater.executable)
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw StirredError.blocked("The updater \(updater.executable) is not in the game folder yet. Let Steam finish installing the game.")
        }
        guard FileManager.default.fileExists(atPath: dxvkPackage.path) else {
            throw StirredError.blocked("DXVK component missing at \(dxvkPackage.path).")
        }
        let arch = PEInfo.architecture(ofFile: exe)
        try DXVKInstaller.install(package: dxvkPackage, executable: exe, architecture: arch == .x86 ? .x86 : .x64,
                                  latency: .low, hud: false, asyncShaders: false, extra: [:])
        let runner = try runner()
        let key = "HKCU\\Software\\Wine\\AppDefaults\\\(exe.lastPathComponent)\\DllOverrides"
        var commands = DXVKInstaller.registryCommands(executableName: exe.lastPathComponent)
        for dll in updater.disabledDlls ?? [] { commands.append(["reg", "add", key, "/v", dll, "/d", "", "/f"]) }
        for command in commands { _ = try await runner.runAndWait(arguments: command) }
        return ["updater \(updater.executable) prepared (\(commands.count) settings)"]
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
    public func startSteam(silent: Bool, backend: GraphicsBackend? = nil) throws {
        // Steam and its games share one Wine: the engine is chosen here, once, and remembered until Steam stops.
        if let backend {
            let chosen = try engine(for: backend)
            try? ActiveEngine.write(paths, EngineLocator.steamEngineFile, value: chosen.name)
        } else if ActiveEngine.read(paths, EngineLocator.steamEngineFile) == nil, let preferred = EngineLocator.preferred(paths: paths) {
            try? ActiveEngine.write(paths, EngineLocator.steamEngineFile, value: preferred.name)
        }
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
        try? ActiveEngine.write(paths, EngineLocator.steamEngineFile, value: nil)
    }

    /// Stops the game and everything started from its folder (launchers, helpers). Steam keeps showing "Stopping"
    /// as long as any process it tracks for the game is alive (e.g. Ubisoft Connect for Trackmania).
    /// After a game ended: remove what it left behind (launchers, helpers) and, if Stirred started Steam only for
    /// this game, close Steam too, unless the user keeps it or another game is still running.
    public func cleanUpAfterGame(_ game: Game, startedSteam: Bool, keepSteam: Bool, otherGamesRunning: Bool) async {
        stopGame(game)
        backupGameData(.session)   // settings, controls and saves the game just wrote
        guard startedSteam, !keepSteam, !otherGamesRunning else { return }
        await quitSteam(graceful: true)
    }

    public func stopGame(_ game: Game) {
        for pattern in Self.stopPatterns(for: game, needle: processNeedle(for: game)) {
            _ = SystemSampler.run("/usr/bin/pkill", ["-f", pattern])
        }
    }

    /// Kills the game and everything started from its folder without letting it answer (SIGKILL). For a game stuck behind an
    /// error dialog or a hung window, where a normal stop is ignored.
    public func forceStopGame(_ game: Game) {
        for pattern in Self.stopPatterns(for: game, needle: processNeedle(for: game)) {
            _ = SystemSampler.run("/usr/bin/pkill", ["-9", "-f", pattern])
        }
    }

    /// Stop, then force-quit if the game is still there after `grace` seconds. Returns true if it had to be forced.
    @discardableResult
    public func stopGameEscalating(_ game: Game, grace: TimeInterval = 4) async -> Bool {
        stopGame(game)
        let needle = processNeedle(for: game)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if SystemSampler.sample(processNeedle: needle, at: 0).processCount == 0 { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard SystemSampler.sample(processNeedle: needle, at: 0).processCount > 0 else { return false }
        forceStopGame(game)
        return true
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
        // A game that needs the other engine (DXMT or not) than the one Steam runs under: restart Steam with the right one.
        let wanted = try engine(for: plan.backend).name
        if steamState() != .stopped, let running = ActiveEngine.read(paths, EngineLocator.steamEngineFile), running != wanted {
            onPhase("Restarting Steam with the \(plan.backend == .dxmt ? "DXMT" : "standard") engine…")
            await quitSteam(graceful: true)
        }
        if steamState() == .stopped {
            let remembered = (try? steam().hasRememberedLogin) ?? false
            onPhase(remembered ? "Starting Steam…" : "Sign in to Steam in the window that opens…")
            if !remembered { timeout = 600 }
            since = Date()
            try startSteam(silent: true, backend: plan.backend)
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
