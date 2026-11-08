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

@Suite("Launch mode")
struct LaunchModeTests {
    @Test func plannerDefaultsToSteamAndHonoursRecipe() {
        let hw = HardwareProfile(memoryGB: 16)
        #expect(LaunchPlanner.plan(recipe: nil, detectedAPIs: [], hardware: hw).launchMode == .steam)
        let r = Recipe(appid: 1, name: "X", status: .playable, launchMode: .direct)
        #expect(LaunchPlanner.plan(recipe: r, detectedAPIs: [], hardware: hw).launchMode == .direct)
    }
}

@Suite("Stopping games")
struct StopGameTests {
    @Test func stopPatternsCoverFolderAndUbisoftLauncher() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-stop-\(UUID().uuidString)/common/Track(mania)!")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data().write(to: tmp.appendingPathComponent("upc_r2_loader64.dll"))
        let game = Game(store: "steam", storeID: "1", name: "T", installDirectory: tmp)
        let patterns = Launcher.stopPatterns(for: game, needle: "Track.exe")
        #expect(patterns.contains("Ubisoft Game Launcher"))
        #expect(patterns.contains { $0.contains("Track\\(mania\\)!") || $0.contains("Track\\(mania") })
        #expect(patterns.first == "Track\\.exe")
    }
}

@Suite("Steam display fix (wrapper)")
struct WebHelperWrapperTests {
    private func tree() throws -> (root: URL, wrapper: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-wrap-\(UUID().uuidString)")
        let cef = WebHelperWrapper.cefDirectory(steamRoot: tmp)
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data(count: 600_000).write(to: cef.appendingPathComponent("steamwebhelper.exe"))   // "Valve's" helper
        let wrapper = tmp.appendingPathComponent("wrapper.exe")
        try Data(repeating: 1, count: 150_000).write(to: wrapper)
        return (tmp, wrapper)
    }

    @Test func wrapsOnceAndKeepsTheOriginal() throws {
        let (root, wrapper) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!WebHelperWrapper.isInstalled(steamRoot: root))
        #expect(try WebHelperWrapper.ensure(steamRoot: root, wrapper: wrapper) == true)
        #expect(WebHelperWrapper.isInstalled(steamRoot: root))
        let dir = WebHelperWrapper.cefDirectory(steamRoot: root)
        #expect(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper_real.exe")).count == 600_000)
        #expect(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper.exe")).count == 150_000)
    }

    /// Regression: a rebuilt wrapper (different bytes) was once copied over the real helper, so the wrapper launched itself forever.
    @Test func refreshingAnOldWrapperNeverTouchesTheRealHelper() throws {
        let (root, wrapper) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        try WebHelperWrapper.ensure(steamRoot: root, wrapper: wrapper)
        let newer = root.appendingPathComponent("wrapper2.exe")
        try Data(repeating: 2, count: 160_000).write(to: newer)
        #expect(try WebHelperWrapper.ensure(steamRoot: root, wrapper: newer) == false)
        let dir = WebHelperWrapper.cefDirectory(steamRoot: root)
        #expect(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper_real.exe")).count == 600_000)
        #expect(try Data(contentsOf: dir.appendingPathComponent("steamwebhelper.exe")).count == 160_000)
    }

    @Test func refusesWhenTheOriginalIsGone() throws {
        let (root, wrapper) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = WebHelperWrapper.cefDirectory(steamRoot: root)
        try Data(count: 150_000).write(to: dir.appendingPathComponent("steamwebhelper.exe"))   // a wrapper, no real file
        #expect(throws: WebHelperWrapper.Failure.self) { try WebHelperWrapper.ensure(steamRoot: root, wrapper: wrapper) }
    }

    @Test func doesNothingBeforeSteamHasDownloadedItsUI() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-wrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let wrapper = tmp.appendingPathComponent("w.exe"); try Data(count: 10).write(to: wrapper)
        #expect(try WebHelperWrapper.ensure(steamRoot: tmp, wrapper: wrapper) == false)
    }
}

