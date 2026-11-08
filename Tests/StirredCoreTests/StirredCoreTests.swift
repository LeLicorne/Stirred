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

@Suite("Check a game")
struct CheckGameTests {
    private func info(mac: Bool = false, notices: String = "", categories: [String] = []) -> StoreInfo {
        StoreInfo(appID: 1, name: "G", isFree: false, windows: true, mac: mac, categories: categories, notices: notices, headerImage: nil)
    }

    @Test func appIDsAreParsedFromLinksAndNumbers() {
        #expect(StoreClient.parseAppID(from: "1625450") == 1625450)
        #expect(StoreClient.parseAppID(from: "https://store.steampowered.com/app/1625450/Muck/") == 1625450)
        #expect(StoreClient.parseAppID(from: "steam://run/230410") == 230410)
        #expect(StoreClient.parseAppID(from: "Muck") == nil)
    }

    @Test func storeJSONIsParsed() throws {
        let json = #"{"7":{"success":true,"data":{"name":"Seven","is_free":true,"platforms":{"windows":true,"mac":true,"linux":false},"categories":[{"id":8,"description":"Valve Anti-Cheat enabled"}],"drm_notice":"Needs <b>Ubisoft Connect</b>","header_image":"https://x/y.jpg"}}}"#
        let parsed = try #require(StoreClient.parseInfo(Data(json.utf8), appID: 7))
        #expect(parsed.name == "Seven" && parsed.isFree && parsed.mac)
        #expect(parsed.categories == ["Valve Anti-Cheat enabled"])
        #expect(parsed.notices.contains("Ubisoft Connect") && !parsed.notices.contains("<b>"))
        #expect(StoreClient.parseInfo(Data(#"{"7":{"success":false}}"#.utf8), appID: 7) == nil)
        #expect(StoreClient.parseSearch(Data(#"{"items":[{"type":"app","id":3,"name":"Three"},{"type":"bundle","id":4,"name":"B"}]}"#.utf8)).map(\.id) == [3])
        #expect(StoreClient.parseDeck(Data(#"{"success":1,"results":{"resolved_category":3}}"#.utf8)) == .verified)
        #expect(StoreClient.parseDeck(Data("junk".utf8)) == .unknown)
    }

    @Test func verdictFollowsTheOrderOfAuthority() {
        let tested = Recipe(appid: 1, name: "G", status: .playable, verified: true)
        #expect(CompatVerdict.evaluate(info: info(), deck: .unsupported, recipe: tested).level == .works)
        #expect(CompatVerdict.evaluate(info: info(notices: "Easy Anti-Cheat"), deck: .verified, recipe: nil).level == .no)
        #expect(CompatVerdict.evaluate(info: info(notices: "Ubisoft Account"), deck: .verified, recipe: nil).level == .no)
        #expect(CompatVerdict.evaluate(info: info(mac: true), deck: .unknown, recipe: nil).level == .native)
        #expect(CompatVerdict.evaluate(info: info(), deck: .verified, recipe: nil).level == .likely)
        #expect(CompatVerdict.evaluate(info: info(), deck: .playable, recipe: nil).level == .maybe)
        #expect(CompatVerdict.evaluate(info: info(), deck: .unknown, recipe: nil).level == .unknown)
        #expect(CompatVerdict.evaluate(info: info(categories: ["Valve Anti-Cheat enabled"]), deck: .verified, recipe: nil).level == .maybe)
    }

    @Test func manifestsReportSizeAndDownloadProgress() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-prog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let engineBin = tmp.appendingPathComponent("engine/bin")
        try FileManager.default.createDirectory(at: engineBin, withIntermediateDirectories: true)
        let wine = engineBin.appendingPathComponent("wine")
        try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let runner = try WineRunner(engine: Engine(directory: tmp.appendingPathComponent("engine")), prefix: tmp)
        let steam = SteamProvider(runner: runner, logsDirectory: tmp)
        let apps = steam.steamRoot.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try #""AppState" { "appid" "1" "name" "Done" "installdir" "Done" "StateFlags" "4" "SizeOnDisk" "2048" }"#
            .write(to: apps.appendingPathComponent("appmanifest_1.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "2" "name" "Busy" "installdir" "Busy" "StateFlags" "1026" "BytesToDownload" "1000" "BytesDownloaded" "250" }"#
            .write(to: apps.appendingPathComponent("appmanifest_2.acf"), atomically: true, encoding: .utf8)
        let games = try steam.installedGames()
        let done = try #require(games.first { $0.storeID == "1" }), busy = try #require(games.first { $0.storeID == "2" })
        #expect(done.downloadProgress == nil && done.sizeOnDisk == 2048)
        #expect(busy.downloadProgress == 0.25)
    }
}

@Suite("Check a game: DirectX and search")
struct CheckGameExtraTests {
    @Test func directXVersionComesFromTheMinimumRequirements() throws {
        let json = #"{"9":{"success":true,"data":{"name":"Nine","pc_requirements":{"minimum":"<ul><li><strong>OS:</strong> Windows 10</li><li><strong>DirectX:</strong> Version 12</li></ul>"}}}}"#
        #expect(try #require(StoreClient.parseInfo(Data(json.utf8), appID: 9)).directX == 12)
        let none = #"{"9":{"success":true,"data":{"name":"Nine","pc_requirements":[]}}}"#
        #expect(try #require(StoreClient.parseInfo(Data(none.utf8), appID: 9)).directX == nil)
    }

