import Foundation
import Testing
@testable import StirredCore

@Suite("VDF parser")
struct VDFTests {
    @Test func parsesAppManifest() throws {
        let text = """
        "AppState"
        {
            "appid"        "480"
            "name"        "Spacewar"
            "installdir"    "Spacewar"
            "UserConfig"
            {
                "language"    "english"
            }
        }
        """
        let doc = try VDF.parse(text)
        #expect(doc["AppState"]?["appid"]?.stringValue == "480")
        #expect(doc["AppState"]?["UserConfig"]?["language"]?.stringValue == "english")
    }

    @Test func handlesEscapesAndComments() throws {
        let doc = try VDF.parse("// comment\n\"k\" \"a\\\\b\\\"c\"")
        #expect(doc["k"]?.stringValue == "a\\b\"c")
    }

    @Test func rejectsUnterminatedBlock() {
        #expect(throws: VDFError.self) { try VDF.parse("\"a\" { \"b\" \"c\"") }
    }
}

@Suite("Graphics detection")
struct GraphicsDetectionTests {
    @Test func findsDirectXVersions() {
        let data = Data("junk D3D11.dll more d3d12.dll end".utf8)
        let apis = GraphicsDetector.detect(in: data)
        #expect(apis == [.d3d11, .d3d12])
    }

    @Test func emptyBinaryHasNoAPI() {
        #expect(GraphicsDetector.detect(in: Data("nothing here".utf8)).isEmpty)
    }
}

@Suite("LaunchPlanner")
struct LaunchPlannerTests {
    let hw = HardwareProfile(memoryGB: 16)

    @Test func dx11DefaultsToDXVK() {
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [.d3d11], hardware: hw)
        #expect(plan.backend == .dxvk)
        #expect(plan.requiredComponents == ["dxvk"])
        #expect(plan.environment["WINEMSYNC"] == "1")
    }

    @Test func dx9UsesDXVKAndNeedsIt() {
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [.d3d9], hardware: hw)
        #expect(plan.backend == .dxvk)
        #expect(plan.requiredComponents == ["dxvk"])
    }

    @Test func dx12IsExperimentalWithMemoryWarning() {
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [.d3d12], hardware: hw)
        #expect(plan.backend == .vkd3d)
        #expect(plan.warnings.contains { $0.contains("experimental") })
        #expect(plan.warnings.contains { $0.contains("16 GB") })
    }

    @Test func unsupportedRecipeBlocks() {
        let recipe = Recipe(appid: 1, name: "Cheaty", status: .unsupported, blockers: ["eac"])
        let plan = LaunchPlanner.plan(recipe: recipe, detectedAPIs: [.d3d11], hardware: hw)
        #expect(plan.blockedReason?.contains("eac") == true)
    }

    @Test func recipeOverridesBackendEnvAndArgs() {
        let recipe = Recipe(
            appid: 730, name: "CS2", status: .offlineOnly, graphics: .dxvk,
            env: ["FOO": "bar"], dllOverrides: ["dinput8": "n,b"], launchArgs: ["-insecure"])
        let plan = LaunchPlanner.plan(recipe: recipe, detectedAPIs: [.d3d11], hardware: hw, hud: true)
        #expect(plan.backend == .dxvk)
        #expect(plan.environment["FOO"] == "bar")
        #expect(plan.environment["WINEDLLOVERRIDES"] == "dinput8=n,b")
        #expect(plan.environment["MTL_HUD_ENABLED"] == "1")
        #expect(plan.gameArguments == ["-insecure"])
        #expect(plan.blockedReason == nil)
    }
}

