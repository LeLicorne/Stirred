import Foundation

public enum DiagnosisSeverity: Int, Sendable, Comparable {
    case blocker = 0   // the game cannot work as things are
    case problem = 1   // something is wrong and can usually be fixed
    case advice = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What Stirred can do by itself, in one click.
public enum DiagnosisFix: Sendable, Equatable {
    case runSetup
    case addLaunchArgument(String)
    case setLaunchMode(LaunchMode)
    case reinstallGraphics
    case repairSteamDisplayFix
    case cleanUpProcesses

    public var label: String {
        switch self {
        case .runSetup: "Finish setup"
        case .addLaunchArgument(let argument): "Add \(argument)"
        case .setLaunchMode(let mode): mode == .direct ? "Start the game directly" : "Start through Steam"
        case .reinstallGraphics: "Reinstall the graphics layer"
        case .repairSteamDisplayFix: "Repair Steam's display fix"
        case .cleanUpProcesses: "Clean up stuck processes"
        }
    }
}

public struct Diagnosis: Sendable, Equatable, Identifiable {
    public var id: String
    public var severity: DiagnosisSeverity
    public var title: String
    public var explanation: String
    /// nil: nothing Stirred can change; the explanation says what the user can do.
    public var fix: DiagnosisFix?
}

/// Everything the rules look at, gathered once so the rules themselves are a pure, testable function.
public struct DiagnosisInput: Sendable {
    public var game: Game
    public var recipe: Recipe?
    public var plan: LaunchPlan
    public var power: PowerState
    public var setupComplete: Bool
    public var steamDisplayFixInstalled: Bool
    public var freeDiskBytes: Int64?
    /// Text of the game's recent logs: Unity Player.log, DXVK log, Steam's game-process log.
    public var logs: String
    public var lastSession: SessionRecord?
    public var lastSessionCrashed: Bool
    public var dxvkInstalledForGame: Bool
    public var isUnity: Bool
    public var executableArchitecture: PEArchitecture
    /// Wine processes alive although Steam itself is not running (left behind by a crash).
    public var staleProcessCount: Int

