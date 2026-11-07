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

func plan(for game: Game) -> LaunchPlan {
    let recipe = game.steamAppID.flatMap { recipeRepository().recipe(forSteamAppID: $0) }
    let apis = GraphicsDetector.detect(executables: executables(in: game.installDirectory))
    return LaunchPlanner.plan(recipe: recipe, detectedAPIs: apis)
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
        try DXVKInstaller.install(package: package, executable: exe, architecture: arch)
        for command in DXVKInstaller.registryCommands(executableName: exe.lastPathComponent) {
            _ = try await runner.runAndWait(arguments: command)
        }
        print("dxvk installed for \(exe.lastPathComponent) (\(arch))")
    }
}

func printPlan(_ plan: LaunchPlan) {
    print("backend:  \(plan.backend.rawValue)")
    print("env:      \(plan.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    if !plan.gameArguments.isEmpty { print("args:     \(plan.gameArguments.joined(separator: " "))") }
    if !plan.requiredComponents.isEmpty { print("needs:    \(plan.requiredComponents.joined(separator: ", "))") }
    for warning in plan.warnings { print("warning:  \(warning)") }
    if let reason = plan.blockedReason { print("BLOCKED:  \(reason)") }
}

func run() async throws {
    guard let command = args.first else {
        print("usage: stirredctl <doctor|init-prefix|steam|library|plan <appid>|run <appid>>")
        return
    }
    switch command {
    case "doctor":
        print("macOS:     \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("memory:    \(HardwareProfile.current.memoryGB) GB")
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
        let process = try makeSteam().launch(game, plan: launchPlan)
        print("launch requested (pid \(process.processIdentifier)); log: \(paths.logs.path)/game-\(game.storeID).log")
    default:
        fail("unknown command: \(command)")
    }
}

do {
    try await run()
} catch {
    fail("error: \(error)")
}
