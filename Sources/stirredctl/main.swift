import Foundation
import StirredCore

// stirredctl: thin debug/CI front end over StirredCore.
// Usage: stirredctl <doctor|init-prefix|steam|library|plan|run> [args]

let paths = StirredPaths()
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Recipes live next to the sources; override with STIRRED_RECIPES.
func recipeRepository() -> RecipeRepository {
    let override = ProcessInfo.processInfo.environment["STIRRED_RECIPES"]
    let dir = override ?? FileManager.default.currentDirectoryPath + "/recipes"
    return RecipeRepository(directory: URL(fileURLWithPath: dir))
}

func makeRunner() throws -> WineRunner {
    guard let engine = EngineLocator.preferred(paths: paths) else { throw StirredError.engineNotFound }
    return try WineRunner(engine: engine, prefix: paths.prefix(named: "steam"))
}

func makeSteam() throws -> SteamProvider {
    SteamProvider(runner: try makeRunner(), logsDirectory: paths.logs)
}

func executables(in directory: URL?, maxDepth: Int = 2) -> [URL] {
    guard let directory,
          let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    var found: [URL] = []
    for case let url as URL in walker {
        if url.pathComponents.count - directory.pathComponents.count > maxDepth { walker.skipDescendants(); continue }
        if url.pathExtension.lowercased() == "exe" { found.append(url) }
    }
    return found
}

/// `--latency balanced|low|lowest` anywhere in the arguments.
func latencyOption() -> LatencyProfile? {
    guard let i = args.firstIndex(of: "--latency"), i + 1 < args.count else { return nil }
    guard let value = LatencyProfile(rawValue: args[i + 1]) else { fail("latency must be balanced, low or lowest") }
    return value
}

func plan(for game: Game) -> LaunchPlan {
    let recipe = game.steamAppID.flatMap { recipeRepository().recipe(forSteamAppID: $0) }
    let apis = GraphicsDetector.detect(executables: executables(in: game.installDirectory))
    return LaunchPlanner.plan(recipe: recipe, detectedAPIs: apis, latency: latencyOption())
}

func findInstalledGame(_ appID: String) throws -> Game {
    guard let game = try makeSteam().installedGames().first(where: { $0.storeID == appID }) else {
        fail("App \(appID) is not installed in the Steam prefix. Install it from the Steam window first.")
    }
    return game
}

/// Installs the graphics backend for this game: DXVK DLLs next to each candidate executable + per-exe Wine overrides.
func prepareGraphics(for game: Game, plan: LaunchPlan) async throws {
    guard plan.backend == .dxvk, let dir = game.installDirectory else { return }
    let package = paths.components.appendingPathComponent("dxvk-macos-1.10.3", isDirectory: true)
    guard FileManager.default.fileExists(atPath: package.path) else {
        fail("DXVK component missing at \(package.path). Run Scripts/install-components.sh")
    }
    let runner = try makeRunner()
    for exe in GameExecutableFinder.candidates(in: dir) {
        let arch = PEInfo.architecture(ofFile: exe)
        guard arch == .x86 || arch == .x64 else { continue }
        try DXVKInstaller.install(package: package, executable: exe, architecture: arch, latency: plan.latency,
                                    hud: args.contains("--hud"), asyncShaders: args.contains("--async"))
        for command in DXVKInstaller.registryCommands(executableName: exe.lastPathComponent) {
            _ = try await runner.runAndWait(arguments: command)
        }
        print("dxvk installed for \(exe.lastPathComponent) (\(arch))")
    }
}

