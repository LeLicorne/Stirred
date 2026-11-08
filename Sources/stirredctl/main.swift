import Foundation
import StirredCore

// stirredctl: thin debug/CI front end over StirredCore's Launcher (the app uses the same code).

let launcher = Launcher()
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func options() -> LaunchOptions {
    var latency: LatencyProfile?
    if let i = args.firstIndex(of: "--latency"), i + 1 < args.count {
        guard let value = LatencyProfile(rawValue: args[i + 1]) else { fail("latency must be balanced, low or lowest") }
        latency = value
    }
    return LaunchOptions(latency: latency, hud: args.contains("--hud"), asyncShaders: args.contains("--async"),
                         launchMode: args.contains("--via-steam") ? .steam : (args.contains("--direct") ? .direct : nil))
}

func intOption(_ name: String, default value: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let n = Int(args[i + 1]) else { return value }
    return n
}

/// Accepts an appid ("1625450") or part of a name ("muck").
func findGame(_ query: String) throws -> Game {
    let games = try launcher.installedGames()
    if let exact = games.first(where: { $0.storeID == query }) { return exact }
    let matches = games.filter { $0.name.localizedCaseInsensitiveContains(query) }
    guard matches.count == 1, let game = matches.first else {
        fail(matches.isEmpty ? "No installed game matches '\(query)'. Try `stirredctl library`."
                             : "Several games match '\(query)': \(matches.map(\.name).joined(separator: ", "))")
    }
    return game
}

func printPlan(_ plan: LaunchPlan) {
    print("backend:  \(plan.backend.rawValue)   latency: \(plan.latency.rawValue)")
    if !plan.gameArguments.isEmpty { print("args:     \(plan.gameArguments.joined(separator: " "))") }
    for warning in plan.warnings + PowerAdvice.warnings(for: .current) { print("warning:  \(warning)") }
    if let reason = plan.blockedReason { print("BLOCKED:  \(reason)") }
}

func run() async throws {
    guard let command = args.first else {
        print("usage: stirredctl <setup|doctor|init-prefix|steam [--silent]|quit|uninstall <game> [--yes]|library|plan <game>|run <game> [--watch] [--keep-steam] [--latency P] [--hud] [--async]|report [dir]>")
        print("<game> is an appid or part of the name, e.g. `stirredctl run muck --watch`")
        return
    }
    switch command {
    case "doctor":
        print("macOS:     \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("memory:    \(HardwareProfile.current.memoryGB) GB")
        for warning in PowerAdvice.warnings(for: .current) { print("power:     \(warning)") }
        print("rosetta:   \(FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta") ? "installed" : "MISSING (softwareupdate --install-rosetta)")")
        print("root:      \(launcher.paths.root.path)")
        for item in launcher.setup.items() where !item.done { print("missing:   \(item.step.title): run `stirredctl setup`") }
        if let engine = try? launcher.engine() {
            let runner = try launcher.runner()
            print("engine:    \(engine.name)")
            print("prefix:    \(runner.isPrefixInitialised ? "ready" : "not initialised (run init-prefix)")")
            print("steam:     \(launcher.steamState())")
        } else {
            print("engine:    NONE (run Scripts/assemble-engine.sh)")
        }
    case "setup":
        // Installs everything that is missing: Wine, DXVK, the Windows environment, Steam. Safe to run again.
        for item in launcher.setup.items() { print("\(item.done ? "[x]" : "[ ]") \(item.step.title)") }
        try await launcher.setup.run { print($0) }
        print("Setup complete. Start Steam with `stirredctl steam` and sign in once.")
    case "init-prefix":
        try await launcher.runner().initialisePrefix(logFile: launcher.paths.logs.appendingPathComponent("wineboot.log"))
        print("prefix ready")
    case "steam":
        try launcher.startSteam(silent: args.contains("--silent"))
        print("Steam starting. Log: \(launcher.paths.logs.path)/steam-client.log")
    case "install":
        guard args.count > 1, let id = Int(args[1]) else { fail("usage: stirredctl install <appid>") }
        guard launcher.steamState() == .ready else { fail("Steam is not ready: start it first (`stirredctl steam`) and log in.") }
        try launcher.requestInstall(appID: id)
        print("Steam should now show an install dialog for app \(id): accept it there.")
    case "uninstall":
        // Shows what would be deleted; nothing is removed without --yes.
        guard args.count > 1 else { fail("usage: stirredctl uninstall <game> [--yes]") }
        let game = try findGame(args[1])
        let plan = try launcher.uninstallPlan(for: game)
        let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
        print("Would delete \(size) for \(game.name):")
        for url in plan.paths { print("  \(url.path)") }
        if args.contains("--yes") {
            let freed = try await launcher.uninstall(game) { print($0) }
            print("Uninstalled \(game.name), freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)).")
        } else {
            print("Run again with --yes to delete.")
        }
    case "quit":
        await launcher.quitSteam()
        print("Steam stopped")
    case "library":
        let games = try launcher.installedGames()
        if games.isEmpty { print("No installed games yet. Log in to Steam and install one."); return }
        for game in games { print("\(game.storeID)\t\(launcher.recipe(for: game)?.status.rawValue ?? "no-recipe")\t\(game.name)") }
    case "plan":
        guard args.count > 1 else { fail("usage: stirredctl plan <game>") }
        printPlan(launcher.plan(for: try findGame(args[1]), options: options()))
    case "run":
        guard args.count > 1 else { fail("usage: stirredctl run <game>") }
        let game = try findGame(args[1])
        let opts = options()
        printPlan(launcher.plan(for: game, options: opts))
        var recorder = try await launcher.play(game, options: opts) { print($0) }
        print("session: \(recorder.directory.path)")
        if args.contains("--watch") {
            await recorder.watch(maxSeconds: intOption("--seconds", default: 600), onEvent: { print($0) })
            print("report: \(try launcher.finish(&recorder).path)")
            let startedSteam = recorder.record.startedSteam ?? false
            await launcher.cleanUpAfterGame(game, startedSteam: startedSteam, keepSteam: args.contains("--keep-steam"), otherGamesRunning: false)
            if startedSteam && !args.contains("--keep-steam") { print("Steam closed (started by this run; use --keep-steam to leave it open)") }
        } else {
            print("tip: add --watch to sample CPU/GPU while you play, or run `stirredctl report` afterwards")
        }
    case "report":
        let dir = args.count > 1 ? URL(fileURLWithPath: args[1])
            : SessionRecorder.sessionsDirectory(launcher.paths).appendingPathComponent("latest").resolvingSymlinksInPath()
        var recorder = try SessionRecorder.load(dir)
        print(try String(contentsOf: try launcher.finish(&recorder), encoding: .utf8))
    default:
        fail("unknown command: \(command)")
    }
}

do { try await run() } catch { fail("error: \(error)") }
