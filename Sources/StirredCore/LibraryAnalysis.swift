import Foundation

public extension VerdictLevel {
    /// Best first.
    var rank: Int {
        switch self { case .works: 0; case .native: 1; case .likely: 2; case .maybe: 3; case .unknown: 4; case .no: 5 }
    }
}

public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public var appID: Int
    public var name: String
    public var verdict: Verdict
    public var installed: Bool
    /// True once the store's details (DirectX version, anti-cheat, third-party launchers) were applied.
    public var refined: Bool
    public var id: Int { appID }
}

/// Store details kept on disk so the same game is never asked for twice (Steam rate-limits its store API).
public struct StoreCache: Sendable {
    public let directory: URL

    public init(paths: StirredPaths = StirredPaths()) {
        directory = paths.root.appendingPathComponent("cache/store", isDirectory: true)
    }

    struct Record: Codable {
        var fetchedAt: Date
        var info: StoreInfo?   // nil: the game has no public store page
    }

    private func file(_ appID: Int) -> URL { directory.appendingPathComponent("\(appID).json") }

    /// Fresh details for a game (nil if never fetched or too old). `.some(nil)` means "known to have no store page".
    public func read(_ appID: Int, now: Date = Date()) -> StoreInfo?? {
        guard let data = try? Data(contentsOf: file(appID)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(Record.self, from: data) else { return nil }
        let maxAge: TimeInterval = record.info == nil ? 7 * 86_400 : 30 * 86_400
        guard now.timeIntervalSince(record.fetchedAt) < maxAge else { return nil }
        return .some(record.info)
    }

    public func write(_ appID: Int, info: StoreInfo?, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Record(fetchedAt: now, info: info)) { try? data.write(to: file(appID)) }
    }
}

public enum LibraryAnalysis {
    /// What Steam's cache files alone tell us (no DirectX version, no anti-cheat notice).
    static func offlineInfo(_ entry: AppInfoEntry) -> StoreInfo {
        StoreInfo(appID: entry.appID, name: entry.name, isFree: false,
                  windows: entry.oses.isEmpty || entry.oses.contains("windows"), mac: entry.oses.contains("macos"),
                  categories: [], notices: "", headerImage: nil)
    }

    /// Instant verdicts for every owned game, using cached store details where we already have them.
    public static func entries(
        for games: [AppInfoEntry], installed: Set<String>, recipes: RecipeRepository, cache: StoreCache
    ) -> [LibraryEntry] {
        games.map { game in
            let recipe = recipes.recipe(forSteamAppID: game.appID)
            let cached = cache.read(game.appID)
            let info: StoreInfo
            if let cached, let cachedInfo = cached { info = cachedInfo } else { info = offlineInfo(game) }
            return LibraryEntry(
                appID: game.appID, name: game.name,
                verdict: CompatVerdict.evaluate(info: info, deck: game.deck, recipe: recipe),
                installed: installed.contains(String(game.appID)), refined: cached != nil)
        }
    }

    /// Only verdicts that the store's details could still change are worth a request.
    public static func needsRefinement(_ entry: LibraryEntry) -> Bool {
        !entry.refined && [.likely, .maybe, .unknown].contains(entry.verdict.level)
    }

    /// Fetches store details one game at a time, slowly (the store API allows about 200 requests per 5 minutes), most
    /// promising games first, and reports each improved entry. Cached games cost nothing.
    public static func refine(
        _ entries: [LibraryEntry], games: [AppInfoEntry], recipes: RecipeRepository, cache: StoreCache, client: StoreClient,
        delay: UInt64 = 1_600_000_000, shouldStop: @Sendable () -> Bool,
        onUpdate: @Sendable (LibraryEntry, Int, Int) -> Void
    ) async {
        let byID = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0) })
        let todo = entries.filter(needsRefinement).sorted {
            $0.verdict.level.rank != $1.verdict.level.rank ? $0.verdict.level.rank < $1.verdict.level.rank : $0.name < $1.name
        }
        for (index, entry) in todo.enumerated() {
            if shouldStop() { return }
            guard let game = byID[entry.appID] else { continue }
            do {
                let info = try await client.info(appID: entry.appID)
                cache.write(entry.appID, info: info)
                var updated = entry
                updated.refined = true
                if let info {
                    updated.verdict = CompatVerdict.evaluate(info: info, deck: game.deck, recipe: recipes.recipe(forSteamAppID: entry.appID))
                }
                onUpdate(updated, index + 1, todo.count)
            } catch {
                // Rate limited: wait it out. Anything else: skip this game and carry on.
                if case SetupError.httpStatus(let code) = error, code == 429 || code == 403 {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: delay)
        }
    }
}

extension Launcher {
    public var storeCache: StoreCache { StoreCache(paths: paths) }

    /// Verdicts for the whole owned library, immediately (cached store details included).
    public func libraryEntries() throws -> (games: [AppInfoEntry], entries: [LibraryEntry]) {
        let games = try ownedGames()
        let installed = Set(((try? installedGames()) ?? []).map(\.storeID))
        return (games, LibraryAnalysis.entries(for: games, installed: installed, recipes: recipes, cache: storeCache))
    }
}
