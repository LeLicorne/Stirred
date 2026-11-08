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
        print("usage: stirredctl <setup|doctor|init-prefix|steam [--silent]|quit|owned [--refine N]|preset <game> [name]|diagnose <game> [--fix]|check <game>|uninstall <game> [--yes]|library|plan <game>|run <game> [--watch] [--keep-steam] [--latency P] [--hud] [--async]|report [dir]>")
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
    case "owned":
        // Every game this Steam install knows you own, ranked by compatibility. Instant and offline;
        // `--refine N` then asks the store about the N most promising ones (slow: Steam rate-limits).
        let (games, entries) = try launcher.libraryEntries()
        final class Updates: @unchecked Sendable {
            private let lock = NSLock()
            private var byID: [Int: LibraryEntry] = [:]
            func set(_ entry: LibraryEntry) { lock.lock(); byID[entry.appID] = entry; lock.unlock() }
            func get() -> [Int: LibraryEntry] { lock.lock(); defer { lock.unlock() }; return byID }
        }
        let updates = Updates()
        var current = entries
        if let i = args.firstIndex(of: "--refine"), i + 1 < args.count, let n = Int(args[i + 1]) {
            let limited = Array(current.filter(LibraryAnalysis.needsRefinement).prefix(n))
            let keep = Set(limited.map(\.appID))
            await LibraryAnalysis.refine(limited, games: games.filter { keep.contains($0.appID) }, recipes: launcher.recipes,
                                         cache: launcher.storeCache, client: StoreClient(), delay: 700_000_000,
                                         shouldStop: { false }) { updated, done, total in
                updates.set(updated)
                print("refined \(done)/\(total): \(updated.name) -> \(updated.verdict.level.rawValue)")
            }
        }
        let refinedByID = updates.get()
        current = current.map { refinedByID[$0.appID] ?? $0 }
        var counts: [VerdictLevel: Int] = [:]
        for e in current { counts[e.verdict.level, default: 0] += 1 }
        print("\(current.count) games owned (\(current.filter(\.installed).count) installed, \(current.filter(\.refined).count) with store details)")
        for level in [VerdictLevel.works, .native, .likely, .maybe, .unknown, .no] { print("  \(level.rawValue): \(counts[level] ?? 0)") }
        for level in [VerdictLevel.works, .likely, .native] {
            let names = current.filter { $0.verdict.level == level }.prefix(8).map(\.name)
            if !names.isEmpty { print("\(level.rawValue) e.g. " + names.joined(separator: ", ")) }
        }
    case "preset":
        // stirredctl preset <game> [faster|balanced|prettier|default]
        guard args.count > 1 else { fail("usage: stirredctl preset <game> [faster|balanced|prettier|default]") }
        let game = try findGame(args[1])
        if args.count > 2 {
            let names: [String: QualityPreset?] = ["faster": .performance, "balanced": .balanced, "prettier": .quality, "default": nil]
            guard let chosen = names[args[2].lowercased()] else { fail("preset must be faster, balanced, prettier or default") }
            try launcher.overrides.update(game.steamAppID ?? 0) { $0.preset = chosen }
        }
        let current = launcher.preset(for: game)
        print("\(game.name): \(current?.title ?? "no preset (recipe defaults)")   recommended for this Mac: \(PresetCatalog.recommended(for: .current).title)")
        printPlan(launcher.plan(for: game))
    case "diagnose":
        // What is wrong with this game? `--fix` applies every fix Stirred can do by itself.
        guard args.count > 1 else { fail("usage: stirredctl diagnose <game> [--fix]") }
        let game = try findGame(args[1])
        let found = launcher.diagnose(game)
        for d in found {
            print("[\(d.severity)] \(d.title)\n    \(d.explanation)")
            if let fix = d.fix { print("    fix: \(fix.label)") }
        }
        if args.contains("--fix") {
            for d in found { if let fix = d.fix {
                print("applying: \(fix.label)…")
                try await launcher.apply(fix, to: game) { print("  \($0)") }
            } }
            print("Done. Run `stirredctl diagnose` again to check.")
        }
    case "check":
        // Will it run? Works for games you do not own or have not installed. Name, app id or store link.
        guard args.count > 1 else { fail("usage: stirredctl check <name | appid | store link>") }
        let query = args.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " ")
        var appID = StoreClient.parseAppID(from: query)
        if appID == nil {
            let results = try await StoreClient().search(query)
            guard let best = StoreClient.bestMatch(results, for: query) else { fail("No game found for '\(query)'.") }
            let others = results.filter { $0.id != best.id }.prefix(4)
            if !others.isEmpty { print("Other matches: " + others.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")) }
            appID = best.id
        }
        guard let id = appID, let check = try await launcher.check(appID: id) else { fail("Steam has no public store page for that game.") }
        print("\(check.info.name) (\(check.info.appID))\(check.info.mac ? "  [Mac version exists]" : "")  Steam Deck: \(check.deck)")
        print("Verdict: \(check.verdict.level.rawValue.uppercased()): \(check.verdict.headline)")
        for reason in check.verdict.reasons { print("  - \(reason)") }
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
    case "update":
        guard args.count > 1 else { fail("usage: stirredctl update <game>") }
        let game = try findGame(args[1])
        guard let updater = launcher.updater(for: game) else { fail("\(game.name) has no updater known to Stirred.") }
        for line in try await launcher.prepareUpdater(for: game) { print(line) }
        print("Running \(updater.executable) through Steam; close it when it says the game is up to date.")
        var recorder = try await launcher.play(game, options: LaunchOptions(launchMode: .steam)) { print($0) }
        await recorder.watch(maxSeconds: intOption("--seconds", default: 3600), onEvent: { print($0) })
        _ = try? launcher.finish(&recorder)
        await launcher.cleanUpAfterGame(game, startedSteam: recorder.record.startedSteam ?? false, keepSteam: args.contains("--keep-steam"), otherGamesRunning: false)
    case "recipe":
        let sub = args.count > 1 ? args[1] : ""
        switch sub {
        case "export":
            guard args.count > 2 else { fail("usage: stirredctl recipe export <game> [--tested]") }
            let game = try findGame(args[2])
            let data = try launcher.exportRecipe(for: game, tested: args.contains("--tested"))
            print(String(decoding: data, as: UTF8.self))
        case "import":
            guard args.count > 2 else { fail("usage: stirredctl recipe import <file.json>") }
            let result = try launcher.importRecipe(from: try Data(contentsOf: URL(fileURLWithPath: args[2])))
            print("\(result.replaced ? "Replaced" : "Imported") recipe for \(result.recipe.name) (\(result.recipe.appid)), status \(result.recipe.status.rawValue), not verified.")
        case "list":
            let ids = launcher.recipes.importedAppIDs()
            if ids.isEmpty { print("No imported recipes.") }
            for id in ids { print("\(id)  \(launcher.recipes.importedRecipe(forSteamAppID: id)?.name ?? "?")") }
        case "remove":
            guard args.count > 2 else { fail("usage: stirredctl recipe remove <game or appid>") }
            let id = try Int(args[2]) ?? findGame(args[2]).steamAppID ?? 0
            try launcher.recipes.removeImported(id)
            print("Removed the imported recipe for \(id) (the bundled one, if any, applies again).")
        default: fail("usage: stirredctl recipe export|import|list|remove")
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
