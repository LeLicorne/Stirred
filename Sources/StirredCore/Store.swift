import Foundation

// MARK: - Steam store facts

public struct StoreInfo: Sendable, Equatable {
    public var appID: Int
    public var name: String
    public var isFree: Bool
    public var windows: Bool
    public var mac: Bool
    public var categories: [String]
    /// DRM / third-party account notices, HTML removed.
    public var notices: String
    public var headerImage: URL?
    /// Minimum DirectX version from the store's system requirements (nil if not stated).
    public var directX: Int? = nil
}

/// Steam Deck compatibility, a useful proxy: Deck-verified games are known to run through Wine-based layers.
public enum DeckStatus: Int, Sendable {
    case unknown = 0, unsupported = 1, playable = 2, verified = 3
}

public struct StoreSearchResult: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
}

/// Reads Steam's public store endpoints. Only used when the user asks about a game; `fetch` is injectable for tests.
public struct StoreClient: Sendable {
    public var fetch: @Sendable (URL) async throws -> Data

    public init(fetch: @escaping @Sendable (URL) async throws -> Data = StoreClient.liveFetch) {
        self.fetch = fetch
    }

    public static let liveFetch: @Sendable (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw SetupError.httpStatus(status) }
        return data
    }

    // MARK: Parsing (pure, tested)

    /// "https://store.steampowered.com/app/1625450/Muck/", "steam://run/1625450" or "1625450" -> 1625450.
    public static func parseAppID(from input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(text), id > 0 { return id }
        guard let regex = try? NSRegularExpression(pattern: #"(?:/app/|/run/|/install/|appid=)(\d+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    public static func parseInfo(_ data: Data, appID: Int) -> StoreInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any], entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any], let name = d["name"] as? String else { return nil }
        let platforms = d["platforms"] as? [String: Any] ?? [:]
        let categories = (d["categories"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        let notices = [d["drm_notice"], d["ext_user_account_notice"]].compactMap { $0 as? String }.joined(separator: " ")
        return StoreInfo(
            appID: appID, name: name, isFree: d["is_free"] as? Bool ?? false,
            windows: platforms["windows"] as? Bool ?? true, mac: platforms["mac"] as? Bool ?? false,
            categories: categories,
            notices: notices.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression),
            headerImage: (d["header_image"] as? String).flatMap(URL.init(string:)),
            directX: directXVersion(in: d["pc_requirements"]))
    }

    /// "DirectX: Version 12" in the minimum requirements -> 12.
    static func directXVersion(in requirements: Any?) -> Int? {
        guard let minimum = (requirements as? [String: Any])?["minimum"] as? String else { return nil }
        let text = minimum.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"DirectX:?\s*(?:Version\s*)?(\d+)"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// Prefers an exact name match (the store's relevance order puts "Hades II" before "Hades").
    public static func bestMatch(_ results: [StoreSearchResult], for term: String) -> StoreSearchResult? {
        func normal(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return results.first { normal($0.name) == normal(term) } ?? results.first
    }

    public static func parseSearch(_ data: Data) -> [StoreSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item["type"] as? String == "app", let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return StoreSearchResult(id: id, name: name)
        }
    }

    public static func parseDeck(_ data: Data) -> DeckStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let category = results["resolved_category"] as? Int else { return .unknown }
        return DeckStatus(rawValue: category) ?? .unknown
    }

    // MARK: Network

    public func info(appID: Int) async throws -> StoreInfo? {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&cc=us&l=english")!
        return Self.parseInfo(try await fetch(url), appID: appID)
    }

    public func deckStatus(appID: Int) async -> DeckStatus {
        let url = URL(string: "https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=\(appID)")!
        guard let data = try? await fetch(url) else { return .unknown }
        return Self.parseDeck(data)
    }

    public func search(_ term: String) async throws -> [StoreSearchResult] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [.init(name: "term", value: term), .init(name: "l", value: "english"), .init(name: "cc", value: "us")]
        return Self.parseSearch(try await fetch(components.url!))
    }
}

// MARK: - Verdict

public enum VerdictLevel: String, Sendable {
    case works     // tested with Stirred
    case native    // has a Mac version: prefer it
    case likely    // no red flag and Steam Deck verified
    case maybe
    case no
    case unknown
}

public struct Verdict: Sendable, Equatable {
    public var level: VerdictLevel
    public var headline: String
    public var reasons: [String]
}

