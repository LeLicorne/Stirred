import Foundation

/// What uninstalling a game will delete, computed up front so the user can confirm it.
public struct UninstallPlan: Sendable, Equatable {
    public let game: Game
    /// Existing paths that will be deleted (the game's folder first, its Steam manifest last).
    public let paths: [URL]
    public let bytes: Int64
}

public enum UninstallError: Error, CustomStringConvertible, Sendable {
    case notInstalled
    case unsafePath(String)
    case gameRunning

    public var description: String {
        switch self {
        case .notInstalled: "This game has no install folder."
        case .unsafePath(let path): "Refusing to delete \(path): it is not a game folder inside Steam's steamapps/common."
        case .gameRunning: "The game is still running. Stop it first."
        }
    }
}

/// Does what Steam's "Delete local content" does: removes the game's files and bookkeeping. Steam Cloud saves are untouched.
public enum Uninstaller {
    public static func plan(for game: Game, steamRoot: URL) throws -> UninstallPlan {
        guard game.store == "steam", let appID = Int(game.storeID), appID > 0 else {
            throw UninstallError.unsafePath("only Steam games can be uninstalled here")
        }
        guard let folder = game.installDirectory else { throw UninstallError.notInstalled }
        let steamapps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamapps.appendingPathComponent("common", isDirectory: true).resolvingSymlinksInPath()
        // The game folder must be exactly one level below steamapps/common once symlinks are resolved:
        // a manifest saying "installdir = ../.." or a symlink pointing elsewhere must never get anything deleted.
        let resolved = folder.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(common.path + "/"),
              resolved.pathComponents.count == common.pathComponents.count + 1 else {
            throw UninstallError.unsafePath(folder.path)
        }
        let id = String(appID)
        let candidates = [
            resolved,
            steamapps.appendingPathComponent("shadercache/\(id)"),
            steamapps.appendingPathComponent("downloading/\(id)"),
            steamapps.appendingPathComponent("temp/\(id)"),
            steamapps.appendingPathComponent("workshop/content/\(id)"),
            steamapps.appendingPathComponent("workshop/appworkshop_\(id).acf"),
            steamapps.appendingPathComponent("appmanifest_\(id).acf"),
        ]
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        return UninstallPlan(game: game, paths: existing, bytes: existing.reduce(0) { $0 + size(of: $1) })
    }

    /// Deletes permanently (moving 50 GB to the Trash would not free any space).
    public static func execute(_ plan: UninstallPlan) throws {
        for url in plan.paths { try FileManager.default.removeItem(at: url) }
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

extension Launcher {
    /// For the confirmation dialog.
    public func uninstallPlan(for game: Game) throws -> UninstallPlan {
        try Uninstaller.plan(for: game, steamRoot: try steam().steamRoot)
    }

    /// Closes Steam (it would otherwise keep believing the game is installed), deletes the files, returns the bytes freed.
    /// Steam starts again by itself the next time a game is played.
    @discardableResult
    public func uninstall(_ game: Game, onPhase: @Sendable (String) -> Void = { _ in }) async throws -> Int64 {
        let plan = try uninstallPlan(for: game)
        if SystemSampler.sample(processNeedle: processNeedle(for: game), at: 0).processCount > 0 {
            throw UninstallError.gameRunning
        }
        if steamState() != .stopped {
            onPhase("Closing Steam…")
            await quitSteam(graceful: true)
        }
        onPhase("Deleting files…")
        try Uninstaller.execute(plan)
        return plan.bytes
    }
}