    @Test func directX12GamesAreRefusedButNativeMacWins() {
        var info = StoreInfo(appID: 1, name: "G", isFree: false, windows: true, mac: false, categories: [], notices: "", headerImage: nil, directX: 12)
        #expect(CompatVerdict.evaluate(info: info, deck: .verified, recipe: nil).level == .no)
        info.mac = true
        #expect(CompatVerdict.evaluate(info: info, deck: .verified, recipe: nil).level == .native)
    }

    @Test func exactNameBeatsStoreRelevanceOrder() {
        let results = [StoreSearchResult(id: 2, name: "Hades II"), StoreSearchResult(id: 1, name: "Hades")]
        #expect(StoreClient.bestMatch(results, for: "hades")?.id == 1)
        #expect(StoreClient.bestMatch(results, for: "had")?.id == 2)
        #expect(StoreClient.bestMatch([], for: "x") == nil)
    }
}

// MARK: - Whole library

private func cstr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
private func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
private func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

@Suite("Steam local data")
struct SteamLocalDataTests {
    /// packageinfo v40: package 5 owns apps 1625450 and 730.
    private func packageInfo(version: UInt32 = 0x06565528) -> Data {
        var d: [UInt8] = le32(version) + le32(1)
        d += le32(5) + [UInt8](repeating: 0, count: 20) + le32(9) + (version & 0xFF >= 0x28 ? le64(0) : [])
        d += [0] + cstr("5") + [0] + cstr("appids") + [2] + cstr("0") + le32(1625450) + [2] + cstr("1") + le32(730) + [8] + [8] + [8]
        d += le32(0xFFFF_FFFF)
        return Data(d)
    }

    /// appinfo v41 with a string table: Muck (windows+macos, Deck playable) and a DLC.
    private func appInfo() -> Data {
        let table = ["appinfo", "common", "name", "type", "oslist", "steam_deck_compatibility", "category"]
        func idx(_ s: String) -> [UInt8] { le32(UInt32(table.firstIndex(of: s)!)) }
        func app(_ id: UInt32, name: String, type: String, oslist: String, deck: UInt32?) -> [UInt8] {
            var kv: [UInt8] = [0] + idx("appinfo") + [0] + idx("common")
            kv += [1] + idx("name") + cstr(name) + [1] + idx("type") + cstr(type) + [1] + idx("oslist") + cstr(oslist)
            if let deck { kv += [0] + idx("steam_deck_compatibility") + [2] + idx("category") + le32(deck) + [8] }
            kv += [8] + [8] + [8]
            let header = le32(0) + le32(0) + le64(0) + [UInt8](repeating: 0, count: 20) + le32(0) + [UInt8](repeating: 0, count: 20)
            return le32(id) + le32(UInt32(header.count + kv.count)) + header + kv
        }
        var body = app(1625450, name: "Muck", type: "Game", oslist: "windows,macos,linux", deck: 2)
        body += app(99, name: "Muck Soundtrack", type: "DLC", oslist: "windows", deck: nil)
        body += le32(0)
        let tableOffset = UInt64(16 + body.count)
        var d: [UInt8] = le32(0x07564429) + le32(1) + le64(tableOffset) + body
        d += le32(UInt32(table.count)); for s in table { d += cstr(s) }
        return Data(d)
    }

    @Test func packageInfoListsOwnedApps() throws {
        #expect(try PackageInfoReader.ownedAppIDs(packageInfo()) == [1625450, 730])
        #expect(try PackageInfoReader.ownedAppIDs(packageInfo(version: 0x06565527)) == [1625450, 730])
    }

    @Test func appInfoGivesNamePlatformsAndDeckStatus() throws {
        let entries = try AppInfoReader.read(appInfo())
        let muck = try #require(entries[1625450])
        #expect(muck.name == "Muck" && muck.isGame && muck.oses == ["windows", "macos", "linux"] && muck.deck == .playable)
        #expect(entries[99]?.isGame == false)
    }

