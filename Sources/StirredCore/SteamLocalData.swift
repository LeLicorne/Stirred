import Foundation

/// What Steam's own cache files say about one app (read offline, no network).
public struct AppInfoEntry: Sendable, Equatable, Identifiable {
    public var appID: Int
    public var name: String
    public var type: String          // "Game", "DLC", "Tool", "Demo"...
    public var oses: Set<String>     // "windows", "macos", "linux"
    public var deck: DeckStatus
    public var id: Int { appID }

    public var isGame: Bool { type.lowercased() == "game" }
}

public enum SteamLocalDataError: Error, CustomStringConvertible, Sendable {
    case missing(String)
    case unsupportedFormat(String)
    case truncated

    public var description: String {
        switch self {
        case .missing(let file): "\(file) not found: open Steam once and sign in so it can build your library data."
        case .unsupportedFormat(let what): "Steam's local data format is not supported (\(what)). Steam probably changed it."
        case .truncated: "Steam's local data file is truncated or corrupt."
        }
    }
}

// MARK: - Valve binary KeyValues

enum KVValue {
    case string(String), int(Int64), object([String: KVValue])

    subscript(key: String) -> KVValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var int: Int64? { if case .int(let i) = self { return i } else { return nil } }
}

/// Reader for Steam's binary KeyValues (`packageinfo.vdf`, `appinfo.vdf`). Every read is bounds-checked.
struct BinaryKVReader {
    let bytes: [UInt8]
    var pos: Int
    /// appinfo v41 stores key names in a string table and only an index in the stream.
    let strings: [String]?

    mutating func need(_ n: Int) throws { if n < 0 || pos + n > bytes.count { throw SteamLocalDataError.truncated } }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        let low = UInt64(try u32()), high = UInt64(try u32())
        return low | high << 32
    }

    mutating func cstring() throws -> String {
        guard let end = bytes[pos...].firstIndex(of: 0) else { throw SteamLocalDataError.truncated }
        defer { pos = end + 1 }
        return String(decoding: bytes[pos..<end], as: UTF8.self)
    }

    mutating func key() throws -> String {
        guard let strings else { return try cstring() }
        let index = Int(try u32())
        guard index < strings.count else { throw SteamLocalDataError.truncated }
        return strings[index]
    }

    /// Reads children until the end marker (0x08).
    mutating func object() throws -> [String: KVValue] {
        var out: [String: KVValue] = [:]
        while true {
            try need(1)
            let type = bytes[pos]; pos += 1
            if type == 8 { return out }
            let name = try key()
            switch type {
            case 0: out[name] = .object(try object())
            case 1: out[name] = .string(try cstring())
            case 2: out[name] = .int(Int64(Int32(bitPattern: try u32())))
            case 3, 4, 6: _ = try u32()
            case 5:
                while true { try need(2); if bytes[pos] == 0 && bytes[pos + 1] == 0 { pos += 2; break }; pos += 2 }
            case 7: out[name] = .int(Int64(bitPattern: try u64()))
            case 10: out[name] = .int(Int64(bitPattern: try u64()))
            default: throw SteamLocalDataError.unsupportedFormat("value type \(type)")
            }
        }
    }
}

// MARK: - packageinfo.vdf: which apps this Steam install knows you own

public enum PackageInfoReader {
    public static func ownedAppIDs(_ data: Data) throws -> Set<Int> {
        var r = BinaryKVReader(bytes: [UInt8](data), pos: 0, strings: nil)
        let magic = try r.u32()
        guard magic >> 8 == 0x065655, magic & 0xFF >= 0x27 else {
            throw SteamLocalDataError.unsupportedFormat(String(format: "packageinfo magic %08x", magic))
        }
        _ = try r.u32()   // universe
        var apps: Set<Int> = []
        while r.pos + 4 <= r.bytes.count {
            let packageID = try r.u32()
            if packageID == 0xFFFF_FFFF { break }
            try r.need(24 + (magic & 0xFF >= 0x28 ? 8 : 0))
            r.pos += 24 + (magic & 0xFF >= 0x28 ? 8 : 0)   // sha1 (20) + change number (4) [+ token (8)]
            let entry = try r.object()
            for package in entry.values {
                guard case .object(let appids)? = package["appids"] else { continue }
                for case .int(let id) in appids.values { apps.insert(Int(id)) }
            }
        }
        return apps
    }
}

// MARK: - appinfo.vdf: name, type, platforms and Steam Deck status of every app Steam has looked at

public enum AppInfoReader {
    public static func read(_ data: Data) throws -> [Int: AppInfoEntry] {
        let bytes = [UInt8](data)
        var r = BinaryKVReader(bytes: bytes, pos: 0, strings: nil)
        let magic = try r.u32()
        guard magic >> 8 == 0x075644, magic & 0xFF >= 0x28 else {
            throw SteamLocalDataError.unsupportedFormat(String(format: "appinfo magic %08x", magic))
        }
        _ = try r.u32()   // universe
        var strings: [String]?
        if magic & 0xFF >= 0x29 {
            let offset = Int(Int64(bitPattern: try r.u64()))
            var table = BinaryKVReader(bytes: bytes, pos: offset, strings: nil)
            let count = Int(try table.u32())
            var list: [String] = []
            list.reserveCapacity(count)
            for _ in 0..<count { list.append(try table.cstring()) }
            strings = list
        }
        var entries: [Int: AppInfoEntry] = [:]
        while r.pos + 8 <= bytes.count {
            let appID = Int(try r.u32())
            if appID == 0 { break }
            let size = Int(try r.u32())
            let end = r.pos + size
            try r.need(size)
            // infoState (4) + lastUpdated (4) + token (8) + sha1 (20) + change number (4) + binary sha1 (20)
            var body = BinaryKVReader(bytes: bytes, pos: r.pos + 4 + 4 + 8 + 20 + 4 + 20, strings: strings)
            if let root = try? body.object() {
                let appinfo = root["appinfo"] ?? .object(root)
                if let common = appinfo["common"], let name = common["name"]?.string {
                    let oses = Set((common["oslist"]?.string ?? "").split(separator: ",").map { String($0).lowercased() })
                    let category = Int(common["steam_deck_compatibility"]?["category"]?.int ?? 0)
                    entries[appID] = AppInfoEntry(
                        appID: appID, name: name, type: common["type"]?.string ?? "",
                        oses: oses, deck: DeckStatus(rawValue: category) ?? .unknown)
                }
            }
            r.pos = end
        }
        return entries
    }
}

extension Launcher {
    /// The games this Steam install knows you own, from its own cache files: no network, no API key.
    public func ownedGames() throws -> [AppInfoEntry] {
        let cache = try steam().steamRoot.appendingPathComponent("appcache", isDirectory: true)
        let packageFile = cache.appendingPathComponent("packageinfo.vdf"), appFile = cache.appendingPathComponent("appinfo.vdf")
        for file in [packageFile, appFile] where !FileManager.default.fileExists(atPath: file.path) {
            throw SteamLocalDataError.missing(file.lastPathComponent)
        }
        let owned = try PackageInfoReader.ownedAppIDs(try Data(contentsOf: packageFile))
        let info = try AppInfoReader.read(try Data(contentsOf: appFile))
        return owned.compactMap { info[$0] }.filter(\.isGame).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
