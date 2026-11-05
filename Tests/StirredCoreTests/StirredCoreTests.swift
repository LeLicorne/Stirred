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

    @Test func dx11DefaultsToDXMT() {
        let plan = LaunchPlanner.plan(recipe: nil, detectedAPIs: [.d3d11], hardware: hw)
        #expect(plan.backend == .dxmt)
        #expect(plan.requiredComponents.isEmpty)
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