    @Test func garbageIsRefusedNotCrashed() {
        #expect(throws: SteamLocalDataError.self) { try PackageInfoReader.ownedAppIDs(Data([1, 2, 3])) }
        #expect(throws: SteamLocalDataError.self) { try AppInfoReader.read(Data(count: 40)) }
        var truncated = appInfo(); truncated.removeLast(40)
        _ = try? AppInfoReader.read(truncated)   // must return or throw, never trap
    }
}

@Suite("Library analysis")
struct LibraryAnalysisTests {
    private func games() -> [AppInfoEntry] {
        [AppInfoEntry(appID: 1, name: "Verified Game", type: "Game", oses: ["windows"], deck: .verified),
         AppInfoEntry(appID: 2, name: "Mac Game", type: "Game", oses: ["windows", "macos"], deck: .unknown),
         AppInfoEntry(appID: 3, name: "Mystery", type: "Game", oses: ["windows"], deck: .unknown)]
    }

    private func tmp() -> (StirredPaths, RecipeRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-lib-\(UUID().uuidString)")
        return (StirredPaths(root: root), RecipeRepository(directory: root.appendingPathComponent("recipes")))
    }

    @Test func offlineVerdictsUseDeckAndPlatforms() {
        let (paths, recipes) = tmp(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let entries = LibraryAnalysis.entries(for: games(), installed: ["3"], recipes: recipes, cache: StoreCache(paths: paths))
        #expect(entries.map(\.verdict.level) == [.likely, .native, .unknown])
        #expect(entries.map(\.installed) == [false, false, true])
        #expect(entries.allSatisfy { !$0.refined })
    }

    @Test func cacheRoundTripExpiryAndNegativeEntries() {
        let (paths, _) = tmp(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let cache = StoreCache(paths: paths)
        #expect(cache.read(1) == nil)
        let info = StoreInfo(appID: 1, name: "G", isFree: true, windows: true, mac: false, categories: ["x"], notices: "n", headerImage: nil, directX: 12)
        cache.write(1, info: info, now: Date())
        #expect(cache.read(1)! == info)
        #expect(cache.read(1, now: Date().addingTimeInterval(31 * 86_400)) == nil)
        cache.write(2, info: nil, now: Date())
        #expect(cache.read(2) != nil && cache.read(2)! == nil)
        #expect(cache.read(2, now: Date().addingTimeInterval(8 * 86_400)) == nil)
    }

    @Test func refinementUsesStoreDetailsAndStopsOnRequest() async {
        let (paths, recipes) = tmp(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let cache = StoreCache(paths: paths)
        let json = #"{"1":{"success":true,"data":{"name":"Verified Game","pc_requirements":{"minimum":"DirectX: Version 12"}}}}"#
        let client = StoreClient(fetch: { _ in Data(json.utf8) })
        let g = games()
        let entries = LibraryAnalysis.entries(for: g, installed: [], recipes: recipes, cache: cache)
        final class Seen: @unchecked Sendable { var levels: [Int: VerdictLevel] = [:] }
        let seen = Seen()
        await LibraryAnalysis.refine(entries, games: g, recipes: recipes, cache: cache, client: client, delay: 0,
                                     shouldStop: { false }) { updated, _, _ in seen.levels[updated.appID] = updated.verdict.level }
        #expect(seen.levels[1] == .no)          // Deck verified, but needs DirectX 12
        #expect(cache.read(1) != nil)
        #expect(seen.levels[2] == nil)          // native Mac games are not refined
        // A stop request before the first game does nothing.
        let (paths2, recipes2) = tmp(); defer { try? FileManager.default.removeItem(at: paths2.root) }
        let seen2 = Seen()
        await LibraryAnalysis.refine(entries, games: g, recipes: recipes2, cache: StoreCache(paths: paths2), client: client, delay: 0,
                                     shouldStop: { true }) { updated, _, _ in seen2.levels[updated.appID] = updated.verdict.level }
        #expect(seen2.levels.isEmpty)
    }

    @Test func levelsRankBestFirst() {
        #expect([VerdictLevel.no, .works, .maybe, .native, .unknown, .likely].sorted { $0.rank < $1.rank } == [.works, .native, .likely, .maybe, .unknown, .no])
    }
}

// MARK: - Diagnosis

@Suite("Diagnosis rules")
struct DiagnosisRuleTests {
    private let game = Game(store: "steam", storeID: "1", name: "G", installDirectory: nil)
    private func plan(_ recipe: Recipe? = nil, args: [String] = []) -> LaunchPlan {
        var p = LaunchPlanner.plan(recipe: recipe, detectedAPIs: [.d3d11], hardware: HardwareProfile(memoryGB: 16))
        p.gameArguments = args
        return p
    }
    private func ids(_ input: DiagnosisInput) -> [String] { Diagnoser.diagnose(input).map(\.id) }
    private func session(started: Bool) -> SessionRecord {
        var record = SessionRecord(gameName: "G", store: "steam", storeID: "1", backend: "dxvk", latency: "low", engine: "e", processNeedle: "G.exe",
                      startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, environment: [:], planWarnings: [],
                      system: SystemInfo(macOS: "27", chip: "M4", memoryGB: 16, lowPowerMode: false, onBattery: false),
                      samples: [SessionSample(t: 0, gpuPercent: 10, cpuPercent: 10, rssMB: 100, processCount: started ? 1 : 0)])
        record.neverDetected = !started
        return record
    }

    @Test func aSessionThatWasNotWatchedIsNotAFailure() {
        var unwatched = session(started: false)
        unwatched.neverDetected = nil; unwatched.samples = []
        #expect(Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), lastSession: unwatched)).first?.id == "nothing")
    }

    @Test func aHealthyGameStillGetsAnAnswer() {
        let out = Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan()))
        #expect(out.map(\.id) == ["nothing"] && out[0].fix == nil)
    }

    @Test func unityOnVulkanOffersTheArgumentOrExplainsStartingFromStirred() {
        let vulkan = "Initialize engine\nMicrosoft Media Foundation video decoding to texture disabled: graphics device is Vulkan, only"
        let fixable = Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), logs: vulkan))
        #expect(fixable.first?.id == "unity-vulkan" && fixable.first?.fix == .addLaunchArgument("-force-d3d11"))
        let outside = Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(args: ["-force-d3d11"]), logs: vulkan))
        #expect(outside.first?.id == "unity-vulkan-outside" && outside.first?.fix == nil)
    }

    @Test func blockersComeFirstAndHaveNoFix() {
        let input = DiagnosisInput(game: game, plan: plan(), power: PowerState(lowPowerMode: true, onBattery: true),
                                   logs: "Starting EasyAntiCheat bootstrapper")
        let out = Diagnoser.diagnose(input)
        #expect(out.first?.id == "anticheat" && out.first?.severity == .blocker && out.first?.fix == nil)
        #expect(out.map(\.id).contains("low-power") && out.map(\.id).contains("battery"))
        #expect(out == out.sorted { $0.severity < $1.severity })
    }

    @Test func fixableProblemsMapToOneClickFixes() {
        #expect(ids(DiagnosisInput(game: game, plan: plan(), setupComplete: false)).first == "setup")
        let missing = Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), dxvkInstalledForGame: false))
        #expect(missing.first?.fix == .reinstallGraphics)
        #expect(Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), steamDisplayFixInstalled: false)).first?.fix == .repairSteamDisplayFix)
        #expect(Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), staleProcessCount: 3)).first?.fix == .cleanUpProcesses)
    }

    @Test func aGameThatNeverStartedSuggestsDirectLaunch() {
        let steamMode = Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), lastSession: session(started: false)))
        #expect(steamMode.first?.fix == .setLaunchMode(.direct))
        let running = Diagnoser.diagnose(DiagnosisInput(game: game, plan: plan(), lastSession: session(started: true)))
        #expect(running.first?.id == "nothing")
    }

    @Test func the32BitUnityCrashAndUnsupportedRecipesAreExplained() {
        let crash = DiagnosisInput(game: game, plan: plan(), logs: "Crash!!!", isUnity: true, executableArchitecture: .x86)
        #expect(ids(crash).first == "unity32")
        let recipe = Recipe(appid: 1, name: "G", status: .unsupported, notes: "Known blocker")
        let unsupported = Diagnoser.diagnose(DiagnosisInput(game: game, recipe: recipe, plan: plan(recipe)))
        #expect(unsupported.first?.explanation == "Known blocker")
    }

    @Test func diskPipelineAndTextReport() {
        let low = DiagnosisInput(game: game, plan: plan(), freeDiskBytes: 1_000_000_000,
                                 logs: String(repeating: "Failed to compile pipeline\n", count: 6))
        #expect(Set(ids(low)) == ["disk", "pipelines"])
        let text = Diagnoser.text(for: game, diagnoses: Diagnoser.diagnose(low),
                                  system: SystemInfo(macOS: "27", chip: "M4", memoryGB: 16, lowPowerMode: false, onBattery: false))
        #expect(text.contains("Stirred diagnosis for G") && text.contains("Almost no free disk space"))
    }
}

