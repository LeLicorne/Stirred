import Foundation

/// A game's identity across stores: `steam:3949040`, `epic:Salt`, `gog:1207658930`.
/// Recipes, personal settings and reports are filed by it, so any store can have them.
public struct GameKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let store: String
    public let id: String

    public init(store: String, id: String) {
        self.store = Self.sanitize(store)
        self.id = Self.sanitize(id)
    }

    public static func steam(_ appID: Int) -> GameKey { GameKey(store: "steam", id: String(appID)) }

    /// Store names and ids end up in file names: keep letters, digits, dot, dash and underscore only
    /// (a store id such as `../x` can never leave its folder).
    static func sanitize(_ text: String) -> String {
        let cleaned = String(text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "-" || scalar == "_" ? Character(scalar) : "_"
        })
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "_" : cleaned
    }

    /// Relative path of the per-game file: `steam/3949040` (the layout Steam recipes and settings always used).
    public var path: String { "\(store)/\(id)" }

    public var steamAppID: Int? { store == "steam" ? Int(id) : nil }

    public var description: String { "\(store):\(id)" }
}

extension Game {
    public var key: GameKey { GameKey(store: store, id: storeID) }
}

/// What the app knows about each store, in one place.
public enum Stores {
    public static func displayName(_ store: String) -> String {
        switch store {
        case "steam": "Steam"
        case "epic": "Epic Games"
        case "gog": "GOG"
        case "ubisoft": "Ubisoft Connect"
        case "ea": "EA App"
        case "battlenet": "Battle.net"
        default: store.capitalized
        }
    }

    /// Windows environment (Wine prefix) a store's games live in. Stores with their own client (Chromium and services) get their own
    /// so one cannot break another; stores without a client to run share `games`.
    public static func prefixName(forStore store: String) -> String {
        switch store {
        case "steam": "steam"
        case "ubisoft", "ea", "battlenet": store
        default: "games"
        }
    }
}