public enum CompatVerdict {
    static let antiCheat = #"(?i)easy ?anti-?cheat|battleye|vanguard|nprotect|xigncode|faceit"#
    static let ubisoft = #"(?i)ubisoft connect|ubisoft account|uplay"#
    static let otherLaunchers = #"(?i)ea app|origin|rockstar games launcher|battle\.net|epic games|bethesda\.net|2k launcher"#

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Combines what we tested (recipe), what the store says and Steam Deck compatibility. Order of authority: our own tests,
    /// then blockers, then a native Mac version, then the Deck hint.
    public static func evaluate(info: StoreInfo, deck: DeckStatus, recipe: Recipe?) -> Verdict {
        var reasons: [String] = []
        let facts = (info.categories + [info.notices]).joined(separator: " ")
        let caveat = "Stirred runs DirectX 9-11 games (DXVK). DirectX 12-only games do not run yet."

        if let recipe, recipe.verified || recipe.status == .unsupported {
            switch recipe.status {
            case .perfect, .playable:
                return Verdict(level: .works, headline: "Works: tested with Stirred", reasons: [recipe.notes ?? "Verified on a real Mac."])
            case .experimental:
                return Verdict(level: .maybe, headline: "Partly works", reasons: [recipe.notes ?? "Experimental support."])
            case .offlineOnly:
                return Verdict(level: .maybe, headline: "Offline only", reasons: [recipe.notes ?? "Online play is blocked by an anti-cheat."])
            case .unsupported:
                return Verdict(level: .no, headline: "Does not work", reasons: [recipe.notes ?? "Known blocker."])
            case .unknown: break
            }
        }

        if matches(antiCheat, facts) {
            return Verdict(level: .no, headline: "Will not run: anti-cheat",
                           reasons: ["This game uses an anti-cheat that cannot run on macOS, and Stirred never tries to bypass one."])
        }
        if matches(ubisoft, facts) {
            return Verdict(level: .no, headline: "Will not run yet: needs Ubisoft Connect",
                           reasons: ["Ubisoft Connect hangs under Wine on this setup (Trackmania failed the same way)."])
        }
        if info.mac {
            return Verdict(level: .native, headline: "Has a Mac version: play that one",
                           reasons: ["A native version runs faster and needs no compatibility layer. Install it with the Mac Steam app."])
        }
        if let dx = info.directX, dx >= 12 {
            return Verdict(level: .no, headline: "Will not run yet: needs DirectX 12",
                           reasons: ["The store lists DirectX \(dx) as a minimum. Stirred runs DirectX 9-11 games (DXVK); DirectX 12 is not supported yet."])
        }
        if matches(otherLaunchers, facts) {
            reasons.append("Needs a third-party launcher or account that Stirred has not tested.")
        }
        if facts.range(of: "valve anti-cheat", options: .caseInsensitive) != nil {
            reasons.append("Uses Valve Anti-Cheat: online play on secured servers risks a ban, offline play is fine.")
        }
        switch deck {
        case .verified where reasons.isEmpty:
            return Verdict(level: .likely, headline: "Probably works (Steam Deck Verified)",
                           reasons: ["Verified games are known to run through Wine-based layers.", caveat])
        case .verified:
            return Verdict(level: .maybe, headline: "Might work", reasons: ["Steam Deck Verified."] + reasons + [caveat])
        case .playable:
            return Verdict(level: .maybe, headline: "Might work (Steam Deck: Playable)",
                           reasons: ["Playable on Steam Deck, with some tweaks."] + reasons + [caveat])
        case .unsupported:
            return Verdict(level: .maybe, headline: "Doubtful (Steam Deck: Unsupported)",
                           reasons: ["Unsupported on Steam Deck, often because of an anti-cheat, a launcher or performance."] + reasons + [caveat])
        case .unknown:
            return Verdict(level: .unknown, headline: "Unknown: nobody has tested it",
                           reasons: reasons + ["No test and no Steam Deck data. You can still try it: the report tells what happens.", caveat])
        }
    }
}

public struct GameCheck: Sendable, Equatable {
    public var info: StoreInfo
    public var deck: DeckStatus
    public var verdict: Verdict
    public var installed: Bool
}

extension Launcher {
    /// "Will it run?" for any Steam game, installed or not.
    public func check(appID: Int, client: StoreClient = StoreClient()) async throws -> GameCheck? {
        guard let info = try await client.info(appID: appID) else { return nil }
        let deck = await client.deckStatus(appID: appID)
        let verdict = CompatVerdict.evaluate(info: info, deck: deck, recipe: recipes.recipe(forSteamAppID: appID))
        let installed = ((try? installedGames()) ?? []).contains { $0.storeID == String(appID) }
        return GameCheck(info: info, deck: deck, verdict: verdict, installed: installed)
    }
}