@Suite("Personal overrides")
struct OverrideTests {
    private func store() -> (OverrideStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-ov-\(UUID().uuidString)")
        return (OverrideStore(paths: StirredPaths(root: root)), root)
    }
    private let game = Game(store: "steam", storeID: "5", name: "Five", installDirectory: nil)

    @Test func withoutOverridesTheRecipeIsUntouched() {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.apply(to: nil, game: game) == nil)
        let recipe = Recipe(appid: 5, name: "Five", status: .playable)
        #expect(store.apply(to: recipe, game: game) == recipe)
    }

    @Test func overridesAreMergedOverTheRecipeAndSurviveRestarts() throws {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        try store.update(5) { $0.launchArgs = ["-force-d3d11"]; $0.launchMode = .direct; $0.dxvkOptions = ["a": "1"] }
        try store.update(5) { $0.launchArgs = ($0.launchArgs ?? []) + ["-force-d3d11", "-x"] }   // duplicates are not repeated
        let recipe = Recipe(appid: 5, name: "Five", status: .playable, launchArgs: ["-dx11"], dxvkOptions: ["a": "0", "b": "2"])
        let merged = try #require(store.apply(to: recipe, game: game))
        #expect(merged.launchArgs == ["-dx11", "-force-d3d11", "-x"] && merged.launchMode == .direct)
        #expect(merged.dxvkOptions == ["a": "1", "b": "2"] && merged.status == .playable)
        // A fresh store object reads the same file back.
        #expect(OverrideStore(paths: StirredPaths(root: root)).read(5).launchMode == .direct)
        let synthesized = try #require(store.apply(to: nil, game: game))
        #expect(synthesized.status == .unknown && synthesized.launchArgs == ["-force-d3d11", "-x"])
    }

    @Test func resetForgetsEverything() throws {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        try store.update(5) { $0.launchMode = .direct }
        try store.reset(5)
        #expect(store.read(5).isEmpty)
        try store.update(5) { $0.launchMode = .direct }
        try store.update(5) { $0.launchMode = nil }   // back to empty removes the file
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("5.json").path))
    }

    @Test func applyingAFixPersistsItAndChangesTheNextPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-fix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = Launcher(paths: StirredPaths(root: root), recipesDirectory: root, resourcesDirectory: root)
        let g = Game(store: "steam", storeID: "5", name: "Five", installDirectory: root.appendingPathComponent("common/F"))
        #expect(launcher.plan(for: g).launchMode == .steam)
        try await launcher.apply(.setLaunchMode(.direct), to: g)
        try await launcher.apply(.addLaunchArgument("-force-d3d11"), to: g)
        let plan = launcher.plan(for: g)
        #expect(plan.launchMode == .direct && plan.gameArguments == ["-force-d3d11"])
    }
}

