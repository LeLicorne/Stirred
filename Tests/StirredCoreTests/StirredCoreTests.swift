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