    public init(
        game: Game, recipe: Recipe? = nil, plan: LaunchPlan, power: PowerState = PowerState(lowPowerMode: false, onBattery: false),
        setupComplete: Bool = true, steamDisplayFixInstalled: Bool = true, freeDiskBytes: Int64? = nil, logs: String = "",
        lastSession: SessionRecord? = nil, lastSessionCrashed: Bool = false, dxvkInstalledForGame: Bool = true,
        isUnity: Bool = false, executableArchitecture: PEArchitecture = .x64, staleProcessCount: Int = 0
    ) {
        self.game = game; self.recipe = recipe; self.plan = plan; self.power = power; self.setupComplete = setupComplete
        self.steamDisplayFixInstalled = steamDisplayFixInstalled; self.freeDiskBytes = freeDiskBytes; self.logs = logs
        self.lastSession = lastSession; self.lastSessionCrashed = lastSessionCrashed; self.dxvkInstalledForGame = dxvkInstalledForGame
        self.isUnity = isUnity; self.executableArchitecture = executableArchitecture; self.staleProcessCount = staleProcessCount
    }
}

public enum Diagnoser {
    /// Known causes, most severe first. Always returns at least one entry.
    public static func diagnose(_ input: DiagnosisInput) -> [Diagnosis] {
        var out: [Diagnosis] = []
        let logs = input.logs
        let neverStarted = input.lastSession?.neverDetected == true

        if !input.setupComplete {
            out.append(Diagnosis(id: "setup", severity: .blocker, title: "Stirred is not fully set up",
                                 explanation: "Something Stirred needs (Wine, the graphics layer, the Windows environment or Steam) is missing.",
                                 fix: .runSetup))
        }
        if input.recipe?.status == .unsupported {
            out.append(Diagnosis(id: "unsupported", severity: .blocker, title: "This game is known not to work on macOS",
                                 explanation: input.recipe?.notes ?? "It has a known blocker that Stirred cannot work around.", fix: nil))
        }
        if logs.range(of: CompatVerdict.antiCheat, options: .regularExpression) != nil {
            out.append(Diagnosis(id: "anticheat", severity: .blocker, title: "An anti-cheat is in the way",
                                 explanation: "The logs mention Easy Anti-Cheat, BattlEye or similar. These cannot run on macOS and Stirred never tries to bypass them.",
                                 fix: nil))
        }
        if input.isUnity && input.executableArchitecture == .x86 && logs.contains("Crash!!!") {
            out.append(Diagnosis(id: "unity32", severity: .blocker, title: "32-bit Unity games crash at startup here",
                                 explanation: "This game is 32-bit Unity: it crashes inside UnityPlayer.dll under Wine on macOS (tested with two Wine builds). Only the developer or a newer Wine could fix it.",
                                 fix: nil))
        }
        if logs.contains("graphics device is Vulkan") {
            if input.plan.gameArguments.contains("-force-d3d11") {
                out.append(Diagnosis(id: "unity-vulkan-outside", severity: .problem, title: "The last run used Vulkan",
                                     explanation: "That run probably started from Steam's own window, where Stirred's fixes do not apply. Start the game from Stirred: it forces DirectX 11, which shows every texture.",
                                     fix: nil))
            } else {
                out.append(Diagnosis(id: "unity-vulkan", severity: .problem, title: "Unity used Vulkan: textures can be missing",
                                     explanation: "Through MoltenVK, Vulkan shows missing texture tiles. Forcing DirectX 11 (through DXVK) fixes it.",
                                     fix: .addLaunchArgument("-force-d3d11")))
            }
        }
        if input.plan.backend == .dxvk && !input.dxvkInstalledForGame {
            out.append(Diagnosis(id: "dxvk-missing", severity: .problem, title: "The graphics layer is not installed for this game",
                                 explanation: "Without DXVK the game falls back to Wine's own Direct3D, which cannot draw most modern games. Stirred installs DXVK when you press Play; this repairs it now.",
                                 fix: .reinstallGraphics))
        }
        if input.setupComplete && !input.steamDisplayFixInstalled {
            out.append(Diagnosis(id: "steam-display", severity: .problem, title: "Steam's display fix is missing",
                                 explanation: "Without it Steam's window can stay black or blank and Steam may hang on startup.",
                                 fix: .repairSteamDisplayFix))
        }
        if neverStarted && !input.lastSessionCrashed {
            if input.plan.launchMode == .steam {
                out.append(Diagnosis(id: "never-started", severity: .problem, title: "The game never started",
                                     explanation: "Steam may be waiting on a window of its own (for example \"Grab a controller\") that never gets an answer. Starting the game directly skips it.",
                                     fix: .setLaunchMode(.direct)))
            } else {
                out.append(Diagnosis(id: "never-started-direct", severity: .problem, title: "The game never started",
                                     explanation: "It was started directly and no game process appeared. Open Logs for the Steam and DXVK logs, or Activity for the last report.",
                                     fix: nil))
            }
        }
        if input.staleProcessCount > 0 {
            out.append(Diagnosis(id: "stale", severity: .problem, title: "Processes were left behind",
                                 explanation: "\(input.staleProcessCount) Wine process(es) are alive although Steam is not running, usually after a crash. They can block the next start.",
                                 fix: .cleanUpProcesses))
        }
        if input.power.lowPowerMode {
            out.append(Diagnosis(id: "low-power", severity: .problem, title: "macOS Low Power Mode is on",
                                 explanation: "It caps the CPU and GPU: games stay around 30 FPS whatever the settings. Turn it off in System Settings > Battery.",
                                 fix: nil))
        }
        if input.power.onBattery {
            out.append(Diagnosis(id: "battery", severity: .advice, title: "The Mac is on battery",
                                 explanation: "Plug in the charger for full performance.", fix: nil))
        }
        if let free = input.freeDiskBytes, free < 5_000_000_000 {
            out.append(Diagnosis(id: "disk", severity: .problem, title: "Almost no free disk space",
                                 explanation: "Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) left. Games and shader caches need room: uninstall something you do not play.",
                                 fix: nil))
        }
        let failures = LogCollector.count(of: "Failed to compile pipeline", in: logs)
        if failures >= 5 {
            out.append(Diagnosis(id: "pipelines", severity: .advice, title: "Some effects cannot be drawn (\(failures) shaders failed)",
                                 explanation: "MoltenVK refused to compile them (a Metal limitation). Objects or effects may be missing or invisible; nothing Stirred can change.",
                                 fix: nil))
        }
        if out.isEmpty {
            out.append(Diagnosis(id: "nothing", severity: .advice, title: "No known problem found",
                                 explanation: "Start the game from Stirred with the FPS overlay on and look at Activity afterwards. If it still misbehaves, copy the report and send it.",
                                 fix: nil))
        }
        return out.sorted { $0.severity < $1.severity }
    }