// MARK: - Presets

@Suite("Presets")
struct PresetTests {
    private let hw16 = HardwareProfile(memoryGB: 16)

    @Test func catalogMatchesWhatEachPresetPromises() {
        let fast = PresetCatalog.settings(for: .performance, hardware: hw16)
        #expect(fast.latency == .lowest && fast.dxvkOptions["dxvk.enableAsync"] == "True")
        let balanced = PresetCatalog.settings(for: .balanced, hardware: hw16)
        #expect(balanced.latency == .low && balanced.dxvkOptions.isEmpty)
        let pretty = PresetCatalog.settings(for: .quality, hardware: hw16)
        #expect(pretty.latency == .balanced && pretty.dxvkOptions["dxgi.maxFrameRate"] == "60")
    }

    @Test func recommendationFollowsMemory() {
        #expect(PresetCatalog.recommended(for: HardwareProfile(memoryGB: 8)) == .performance)
        #expect(PresetCatalog.recommended(for: hw16) == .balanced)
        #expect(PresetCatalog.recommended(for: HardwareProfile(memoryGB: 32)) == .quality)
    }

    private func setup(unity: Bool, recipeLatency: LatencyProfile? = nil) throws -> (Launcher, Game, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-preset-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("common/G")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if unity { try Data().write(to: folder.appendingPathComponent("UnityPlayer.dll")) }
        let recipes = root.appendingPathComponent("recipes/steam")
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        let latencyJSON = recipeLatency.map { #","latency":"\#($0.rawValue)""# } ?? ""
        try #"{"appid":9,"name":"G","status":"playable","verified":false\#(latencyJSON)}"#
            .write(to: recipes.appendingPathComponent("9.json"), atomically: true, encoding: .utf8)
        let launcher = Launcher(paths: StirredPaths(root: root), recipesDirectory: root.appendingPathComponent("recipes"), resourcesDirectory: root)
        return (launcher, Game(store: "steam", storeID: "9", name: "G", installDirectory: folder), root)
    }

    @Test func fasterPresetSetsLatencyAndAsyncShadersButNeverTouchesResolution() throws {
        let (launcher, game, root) = try setup(unity: true); defer { try? FileManager.default.removeItem(at: root) }
        try launcher.overrides.update(9) { $0.preset = .performance }
        let plan = launcher.plan(for: game)
        #expect(plan.latency == .lowest)
        #expect(plan.dxvkOptions["dxvk.enableAsync"] == "True")
        #expect(plan.gameArguments == ["-force-d3d11"])   // only Stirred's own Unity fix: no -screen-width
    }

    @Test func recipeAndPersonalDxvkOptionsWinOverThePreset() throws {
        let (launcher, game, root) = try setup(unity: false); defer { try? FileManager.default.removeItem(at: root) }
        try launcher.overrides.update(9) { $0.preset = .quality; $0.dxvkOptions = ["dxgi.maxFrameRate": "30"] }
        #expect(launcher.plan(for: game).dxvkOptions["dxgi.maxFrameRate"] == "30")
    }

    @Test func authorityIsRunOptionThenPersonalThenPresetThenRecipe() throws {
        let (launcher, game, root) = try setup(unity: false, recipeLatency: .lowest); defer { try? FileManager.default.removeItem(at: root) }
        #expect(launcher.plan(for: game).latency == .lowest)                       // recipe alone
        try launcher.overrides.update(9) { $0.preset = .quality }
        #expect(launcher.plan(for: game).latency == .balanced)                     // the chosen preset beats the recipe
        try launcher.overrides.update(9) { $0.latency = .low }
        #expect(launcher.plan(for: game).latency == .low)                          // a personal latency beats the preset
        #expect(launcher.plan(for: game, options: LaunchOptions(latency: .lowest)).latency == .lowest)   // this run's option beats all
    }

    @Test func aRecipeCanSuggestAPresetAndUsersCanClearTheirChoice() throws {
        let (launcher, game, root) = try setup(unity: false); defer { try? FileManager.default.removeItem(at: root) }
        #expect(launcher.preset(for: game) == nil)
        try launcher.overrides.update(9) { $0.preset = .quality }
        #expect(launcher.preset(for: game) == .quality)
        try launcher.overrides.update(9) { $0.preset = nil }
        #expect(launcher.preset(for: game) == nil)
    }
}

@Suite struct UpdaterTests {
    @Test func warframeRecipeDeclaresItsUpdater() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recipes/steam/230410.json")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let recipe = try decoder.decode(Recipe.self, from: Data(contentsOf: url))
        #expect(recipe.updater?.executable == "Tools/Launcher.exe")
        #expect(recipe.updater?.disabledDlls?.contains("d3dcompiler_47") == true)
    }