@Suite("First-run setup")
struct SetupTests {
    @Test func emptyDataFolderReportsEverythingMissing() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-setup-\(UUID().uuidString)")
        let items = SetupManager(paths: StirredPaths(root: tmp), wrapper: nil).items()
        #expect(items.count == SetupStep.allCases.count)
        #expect(items.filter { $0.step != .rosetta }.allSatisfy { !$0.done })
        #expect(!SetupManager(paths: StirredPaths(root: tmp), wrapper: nil).isComplete)
    }

    @Test func sha256MatchesAKnownValue() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try SetupManager.sha256Hex(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func detectsARememberedSteamLogin() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-login-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let engineBin = tmp.appendingPathComponent("engine/bin")
        try FileManager.default.createDirectory(at: engineBin, withIntermediateDirectories: true)
        let wine = engineBin.appendingPathComponent("wine")
        try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let runner = try WineRunner(engine: Engine(directory: tmp.appendingPathComponent("engine")), prefix: tmp)
        let steam = SteamProvider(runner: runner, logsDirectory: tmp)
        #expect(!steam.hasRememberedLogin)
        let config = steam.steamRoot.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "\"users\" { \"7656\" { \"AccountName\" \"x\" \"RememberPassword\" \"1\" \"MostRecent\" \"1\" } }"
            .write(to: config.appendingPathComponent("loginusers.vdf"), atomically: true, encoding: .utf8)
        #expect(steam.hasRememberedLogin)
    }
}

@Suite("Library filtering")
struct LibraryFilterTests {
    @Test func technicalComponentsAreHidden() {
        #expect(Launcher.hiddenAppIDs.contains("228980"))
        #expect(Launcher.hiddenAppIDs.contains("4099820"))
        #expect(!Launcher.hiddenAppIDs.contains("1625450"))
    }
}

@Suite("Unity default")
struct UnityDefaultTests {
    @Test func unityGamesAreForcedToDirect3D11UnlessTheRecipeSaysOtherwise() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-unity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let unity = tmp.appendingPathComponent("common/U"), other = tmp.appendingPathComponent("common/O")
        for dir in [unity, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data().write(to: unity.appendingPathComponent("UnityPlayer.dll"))
        let launcher = Launcher(paths: StirredPaths(root: tmp), recipesDirectory: tmp, resourcesDirectory: tmp)
        let unityGame = Game(store: "steam", storeID: "1", name: "U", installDirectory: unity)
        let otherGame = Game(store: "steam", storeID: "2", name: "O", installDirectory: other)
        #expect(launcher.plan(for: unityGame).gameArguments == ["-force-d3d11"])
        #expect(launcher.plan(for: otherGame).gameArguments.isEmpty)
        // A recipe that already chooses an API keeps it.
        let steamDir = tmp.appendingPathComponent("steam"); try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try #"{"appid":3,"name":"V","status":"playable","verified":false,"launch_args":["-force-vulkan"]}"#
            .write(to: steamDir.appendingPathComponent("3.json"), atomically: true, encoding: .utf8)
        let unityVulkan = Game(store: "steam", storeID: "3", name: "V", installDirectory: unity)
        #expect(launcher.plan(for: unityVulkan).gameArguments == ["-force-vulkan"])
    }
}

@Suite("Unreal executables")
struct UnrealFinderTests {
    @Test func shippingExecutableComesFirstAndEngineIsIgnored() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-ue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        for sub in ["OMD/Binaries/Win64", "Engine/Binaries/Win64"] {
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data().write(to: tmp.appendingPathComponent("Game Stub.exe"))
        try Data().write(to: tmp.appendingPathComponent("OMD/Binaries/Win64/OMD-Win64-Shipping.exe"))
        try Data().write(to: tmp.appendingPathComponent("Engine/Binaries/Win64/Other-Win64-Shipping.exe"))
        let names = GameExecutableFinder.candidates(in: tmp).map(\.lastPathComponent)
        #expect(names == ["OMD-Win64-Shipping.exe", "Game Stub.exe"])
    }
}

