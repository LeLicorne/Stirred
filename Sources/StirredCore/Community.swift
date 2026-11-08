import Foundation

/// Sharing recipes between people, with no server: a recipe is one small JSON file that can be exported, sent around
/// (or proposed to the project through a pull request) and imported. An imported recipe lives in the user's own folder,
/// wins over the bundled recipe for that game, and can be removed again. Nothing is ever uploaded by Stirred.
///
/// A recipe from someone else is untrusted input. It is only accepted when every field stays inside what a recipe is meant
/// to do (graphics settings, launch arguments, harmless environment variables), and it is never marked "verified" here.
public enum CommunityRecipes {
    public static let maxBytes = 64 * 1024

    static let allowedEnvPrefixes = ["DXVK_", "MVK_", "WINE", "SDL_", "MTL_", "STEAM"]
    static let allowedOptionPrefixes = ["dxvk.", "d3d9.", "d3d10.", "d3d11.", "dxgi."]
    static let allowedOverrideModes: Set<String> = ["native", "builtin", "native,builtin", "builtin,native", ""]

    public enum ImportError: Error, CustomStringConvertible, Sendable {
        case tooLarge, notARecipe(String), rejected([String])

        public var description: String {
            switch self {
            case .tooLarge: "This file is too large to be a recipe."
            case .notARecipe(let why): "This is not a Stirred recipe (\(why))."
            case .rejected(let problems): "Recipe refused: " + problems.joined(separator: "; ")
            }
        }
    }

    static var decoder: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
    static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    /// Why a recipe must not be accepted (empty means fine).
    public static func problems(in recipe: Recipe) -> [String] {
        var out: [String] = []
        if recipe.appid <= 0 { out.append("invalid app id") }
        for (key, value) in recipe.env ?? [:] {
            if !allowedEnvPrefixes.contains(where: key.hasPrefix) { out.append("environment variable \(key) is not allowed") }
            if value.count > 200 || value.contains("\n") { out.append("environment value of \(key) is not allowed") }
        }
        for (name, mode) in recipe.dllOverrides ?? [:] {
            if name.isEmpty || !name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) { out.append("DLL name \(name) is not allowed") }
            if !allowedOverrideModes.contains(mode) { out.append("DLL mode \(mode) is not allowed") }
        }
        for arg in recipe.launchArgs ?? [] where arg.count > 200 || arg.contains("\n") { out.append("a launch argument is not allowed") }
        for (key, value) in recipe.dxvkOptions ?? [:] {
            if !allowedOptionPrefixes.contains(where: key.hasPrefix) || key.contains("\n") { out.append("graphics option \(key) is not allowed") }
            if value.count > 64 || value.contains("\n") { out.append("graphics option value of \(key) is not allowed") }
        }
        if let updater = recipe.updater {
            let path = updater.executable
            if path.hasPrefix("/") || path.hasPrefix("\\") || path.contains("..") || !path.lowercased().hasSuffix(".exe") {
                out.append("updater path is not allowed")
            }
            for dll in updater.disabledDlls ?? [] where !dll.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                out.append("updater DLL name \(dll) is not allowed")
            }
        }
        if (recipe.notes ?? "").count > 2000 { out.append("notes are too long") }
        return out
    }

    /// Reads a recipe from untrusted bytes. The result is never `verified` and its notes say where it comes from.
    public static func parse(_ data: Data) throws -> Recipe {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        var recipe: Recipe
        do {
            // `verified` is ours to set, so a file without it is fine.
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.notARecipe("not a JSON object") }
            object["verified"] = false
            recipe = try decoder.decode(Recipe.self, from: try JSONSerialization.data(withJSONObject: object))
        } catch let error as ImportError { throw error } catch { throw ImportError.notARecipe("\(error.localizedDescription)") }
        let issues = problems(in: recipe)
        guard issues.isEmpty else { throw ImportError.rejected(issues.sorted()) }
        recipe.verified = false
        let note = "Imported recipe: not verified on this Mac."
        recipe.notes = [recipe.notes, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return recipe
    }

    /// The file to share. `tested`: the person says they played the game with these settings; the notes then record on what
    /// (chip, memory, macOS, engine, date), which is all a maintainer needs. No path, name or account is ever included.
    public static func export(_ recipe: Recipe, tested: Bool, system: SystemInfo, engine: String, date: Date = Date()) throws -> Data {
        var shared = recipe
        shared.verified = tested
        if tested {
            let day = ISO8601DateFormatter().string(from: date).prefix(10)
            let line = "Tested \(day) on \(system.chip) \(system.memoryGB) GB, macOS \(system.macOS), engine \(engine)."
            shared.notes = [recipe.notes, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        return try encoder.encode(shared)
    }
}

extension RecipeRepository {
    /// Where imported recipes live (read first, before the bundled ones).
    public func importedFile(_ appID: Int) -> URL? { userDirectory?.appendingPathComponent("steam/\(appID).json") }

    public func importedRecipe(forSteamAppID appID: Int) -> Recipe? {
        guard let url = importedFile(appID), let data = try? Data(contentsOf: url) else { return nil }
        return try? CommunityRecipes.decoder.decode(Recipe.self, from: data)
    }

    @discardableResult
    public func saveImported(_ recipe: Recipe) throws -> Bool {
        guard let url = importedFile(recipe.appid) else { throw StirredError.blocked("No folder for imported recipes.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let replaced = FileManager.default.fileExists(atPath: url.path)
        try CommunityRecipes.encoder.encode(recipe).write(to: url)
        return replaced
    }

    public func removeImported(_ appID: Int) throws {
        if let url = importedFile(appID), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func importedAppIDs() -> [Int] {
        guard let dir = userDirectory?.appendingPathComponent("steam"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { $0.hasSuffix(".json") ? Int($0.dropLast(5)) : nil }.sorted()
    }
}

extension Launcher {
    public func importRecipe(from data: Data) throws -> (recipe: Recipe, replaced: Bool) {
        let recipe = try CommunityRecipes.parse(data)
        return (recipe, try recipes.saveImported(recipe))
    }

    /// The recipe as it applies to this game right now (bundled or imported, with personal settings), ready to share.
    public func exportRecipe(for game: Game, tested: Bool) throws -> Data {
        guard let recipe = recipe(for: game) else { throw StirredError.blocked("\(game.name) has no recipe or personal settings to share yet.") }
        let engineName = (try? engine().name) ?? "unknown"
        return try CommunityRecipes.export(recipe, tested: tested, system: .current(), engine: engineName)
    }
}