    @Test func gamesWithoutUpdaterHaveNone() {
        #expect(Recipe(appid: 1, name: "X", status: .playable).updater == nil)
    }
}

@Suite struct CommunityRecipeTests {
    private func json(_ body: String) -> Data { Data(body.utf8) }
    private let system = SystemInfo(macOS: "27.0", chip: "Apple M4", memoryGB: 16, lowPowerMode: false, onBattery: false)

    @Test func acceptsASafeRecipeAndNeverTrustsItsVerifiedFlag() throws {
        let recipe = try CommunityRecipes.parse(json(#"{"appid": 42, "name": "G", "status": "playable", "verified": true, "graphics": "dxvk", "launch_args": ["-windowed"], "env": {"DXVK_HUD": "fps"}, "dxvk_options": {"dxgi.maxFrameRate": "60"}}"#))
        #expect(recipe.verified == false)
        #expect(recipe.notes?.contains("not verified") == true)
        #expect(recipe.launchArgs == ["-windowed"])
    }

    @Test func refusesDangerousEnvironmentVariables() {
        #expect(throws: CommunityRecipes.ImportError.self) {
            try CommunityRecipes.parse(json(#"{"appid": 42, "name": "G", "status": "playable", "env": {"DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"}}"#))
        }
    }

    @Test func refusesUpdaterOutsideTheGameFolderAndUnknownOptions() {
        #expect(!CommunityRecipes.problems(in: Recipe(appid: 1, name: "G", status: .playable, updater: GameUpdater(executable: "../../evil.exe"))).isEmpty)
        #expect(!CommunityRecipes.problems(in: Recipe(appid: 1, name: "G", status: .playable, updater: GameUpdater(executable: "/bin/sh"))).isEmpty)
        #expect(!CommunityRecipes.problems(in: Recipe(appid: 1, name: "G", status: .playable, dxvkOptions: ["evil.key": "1"])).isEmpty)
        #expect(!CommunityRecipes.problems(in: Recipe(appid: 1, name: "G", status: .playable, dllOverrides: ["d3d11": "$(rm -rf)"])).isEmpty)
        #expect(CommunityRecipes.problems(in: Recipe(appid: 1, name: "G", status: .playable, updater: GameUpdater(executable: "Tools/Launcher.exe"))).isEmpty)
    }

    @Test func refusesGarbageAndHugeFiles() {
        #expect(throws: CommunityRecipes.ImportError.self) { try CommunityRecipes.parse(json("not json")) }
        #expect(throws: CommunityRecipes.ImportError.self) { try CommunityRecipes.parse(Data(count: CommunityRecipes.maxBytes + 1)) }
    }

    @Test func exportRoundTripsAndRecordsTheTestOnlyWhenClaimed() throws {
        let recipe = Recipe(appid: 42, name: "G", status: .playable, launchArgs: ["-windowed"], latency: .low)
        let untested = try CommunityRecipes.parse(CommunityRecipes.export(recipe, tested: false, system: system, engine: "wine-1"))
        #expect(untested.launchArgs == ["-windowed"] && untested.latency == .low)
        let data = try CommunityRecipes.export(recipe, tested: true, system: system, engine: "wine-1", date: Date(timeIntervalSince1970: 0))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"verified\" : true") && text.contains("Apple M4 16 GB") && text.contains("1970-01-01"))
        #expect(!text.contains("baptiste") && !text.contains("/Users"))
    }

    @Test func importedRecipeWinsOverBundledAndCanBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-community-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled/steam"); try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data(#"{"appid": 7, "name": "Bundled", "status": "unsupported", "verified": false}"#.utf8).write(to: bundled.appendingPathComponent("7.json"))
        let repo = RecipeRepository(directory: root.appendingPathComponent("bundled"), userDirectory: root.appendingPathComponent("user"))
        #expect(repo.recipe(forSteamAppID: 7)?.name == "Bundled")
        try repo.saveImported(try CommunityRecipes.parse(json(#"{"appid": 7, "name": "Imported", "status": "playable"}"#)))
        #expect(repo.recipe(forSteamAppID: 7)?.name == "Imported")
        #expect(repo.importedAppIDs() == [7])
        try repo.removeImported(7)
        #expect(repo.recipe(forSteamAppID: 7)?.name == "Bundled")
    }
}

@Suite struct DiskManagementTests {
    /// A fake Steam library with one 3-file game, and a separate "external" folder.
    private func fixture() throws -> (root: URL, steam: URL, game: Game, external: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-disk-\(UUID().uuidString)")
        let steam = root.appendingPathComponent("Steam")
        let folder = steam.appendingPathComponent("steamapps/common/Cool Game")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: folder.appendingPathComponent("game.exe"))
        try Data(count: 2000).write(to: folder.appendingPathComponent("data/a.pak"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("data/link"), withDestinationURL: URL(fileURLWithPath: "a.pak"))
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let game = Game(store: "steam", storeID: "9", name: "Cool Game", installDirectory: folder)
        return (root, steam, game, external)
    }

    @Test func movesToAnotherFolderLeavesALinkAndMovesBack() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = try GameMover.plan(for: f.game, to: f.external, steamRoot: f.steam)
        try GameMover.execute(plan)
        let folder = f.game.installDirectory!
        #expect(GameMover.isLink(folder))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("data/a.pak").path))
        #expect(GameMover.location(of: f.game) == .external(f.external.appendingPathComponent("Stirred Games/Cool Game").resolvingSymlinksInPath()))
        #expect(throws: UninstallError.self) { try Uninstaller.plan(for: f.game, steamRoot: f.steam) }
        #expect(throws: MoveError.self) { try GameMover.plan(for: f.game, to: f.external, steamRoot: f.steam) }

        let back = try GameMover.planBack(for: f.game, steamRoot: f.steam)
        try GameMover.execute(back)
        #expect(!GameMover.isLink(folder))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("game.exe").path))
        #expect(!FileManager.default.fileExists(atPath: f.external.appendingPathComponent("Stirred Games").path))
        #expect(!FileManager.default.fileExists(atPath: folder.path + ".stirred-moving"))
    }

    @Test func reportsAMissingDiskAndRefusesToMoveBack() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try GameMover.execute(try GameMover.plan(for: f.game, to: f.external, steamRoot: f.steam))
        try FileManager.default.removeItem(at: f.external.appendingPathComponent("Stirred Games"))   // "unplugged"
        if case .missing = GameMover.location(of: f.game) {} else { Issue.record("expected a missing disk") }
        #expect(throws: MoveError.self) { try GameMover.planBack(for: f.game, steamRoot: f.steam) }
    }

    @Test func refusesUnsafeDestinationsAndFolders() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(throws: MoveError.self) { try GameMover.plan(for: f.game, to: f.steam, steamRoot: f.steam) }
        #expect(throws: MoveError.self) { try GameMover.plan(for: f.game, to: f.root.appendingPathComponent("nope"), steamRoot: f.steam) }
        var odd = f.game; odd.installDirectory = f.root
        #expect(throws: MoveError.self) { try GameMover.plan(for: odd, to: f.external, steamRoot: f.steam) }
        var downloading = f.game; downloading.downloadProgress = 0.4
        #expect(throws: MoveError.self) { try GameMover.plan(for: downloading, to: f.external, steamRoot: f.steam) }
    }