@Suite("Per-game DXVK options")
struct DXVKOptionsTests {
    @Test func recipeOptionsReachDxvkConf() throws {
        let json = #"{"appid":1,"name":"G","status":"playable","verified":false,"dxvk_options":{"d3d11.zeroWorkgroupMemory":"True","dxvk.useRawSsbo":"True"}}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let recipe = try decoder.decode(Recipe.self, from: Data(json.utf8))
        let plan = LaunchPlanner.plan(recipe: recipe, detectedAPIs: [], hardware: HardwareProfile(memoryGB: 16))
        #expect(plan.dxvkOptions["dxvk.useRawSsbo"] == "True")
        let conf = DXVKConfig.render(latency: .low, extra: plan.dxvkOptions)
        #expect(conf.contains("d3d11.zeroWorkgroupMemory = True") && conf.contains("dxvk.useRawSsbo = True"))
    }
}

@Suite("Steam lifecycle record")
struct SteamLifecycleTests {
    @Test func oldSessionFilesWithoutTheFlagStillDecode() throws {
        let rec = SessionRecord(
            gameName: "G", store: "steam", storeID: "1", backend: "dxvk", latency: "low", engine: "e",
            processNeedle: "G.exe", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, environment: [:], planWarnings: [],
            system: SystemInfo(macOS: "27", chip: "M4", memoryGB: 16, lowPowerMode: false, onBattery: false), samples: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(rec)) as! [String: Any]
        object.removeValue(forKey: "startedSteam")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.startedSteam == nil)
        var flagged = rec; flagged.startedSteam = true
        let round = try decoder.decode(SessionRecord.self, from: encoder.encode(flagged))
        #expect(round.startedSteam == true)
    }
}

@Suite("Uninstall")
struct UninstallTests {
    private func tree() throws -> (root: URL, game: Game) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-un-\(UUID().uuidString)")
        let steamapps = root.appendingPathComponent("steamapps")
        let folder = steamapps.appendingPathComponent("common/Muck")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: folder.appendingPathComponent("a.bin"))
        try Data(count: 500).write(to: folder.appendingPathComponent("b.bin"))
        try Data(count: 10).write(to: steamapps.appendingPathComponent("appmanifest_7.acf"))
        try FileManager.default.createDirectory(at: steamapps.appendingPathComponent("shadercache/7"), withIntermediateDirectories: true)
        try Data(count: 90).write(to: steamapps.appendingPathComponent("shadercache/7/x"))
        return (root, Game(store: "steam", storeID: "7", name: "Muck", installDirectory: folder))
    }

    @Test func planListsFolderCachesAndManifestWithTheirSize() throws {
        let (root, game) = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try Uninstaller.plan(for: game, steamRoot: root)
        #expect(plan.bytes == 1600)
        #expect(plan.paths.count == 3)
        #expect(plan.paths.last?.lastPathComponent == "appmanifest_7.acf")
    }

    @Test func executeRemovesEverythingButLeavesOtherGames() throws {
        let (root, game) = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("steamapps/common/Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Uninstaller.execute(try Uninstaller.plan(for: game, steamRoot: root))
        #expect(!FileManager.default.fileExists(atPath: game.installDirectory!.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps/appmanifest_7.acf").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func refusesFoldersOutsideCommonAndSymlinkEscapes() throws {
        let (root, _) = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        let escape = Game(store: "steam", storeID: "7", name: "X",
                          installDirectory: root.appendingPathComponent("steamapps/common/../.."))
        #expect(throws: UninstallError.self) { try Uninstaller.plan(for: escape, steamRoot: root) }
        let common = root.appendingPathComponent("steamapps/common")
        #expect(throws: UninstallError.self) {   // the whole "common" folder is not a single game
            try Uninstaller.plan(for: Game(store: "steam", storeID: "7", name: "X", installDirectory: common), steamRoot: root)
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = common.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: UninstallError.self) {
            try Uninstaller.plan(for: Game(store: "steam", storeID: "7", name: "X", installDirectory: link), steamRoot: root)
        }
        #expect(throws: UninstallError.self) {   // not a numeric Steam app id
            try Uninstaller.plan(for: Game(store: "steam", storeID: "../7", name: "X", installDirectory: common.appendingPathComponent("Muck")), steamRoot: root)
        }
    }
}