/// Samples the game's processes every 3 s: waits for the process to appear, stops when it exits or after `maxSeconds`.
func watchSession(_ recorder: inout SessionRecorder, maxSeconds: Int) async {
    let needle = recorder.record.processNeedle
    let waitStart = Date()
    var started: Date?
    var misses = 0
    while true {
        let now = Date()
        if started == nil, now.timeIntervalSince(waitStart) > 120 { print("game process never appeared"); return }
        if let started, now.timeIntervalSince(started) >= Double(maxSeconds) { return }
        let sample = SystemSampler.sample(processNeedle: needle, at: started.map { now.timeIntervalSince($0) } ?? 0)
        if sample.processCount > 0 {
            if started == nil { started = now; print("game detected, sampling every 3 s (max \(maxSeconds) s)...") }
            misses = 0
            var s = sample; s.t = now.timeIntervalSince(started ?? now)
            recorder.add(s)
        } else if started != nil {
            misses += 1
            if misses >= 2 { print("game exited"); return }
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
}

func intOption(_ name: String, default value: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let n = Int(args[i + 1]) else { return value }
    return n
}

func printPlan(_ plan: LaunchPlan) {
    print("backend:  \(plan.backend.rawValue)   latency: \(plan.latency.rawValue)")
    print("env:      \(plan.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    if !plan.gameArguments.isEmpty { print("args:     \(plan.gameArguments.joined(separator: " "))") }
    if !plan.requiredComponents.isEmpty { print("needs:    \(plan.requiredComponents.joined(separator: ", "))") }
    for warning in plan.warnings + PowerAdvice.warnings(for: .current) { print("warning:  \(warning)") }
    if let reason = plan.blockedReason { print("BLOCKED:  \(reason)") }
}

func run() async throws {
    guard let command = args.first else {
        print("usage: stirredctl <doctor|init-prefix|steam|library|plan <appid>|run <appid> [--watch] [--latency P] [--hud] [--async]|report [dir]>")
        return
    }
    switch command {
    case "doctor":
        print("macOS:     \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("memory:    \(HardwareProfile.current.memoryGB) GB")
        for warning in PowerAdvice.warnings(for: .current) { print("power:     \(warning)") }
        print("rosetta:   \(FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta") ? "installed" : "MISSING (softwareupdate --install-rosetta)")")
        print("root:      \(paths.root.path)")
        if let engine = EngineLocator.preferred(paths: paths) {
            print("engine:    \(engine.name)")
            let runner = try WineRunner(engine: engine, prefix: paths.prefix(named: "steam"))
            print("prefix:    \(runner.isPrefixInitialised ? "ready" : "not initialised (run init-prefix)")")
            print("steam:     \(SteamProvider(runner: runner, logsDirectory: paths.logs).isInstalled ? "installed" : "not installed")")
        } else {
            print("engine:    NONE")
        }
    case "init-prefix":
        try await makeRunner().initialisePrefix(logFile: paths.logs.appendingPathComponent("wineboot.log"))
        print("prefix ready")
    case "steam":
        let process = try makeSteam().launchClient()
        print("Steam started (pid \(process.processIdentifier)); log: \(paths.logs.path)/steam-client.log")
    case "library":
        let games = try makeSteam().installedGames()
        if games.isEmpty { print("No installed games yet. Log in to Steam and install one."); return }
        for game in games {
            let status = recipeRepository().recipe(forSteamAppID: Int(game.storeID) ?? 0)?.status.rawValue ?? "no-recipe"
            print("\(game.storeID)\t\(status)\t\(game.name)")
        }
    case "plan":
        guard args.count > 1 else { fail("usage: stirredctl plan <appid>") }
        printPlan(plan(for: try findInstalledGame(args[1])))
    case "run":
        guard args.count > 1 else { fail("usage: stirredctl run <appid>") }
        let game = try findInstalledGame(args[1])
        let launchPlan = plan(for: game)
        printPlan(launchPlan)
        try await prepareGraphics(for: game, plan: launchPlan)
        let needle = GameExecutableFinder.candidates(in: game.installDirectory ?? paths.root).first?.lastPathComponent ?? game.name
        var recorder = try SessionRecorder.begin(
            game: game, plan: launchPlan, engine: (EngineLocator.preferred(paths: paths)?.name ?? "unknown"),
            processNeedle: needle, paths: paths)
        let process = try makeSteam().launch(game, plan: launchPlan)
        print("launch requested (pid \(process.processIdentifier)); session: \(recorder.directory.path)")
        if args.contains("--watch") {
            await watchSession(&recorder, maxSeconds: intOption("--seconds", default: 600))
            let report = try recorder.finish(paths: paths, prefix: try makeRunner().prefix)
            print("report: \(report.path)")
        } else {
            print("tip: add --watch to sample CPU/GPU while you play, or run `stirredctl report` afterwards")
        }
    case "report":
        // stirredctl report [session-directory]   (default: latest session)
        let dir = args.count > 1 ? URL(fileURLWithPath: args[1])
            : SessionRecorder.sessionsDirectory(paths).appendingPathComponent("latest").resolvingSymlinksInPath()
        var recorder = try SessionRecorder.load(dir)
        let report = try recorder.finish(paths: paths, prefix: try makeRunner().prefix)
        print(try String(contentsOf: report, encoding: .utf8))
    default:
        fail("unknown command: \(command)")
    }
}

do {
    try await run()
} catch {
    fail("error: \(error)")
}