    @Test func copyTreeKeepsEverythingIncludingLinks() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.game.installDirectory!, target = f.external.appendingPathComponent("copy")
        var last = 0.0
        try GameMover.copyTree(from: source, to: target, bytes: 3000) { last = $0 }
        #expect(Uninstaller.size(of: target) == 3000)
        #expect(GameMover.isLink(target.appendingPathComponent("data/link")))
        #expect(last == 1)
    }

    @Test func cleanerOnlyEmptiesItsOwnFolders() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let paths = StirredPaths(root: f.root.appendingPathComponent("data"))
        try FileManager.default.createDirectory(at: paths.downloads, withIntermediateDirectories: true)
        try Data(count: 500).write(to: paths.downloads.appendingPathComponent("wine.tar.xz"))
        let items = DiskCleaner.reclaimables(paths: paths, steamRoot: f.steam)
        #expect(items.map(\.id) == ["downloads"] && items[0].bytes == 500)
        #expect(DiskCleaner.clean(items[0]) == 500)
        #expect(FileManager.default.fileExists(atPath: paths.downloads.path))
        #expect(FileManager.default.fileExists(atPath: f.game.installDirectory!.path))
    }

    @Test func lowSpaceThreshold() {
        #expect(DiskSpace(total: 500_000_000_000, free: 5_000_000_000).isLow)
        #expect(!DiskSpace(total: 500_000_000_000, free: 100_000_000_000).isLow)
    }
}

