import Foundation

/// Why a backup was taken. Backups before risky operations are kept longer than the automatic one after each game.
public enum BackupReason: String, Codable, Sendable, CaseIterable {
    case session, engineChange, uninstall, move, manual, beforeRestore

    /// How many backups of this kind are kept.
    var keep: Int { self == .session ? 5 : 10 }
}

public struct BackupInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var reason: BackupReason
    public var date: Date
    /// Paths relative to the prefix that were saved.
    public var items: [String]
    /// Newest modification time (and file count) at the time: identical backups are skipped.
    public var fingerprint: String
}

/// Copies what belongs to the user (game settings, controls, save files, Steam's per-user data) out of the Windows environment,
/// so a prefix reset, an engine switch or an uninstall can never lose it. Copies use APFS cloning: instant, and no extra space
/// until the originals change. Games themselves and caches are not part of it.
public struct GameDataBackup: Sendable {
    public let paths: StirredPaths

    public init(paths: StirredPaths) { self.paths = paths }

    public var directory: URL { paths.root.appendingPathComponent("backups", isDirectory: true) }
    /// Items of the Steam environment are stored as before (relative to it); items of another environment are `@<name>/<relative path>`.
    private func location(of item: String) -> URL {
        if item.hasPrefix("@"), let slash = item.firstIndex(of: "/") {
            return paths.prefix(named: String(item[item.index(after: item.startIndex)..<slash]))
                .appendingPathComponent(String(item[item.index(after: slash)...]))
        }
        return paths.prefix(named: "steam").appendingPathComponent(item)
    }

    static let skippedLocal: Set<String> = ["steam", "temp", "crashdumps", "d3dscache", "microsoft", "packages", "wine", "programs"]
    static let skippedRoaming: Set<String> = ["microsoft"]

    /// What gets saved from every Windows environment (only what exists).
    func items() -> [String] {
        var result: [String] = []
        for name in paths.existingPrefixNames() {
            let tag = name == "steam" ? "" : "@\(name)/"
            result += items(inPrefix: name).map { tag + $0 }
        }
        return result.sorted()
    }

    /// What gets saved from one environment, relative to it.
    private func items(inPrefix name: String) -> [String] {
        let fm = FileManager.default
        let prefix = paths.prefix(named: name)
        var result: [String] = []
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            let home = "drive_c/users/\(user)"
            for (sub, skipped) in [("AppData/Local", Self.skippedLocal), ("AppData/Roaming", Self.skippedRoaming)] {
                let base = prefix.appendingPathComponent("\(home)/\(sub)").path
                for child in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !skipped.contains(child.lowercased()) {
                    result.append("\(home)/\(sub)/\(child)")
                }
            }
            for folder in ["Documents", "Saved Games"] where fm.fileExists(atPath: prefix.appendingPathComponent("\(home)/\(folder)").path) {
                result.append("\(home)/\(folder)")
            }
        }
        let userdata = "drive_c/Program Files (x86)/Steam/userdata"
        if fm.fileExists(atPath: prefix.appendingPathComponent(userdata).path) { result.append(userdata) }
        return result
    }

    func fingerprint(of items: [String]) -> String {
        var newest = Date.distantPast, count = 0
        for item in items {
            let root = location(of: item)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            if let a = try? FileManager.default.attributesOfItem(atPath: root.path), let d = a[.modificationDate] as? Date { newest = max(newest, d) }
            for case let rel as String in walker {
                count += 1
                if let a = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(rel).path),
                   let d = a[.modificationDate] as? Date { newest = max(newest, d) }
            }
        }
        return "\(Int(newest.timeIntervalSince1970))-\(count)"
    }

    public func list() -> [BackupInfo] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> BackupInfo? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name)/manifest.json")) else { return nil }
            return try? decoder.decode(BackupInfo.self, from: data)
        }.sorted { $0.name > $1.name }
    }

    /// Takes a backup. Returns nil when nothing changed since the last one of the same kind (or there is nothing to save).
    @discardableResult
    public func take(reason: BackupReason, now: Date = Date()) throws -> BackupInfo? {
        let items = items()
        guard !items.isEmpty else { return nil }
        let print = fingerprint(of: items)
        if reason == .session, list().first(where: { $0.reason == .session })?.fingerprint == print { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        var name = "\(formatter.string(from: now))-\(reason.rawValue)"
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { name = "\(formatter.string(from: now))-\(reason.rawValue)-\(n)"; n += 1 }
        let target = directory.appendingPathComponent(name, isDirectory: true)
        do {
            for item in items { try PrefixSnapshot.clone(location(of: item), target.appendingPathComponent("files/\(item)")) }
            let info = BackupInfo(name: name, reason: reason, date: now, items: items, fingerprint: print)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(info).write(to: target.appendingPathComponent("manifest.json"))
            prune()
            return info
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    func prune() {
        for reason in BackupReason.allCases {
            for old in list().filter({ $0.reason == reason }).dropFirst(reason.keep) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.name))
            }
        }
    }

    /// Puts the saved files back (files only in the live environment are left alone). Takes a safety backup first.
    public func restore(_ name: String) throws {
        guard let info = list().first(where: { $0.name == name }) else { throw BackupError.notFound(name) }
        try take(reason: .beforeRestore)
        for item in info.items {
            let saved = directory.appendingPathComponent("\(name)/files/\(item)"), live = location(of: item)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            try? FileManager.default.removeItem(at: live)
            try PrefixSnapshot.clone(saved, live)
        }
    }
}

public enum BackupError: Error, CustomStringConvertible, Sendable {
    case notFound(String), steamRunning
    public var description: String {
        switch self {
        case .notFound(let name): "No backup called \(name)."
        case .steamRunning: "Close Steam and the games before restoring a backup."
        }
    }
}

extension Launcher {
    public var backups: GameDataBackup { GameDataBackup(paths: paths) }

    /// Never fails the operation that asked for it: a backup problem must not block playing or switching engines.
    @discardableResult
    public func backupGameData(_ reason: BackupReason) -> BackupInfo? { try? backups.take(reason: reason) }

    public func restoreBackup(_ name: String) throws {
        guard steamState() == .stopped else { throw BackupError.steamRunning }
        try backups.restore(name)
    }
}