    /// Plain text for a bug report (no personal paths: logs are not included).
    public static func text(for game: Game, diagnoses: [Diagnosis], system: SystemInfo) -> String {
        var lines = ["Stirred diagnosis for \(game.name) (\(game.store) \(game.storeID))",
                     "\(system.chip), \(system.memoryGB) GB, macOS \(system.macOS), Low Power Mode \(system.lowPowerMode ? "on" : "off"), battery \(system.onBattery ? "yes" : "no")", ""]
        for d in diagnoses { lines.append("[\(d.severity)] \(d.title): \(d.explanation)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Gathering the facts and applying the fixes

extension Launcher {
    /// Recent log text for this game, whichever way it was started (Stirred or Steam's own window).
    func gameLogsText(for game: Game) -> String {
        guard let steam = try? steam() else { return "" }
        var parts: [String] = []
        let users = steam.runner.prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let folder = game.installDirectory?.lastPathComponent
        for log in LogCollector.files(named: "Player.log", under: users, after: .distantPast) {
            if let folder, let head = LogCollector.head(log), !head.localizedCaseInsensitiveContains(folder) { continue }
            if let text = LogCollector.tail(log, maxBytes: 64_000) { parts.append(text) }
        }
        let stem = processNeedle(for: game).lowercased().replacingOccurrences(of: ".exe", with: "")
        for url in LogCollector.recentFiles(in: paths.logs.appendingPathComponent("dxvk"), extension: "log", after: .distantPast)
        where url.lastPathComponent.lowercased().hasPrefix(stem) {
            if let text = LogCollector.tail(url, maxBytes: 32_000) { parts.append(text) }
        }
        if let text = LogCollector.tail(steam.steamRoot.appendingPathComponent("logs/gameprocess_log.txt"), maxBytes: 16_000) { parts.append(text) }
        return parts.joined(separator: "\n")
    }

    public func diagnosisInput(for game: Game) -> DiagnosisInput {
        let steamRoot = try? steam().steamRoot
        let plan = plan(for: game)
        let folder = game.installDirectory
        let executable = folder.flatMap { GameExecutableFinder.candidates(in: $0).first }
        let sessionDir = sessionDirectories().first { $0.lastPathComponent.hasSuffix("-\(game.storeID)") }
        let session = sessionDir.flatMap { try? SessionRecorder.load($0).record }
        let crashed = sessionDir.flatMap { try? String(contentsOf: $0.appendingPathComponent("report.md"), encoding: .utf8) }?
            .contains("Crash detected | YES") ?? false
        let free = (try? paths.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        var stale = 0
        if steamState() == .stopped {
            stale = SystemSampler.run("/bin/ps", ["-Ao", "command"]).split(separator: "\n")
                .filter { $0.contains("steamwebhelper") || $0.contains("\\steamapps\\common\\") }.count
        }
        return DiagnosisInput(
            game: game, recipe: recipe(for: game), plan: plan, power: .current, setupComplete: setup.isComplete,
            steamDisplayFixInstalled: steamRoot.map(WebHelperWrapper.isInstalled(steamRoot:)) ?? false,
            freeDiskBytes: free.map { Int64($0) }, logs: gameLogsText(for: game), lastSession: session, lastSessionCrashed: crashed,
            dxvkInstalledForGame: executable.map { exe in
                let dir = exe.deletingLastPathComponent()
                return ["d3d11.dll", "dxgi.dll"].allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            } ?? true,
            isUnity: folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("UnityPlayer.dll").path) } ?? false,
            executableArchitecture: executable.map { PEInfo.architecture(ofFile: $0) } ?? .unknown,
            staleProcessCount: stale)
    }

    public func diagnose(_ game: Game) -> [Diagnosis] { Diagnoser.diagnose(diagnosisInput(for: game)) }

    /// Applies one fix. Settings are saved as personal overrides, so they last.
    public func apply(_ fix: DiagnosisFix, to game: Game, onPhase: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let appID = game.steamAppID ?? 0
        switch fix {
        case .runSetup:
            try await setup.run(onProgress: onPhase)
        case .addLaunchArgument(let argument):
            try overrides.update(appID) { $0.launchArgs = ($0.launchArgs ?? []) + [argument] }
        case .setLaunchMode(let mode):
            try overrides.update(appID) { $0.launchMode = mode }
        case .reinstallGraphics:
            onPhase("Reinstalling the graphics layer…")
            try await prepareGraphics(for: game, plan: plan(for: game), options: LaunchOptions())
        case .repairSteamDisplayFix:
            guard let wrapper = wrapperURL else { throw StirredError.blocked("The display fix is missing from this build of Stirred.") }
            let steam = try steam()
            if steamState() != .stopped { onPhase("Closing Steam…"); await quitSteam(graceful: true) }
            onPhase("Repairing…")
            try WebHelperWrapper.ensure(steamRoot: steam.steamRoot, wrapper: wrapper)
        case .cleanUpProcesses:
            onPhase("Cleaning up…")
            await quitSteam(graceful: false)
            stopGame(game)
        }
    }
}