@Suite struct EngineUpdateTests {
    private func world() throws -> (root: URL, paths: StirredPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stirred-engine-\(UUID().uuidString)")
        let paths = StirredPaths(root: root)
        for name in ["stirred-wine-11.9", "stirred-wine-11.21"] {
            let bin = paths.engines.appendingPathComponent("\(name)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let wine = bin.appendingPathComponent("wine")
            try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        }
        let prefix = paths.prefix(named: "steam")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try "registry v1".write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "dll v1".write(to: prefix.appendingPathComponent("drive_c/windows/system32/a.dll"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/games"), withIntermediateDirectories: true)
        return (root, paths)
    }

    @Test func versionsCompareNumerically() {
        #expect(EngineVersion.isNewer("11.21", than: "11.9"))
        #expect(EngineVersion.isNewer("12.0", than: "11.21"))
        #expect(!EngineVersion.isNewer("11.21", than: "11.21"))
        #expect(EngineVersion.version(ofEngineNamed: "stirred-wine-11.21") == "11.21")
    }

    @Test func newestEngineIsChosenNumericallyAndActiveFileWins() throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        #expect(EngineLocator.preferred(paths: w.paths)?.name == "stirred-wine-11.21")
        try ActiveEngine.write(w.paths, "active.txt", value: "stirred-wine-11.9")
        #expect(EngineLocator.preferred(paths: w.paths)?.name == "stirred-wine-11.9")
        try ActiveEngine.write(w.paths, "active.txt", value: "stirred-wine-gone")   // stale pointer: ignored
        #expect(EngineLocator.preferred(paths: w.paths)?.name == "stirred-wine-11.21")
    }

    @Test func statusOffersOnlyNewerTestedReleases() throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        func release(_ v: String) -> EngineRelease { EngineRelease(name: "stirred-wine-\(v)", version: v, url: URL(string: "https://example.com/\(v)")!, sha256: "00", archiveName: "\(v).tar.xz") }
        let updater = EngineUpdater(paths: w.paths, catalog: EngineCatalog(releases: [release("11.9"), release("11.21"), release("11.30"), release("12.1")]))
        #expect(updater.status().updates.map(\.version) == ["12.1", "11.30"])
    }

    @Test func snapshotRestoresRegistryAndSystemFilesButNeverGames() throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let prefix = w.paths.prefix(named: "steam")
        try PrefixSnapshot.take(w.paths, engine: "stirred-wine-11.21")
        try "registry v2".write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("drive_c/windows/system32/a.dll"))
        try "new game file".write(to: prefix.appendingPathComponent("drive_c/games/save.dat"), atomically: true, encoding: .utf8)
        try PrefixSnapshot.restore(w.paths, engine: "stirred-wine-11.21")
        #expect(try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) == "registry v1")
        #expect(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/a.dll").path))
        #expect(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/games/save.dat").path))
        #expect(throws: EngineUpdateError.self) { try PrefixSnapshot.restore(w.paths, engine: "stirred-wine-nothing") }
    }

    @Test func cannotRemoveTheActiveEngineButCanRemoveOthers() throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let updater = EngineUpdater(paths: w.paths, catalog: EngineCatalog(releases: []))
        #expect(throws: EngineUpdateError.self) { try updater.remove("stirred-wine-11.21") }
        try updater.remove("stirred-wine-11.9")
        #expect(EngineLocator.installedEngines(paths: w.paths).map(\.name) == ["stirred-wine-11.21"])
    }

    @Test func installRefusesReleasesOutsideTheCatalog() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let updater = EngineUpdater(paths: w.paths, catalog: EngineCatalog(releases: []))
        await #expect(throws: EngineUpdateError.self) { try await updater.install("stirred-wine-99.0", progress: { _ in }) }
    }

    @Test func readsUpstreamVersionAndBundledCatalog() throws {
        #expect(EngineUpdater.upstreamVersion(fromReleaseJSON: Data(#"{"tag_name": "11.22", "name": "x"}"#.utf8)) == "11.22")
        #expect(EngineUpdater.upstreamVersion(fromReleaseJSON: Data("nope".utf8)) == nil)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/engines.json")
        let catalog = try #require(EngineCatalog.load(from: url))
        let standard = SetupSources.standard
        #expect(catalog.releases.contains { $0.name == standard.engineName && $0.sha256 == standard.wineSHA256 && $0.url == standard.wineURL })
    }
}