@Suite("Recipes")
struct RecipeTests {
    @Test func decodesSnakeCaseJSON() throws {
        let json = """
        {"appid": 730, "name": "CS2", "status": "offline-only", "verified": false,
         "dll_overrides": {"a": "n"}, "launch_args": ["-insecure"]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let recipe = try decoder.decode(Recipe.self, from: Data(json.utf8))
        #expect(recipe.status == .offlineOnly)
        #expect(recipe.dllOverrides == ["a": "n"])
        #expect(recipe.launchArgs == ["-insecure"])
    }

    @Test func repositoryReadsSeedRecipes() throws {
        // Tests run from the package root.
        let repo = RecipeRepository(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/recipes"))
        let cs2 = try #require(repo.recipe(forSteamAppID: 730))
        #expect(cs2.status == .offlineOnly)
        #expect(cs2.launchArgs == ["-insecure"])
    }
}

@Suite("Steam library scan")
struct SteamScanTests {
    @Test func listsInstalledGamesFromManifests() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-test-\(UUID().uuidString)")
        let steamapps = tmp.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try """
        "AppState" { "appid" "480" "name" "Spacewar" "installdir" "Spacewar" }
        """.write(to: steamapps.appendingPathComponent("appmanifest_480.acf"), atomically: true, encoding: .utf8)
        // A fake engine layout so WineRunner can be created.
        let engineDir = tmp.appendingPathComponent("engine/bin")
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        let wine = engineDir.appendingPathComponent("wine")
        try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

        let runner = try WineRunner(engine: Engine(directory: tmp.appendingPathComponent("engine")), prefix: tmp)
        let games = try SteamProvider(runner: runner, logsDirectory: tmp).installedGames()
        #expect(games.count == 1)
        #expect(games.first?.name == "Spacewar")
        #expect(games.first?.steamAppID == 480)
    }
}

@Suite("Graphics setup")
struct GraphicsSetupTests {
    private func pe(machine: UInt16) -> Data {
        var d = Data(count: 0x100)
        d[0] = 0x4D; d[1] = 0x5A; d[0x3C] = 0x80
        d[0x80] = 0x50; d[0x81] = 0x45
        d[0x84] = UInt8(machine & 0xFF); d[0x85] = UInt8(machine >> 8)
        return d
    }

    @Test func detectsPEArchitecture() {
        #expect(PEInfo.architecture(of: pe(machine: 0x014C)) == .x86)
        #expect(PEInfo.architecture(of: pe(machine: 0x8664)) == .x64)
        #expect(PEInfo.architecture(of: Data("not a pe".utf8)) == .unknown)
    }

    @Test func registryCommandsTargetOnlyThatExecutable() {
        let commands = DXVKInstaller.registryCommands(executableName: "Game.exe")
        #expect(commands.count == 3)
        #expect(commands[0][2] == "HKCU\\Software\\Wine\\AppDefaults\\Game.exe\\DllOverrides")
        #expect(commands.map { $0[4] } == ["d3d11", "dxgi", "d3d10core"])
    }

    @Test func installCopiesTheRightArchitecture() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-dxvk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pkg = tmp.appendingPathComponent("pkg"), game = tmp.appendingPathComponent("game")
        for arch in ["x32", "x64"] {
            try FileManager.default.createDirectory(at: pkg.appendingPathComponent(arch), withIntermediateDirectories: true)
            for dll in DXVKInstaller.dlls { try Data(arch.utf8).write(to: pkg.appendingPathComponent("\(arch)/\(dll)")) }
        }
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let exe = game.appendingPathComponent("g.exe")
        let copied = try DXVKInstaller.install(package: pkg, executable: exe, architecture: .x86)
        #expect(copied.count == 3)
        #expect(try String(contentsOf: game.appendingPathComponent("d3d11.dll"), encoding: .utf8) == "x32")
        #expect(throws: StirredError.self) { try DXVKInstaller.install(package: pkg, executable: exe, architecture: .unknown) }
    }

    @Test func finderSkipsCrashHandlersAndInstallers() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-find-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for n in ["Game.exe", "UnityCrashHandler32.exe", "unins000.exe", "readme.txt"] {
            try Data().write(to: tmp.appendingPathComponent(n))
        }
        #expect(GameExecutableFinder.candidates(in: tmp).map(\.lastPathComponent) == ["Game.exe"])
    }
}

@Suite("Latency profiles")
struct LatencyTests {
    @Test func profilesRenderExpectedSettings() {
        #expect(DXVKConfig.render(latency: .balanced).contains("dxgi.maxFrameLatency = 2"))
        #expect(DXVKConfig.render(latency: .low).contains("dxgi.maxFrameLatency = 1"))
        let lowest = DXVKConfig.render(latency: .lowest)
        #expect(lowest.contains("dxgi.syncInterval = 0") && lowest.contains("dxgi.tearFree = False"))
    }

    @Test func hudAndAsyncAreOptIn() {
        let plain = DXVKConfig.render(latency: .low)
        #expect(!plain.contains("hud") && !plain.contains("enableAsync"))
        let full = DXVKConfig.render(latency: .low, hud: true, asyncShaders: true)
        #expect(full.contains("dxvk.hud = fps,frametimes") && full.contains("dxvk.enableAsync = True"))
    }

    @Test func plannerDefaultsToLowAndRecipeOverrides() {
        #expect(LaunchPlanner.plan(recipe: nil, detectedAPIs: [.d3d11], hardware: HardwareProfile(memoryGB: 16)).latency == .low)
        let recipe = Recipe(appid: 1, name: "X", status: .playable, latency: .lowest)
        #expect(LaunchPlanner.plan(recipe: recipe, detectedAPIs: [], hardware: HardwareProfile(memoryGB: 16)).latency == .lowest)
        #expect(LaunchPlanner.plan(recipe: recipe, detectedAPIs: [], hardware: HardwareProfile(memoryGB: 16), latency: .balanced).latency == .balanced)
    }
}

@Suite("Power advice")
struct PowerAdviceTests {
    @Test func warnsOnLowPowerAndBattery() {
        let both = PowerAdvice.warnings(for: PowerState(lowPowerMode: true, onBattery: true))
        #expect(both.count == 2)
        #expect(PowerAdvice.warnings(for: PowerState(lowPowerMode: false, onBattery: false)).isEmpty)
    }
}

@Suite("Log rotation")
struct LogRotationTests {
    @Test func rotatesOnlyOversizedLogs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let log = tmp.appendingPathComponent("a.log")
        try Data(count: 100).write(to: log)
        #expect(LogRotation.rotateIfNeeded(log, maxBytes: 1000) == false)
        try Data(count: 5000).write(to: log)
        #expect(LogRotation.rotateIfNeeded(log, maxBytes: 1000) == true)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
    }
}

@Suite("Session report")
struct SessionReportTests {
    @Test func parsesGPUUtilization() {
        let io = "| | \"PerformanceStatistics\" = {\"Tiler Utilization %\"=39,\"Device Utilization %\"=46,\"Renderer Utilization %\"=45}"
        #expect(SystemSampler.parseGPUUtilization(io) == 46)
        #expect(SystemSampler.parseGPUUtilization("nothing") == nil)
    }

    @Test func parsesProcessTotals() {
        let ps = """
          %CPU   RSS COMMAND
          80.5 204800 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Muck\\Muck.exe -x
          20.0 102400 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Muck\\UnityCrashHandler64.exe
           5.0   1024 /usr/bin/other
        """
        let t = SystemSampler.parseProcesses(ps, containing: "Muck.exe")
        #expect(t.count == 1 && t.cpu == 80.5 && t.rssMB == 200)
    }

    @Test func redactsUserNameAndHome() {
        let r = Redactor(home: "/Users/jo", user: "jo")
        let out = r.redact("/Users/jo/Library/x and C:\\users\\jo\\AppData\\y and /Users/jo")
        #expect(!out.contains("jo\\") && !out.contains("/Users/jo"))
        #expect(out.contains("~/Library/x") && out.contains("C:\\users\\<user>\\AppData"))
    }

    private func record(cpu: Double, gpu: Int, lowPower: Bool = false) -> SessionRecord {
        let samples = (0..<5).map { SessionSample(t: Double($0) * 3, gpuPercent: gpu, cpuPercent: cpu, rssMB: 500, processCount: 2) }
        return SessionRecord(
            gameName: "G", store: "steam", storeID: "1", backend: "dxvk", latency: "low", engine: "e",
            processNeedle: "G.exe", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60),
            environment: [:], planWarnings: [],
            system: SystemInfo(macOS: "27", chip: "Apple M4", memoryGB: 16, lowPowerMode: lowPower, onBattery: false),
            samples: samples)
    }

    @Test func findingsClassifyBottlenecks() {
        #expect(ReportBuilder.findings(for: record(cpu: 40, gpu: 95), crashDetected: false).contains { $0.contains("GPU-bound") })
        #expect(ReportBuilder.findings(for: record(cpu: 99, gpu: 30), crashDetected: false).contains { $0.contains("CPU-bound") })
        #expect(ReportBuilder.findings(for: record(cpu: 30, gpu: 30), crashDetected: false).contains { $0.contains("Neither") })
        #expect(ReportBuilder.findings(for: record(cpu: 30, gpu: 30, lowPower: true), crashDetected: true).count >= 3)
    }

    @Test func recorderWritesReportWithRedactedExcerpts() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-sess-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = StirredPaths(root: tmp)
        let prefix = paths.prefix(named: "steam")
        let logDir = prefix.appendingPathComponent("drive_c/users/jo/AppData/LocalLow/Dev/Game")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try "Initialize engine\nDirect3D 11\nCrash!!!\nC:\\users\\jo\\secret".write(
            to: logDir.appendingPathComponent("Player.log"), atomically: true, encoding: .utf8)

        let game = Game(store: "steam", storeID: "42", name: "Demo", installDirectory: nil)
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [.d3d11], hardware: HardwareProfile(memoryGB: 16))
        let system = SystemInfo(macOS: "27", chip: "Apple M4", memoryGB: 16, lowPowerMode: false, onBattery: false)
        var rec = try SessionRecorder.begin(
            game: game, plan: plan, engine: "e", processNeedle: "Demo.exe", paths: paths,
            system: system, now: Date().addingTimeInterval(-30))
        let report = try rec.finish(paths: paths, prefix: prefix, redactor: Redactor(home: "/Users/jo", user: "jo"))

        let md = try String(contentsOf: report, encoding: .utf8)
        #expect(md.contains("Crash detected | YES"))
        #expect(md.contains("Direct3D 11"))
        let excerpt = try String(contentsOf: rec.directory.appendingPathComponent("excerpts/unity-Player.log"), encoding: .utf8)
        #expect(excerpt.contains("<user>") && !excerpt.contains("users\\jo"))
        let loaded = try SessionRecorder.load(rec.directory)
        #expect(loaded.record.storeID == "42")
        #expect(FileManager.default.fileExists(atPath: rec.directory.deletingLastPathComponent().appendingPathComponent("latest").path))
    }
}

@Suite("Launcher helpers")
struct LauncherHelperTests {
    @Test func detectsSteamClientProcessOnly() {
        let ps = """
        C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe --type=gpu
        C:\\Program Files (x86)\\Common Files\\Steam\\steamservice.exe /RunAsService
        C:\\Program Files (x86)\\Steam\\steamapps\\common\\Muck\\Muck.exe
        """
        #expect(!Launcher.isSteamClientRunning(psOutput: ps))
        #expect(Launcher.isSteamClientRunning(psOutput: ps + "\nC:\\Program Files (x86)\\Steam\\steam.exe -no-cef-sandbox"))
    }

    @Test func readsLoggedOnStateFromTheLastStateLine() {
        let on = "[t] [Connecting, 4, 7] x\n[t] [Logging On, 4, 7] y\n[t] [Logged On, 4, 7] z\n[t] unrelated line"
        #expect(Launcher.isLoggedOn(connectionLogTail: on))
        let off = on + "\n[t] [Logged Off, 0, 0] bye"
        #expect(!Launcher.isLoggedOn(connectionLogTail: off))
        #expect(!Launcher.isLoggedOn(connectionLogTail: "nothing useful"))
    }
}

@Suite("Report accuracy")
struct ReportAccuracyTests {
    private func setup() throws -> (StirredPaths, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-acc-\(UUID().uuidString)")
        let paths = StirredPaths(root: tmp)
        let prefix = paths.prefix(named: "steam")
        let users = prefix.appendingPathComponent("drive_c/users/jo/AppData/LocalLow")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        return (paths, prefix, users)
    }

    @Test func ignoresOtherGamesLogsAndSteamDumps() throws {
        let (paths, prefix, users) = try setup()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let mine = users.appendingPathComponent("A/Muck"), other = users.appendingPathComponent("B/Cat")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "Mono path[0] = 'C:/Steam/steamapps/common/Muck/Muck_Data'\nall good".write(
            to: mine.appendingPathComponent("Player.log"), atomically: true, encoding: .utf8)
        try "Mono path[0] = 'C:/Steam/steamapps/common/Cat Purrtrol/x'\nCrash!!!".write(
            to: other.appendingPathComponent("Player.log"), atomically: true, encoding: .utf8)
        let dumps = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/dumps")
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        try Data().write(to: dumps.appendingPathComponent("assert_steam.exe_1.dmp"))

        let game = Game(store: "steam", storeID: "1", name: "Muck",
                        installDirectory: URL(fileURLWithPath: "/x/steamapps/common/Muck"))
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [], hardware: HardwareProfile(memoryGB: 16))
        let system = SystemInfo(macOS: "27", chip: "M4", memoryGB: 16, lowPowerMode: false, onBattery: false)
        var rec = try SessionRecorder.begin(game: game, plan: plan, engine: "e", processNeedle: "Muck.exe",
                                            paths: paths, system: system, now: Date().addingTimeInterval(-30))
        let report = try rec.finish(paths: paths, prefix: prefix, redactor: Redactor(home: "/Users/jo", user: "jo"))
        let md = try String(contentsOf: report, encoding: .utf8)
        #expect(md.contains("Crash detected | no"))
        #expect(!md.contains("assert_steam"))
    }

    @Test func countsGraphicsProblemsAndParsesFindings() {
        let rec = SessionRecord(
            gameName: "G", store: "steam", storeID: "1", backend: "dxvk", latency: "low", engine: "e",
            processNeedle: "G.exe", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
            environment: [:], planWarnings: [],
            system: SystemInfo(macOS: "27", chip: "M4", memoryGB: 16, lowPowerMode: false, onBattery: false), samples: [])
        let md = ReportBuilder.markdown(record: rec, crashDetected: false, newDumps: [], keyLines: [],
                                        excerptNames: [], problems: ["pipeline compile failures": 3])
        let found = ReportBuilder.findingsSection(of: md)
        #expect(found.contains { $0.contains("3x pipeline compile failures") })
        #expect(LogCollector.count(of: "ab", in: "ab ab ab") == 3)
    }
}

@Suite("Assertions are not crashes")
struct AssertionDumpTests {
    @Test func assertDumpIsWarningNotCrash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-assert-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = StirredPaths(root: tmp)
        let prefix = paths.prefix(named: "steam")
        let dumps = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/dumps")
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        try Data().write(to: dumps.appendingPathComponent("assert_muck.exe_1.dmp"))
        let game = Game(store: "steam", storeID: "1", name: "Muck", installDirectory: nil)
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [], hardware: HardwareProfile(memoryGB: 16))
        let system = SystemInfo(macOS: "27", chip: "M4", memoryGB: 16, lowPowerMode: false, onBattery: false)
        var rec = try SessionRecorder.begin(game: game, plan: plan, engine: "e", processNeedle: "Muck.exe",
                                            paths: paths, system: system, now: Date().addingTimeInterval(-30))
        let md = try String(contentsOf: try rec.finish(paths: paths, prefix: prefix), encoding: .utf8)
        #expect(md.contains("Crash detected | no"))
        #expect(md.contains("assertion dump"))
    }
}
