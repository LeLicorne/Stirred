import Foundation

// MARK: - Space

public struct DiskSpace: Sendable, Equatable {
    public var total: Int64
    public var free: Int64

    /// Space of the volume holding `url` (what the system would let an app use, purgeable space included).
    public static func of(_ url: URL) -> DiskSpace? {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 { target.deleteLastPathComponent() }
        guard let values = try? target.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskSpace(total: Int64(total), free: free)
    }

    /// Below this a game install may fail half way: worth a warning.
    public static let lowSpaceThreshold: Int64 = 20_000_000_000
    public var isLow: Bool { free < Self.lowSpaceThreshold }
}

// MARK: - Things that can be deleted without losing anything that matters

public struct Reclaimable: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var urls: [URL]
    public var bytes: Int64
}

public enum DiskCleaner {
    /// Only the contents of these two folders are ever deleted, never the folders themselves.
    public static func reclaimables(paths: StirredPaths, steamRoot: URL?) -> [Reclaimable] {
        var out: [Reclaimable] = []
        func children(_ folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
        }
        let downloads = children(paths.downloads)
        if !downloads.isEmpty {
            out.append(Reclaimable(id: "downloads", title: "Setup downloads",
                                   detail: "Archives kept from the first-run setup. They are downloaded again if you reinstall.",
                                   urls: downloads, bytes: downloads.reduce(0) { $0 + Uninstaller.size(of: $1) }))
        }
        if let steamRoot {
            let shaders = children(steamRoot.appendingPathComponent("steamapps/shadercache", isDirectory: true))
            if !shaders.isEmpty {
                out.append(Reclaimable(id: "shadercache", title: "Steam shader cache",
                                       detail: "Rebuilt by Steam when needed; the first launch of a game may be slightly slower.",
                                       urls: shaders, bytes: shaders.reduce(0) { $0 + Uninstaller.size(of: $1) }))
            }
        }
        return out
    }

    @discardableResult
    public static func clean(_ item: Reclaimable) -> Int64 {
        var freed: Int64 = 0
        for url in item.urls {
            let size = Uninstaller.size(of: url)
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }
}

// MARK: - Moving a game to another disk

public enum StorageLocation: Sendable, Equatable {
    case thisMac
    case external(URL)
    /// Moved to a disk that is not connected right now.
    case missing(URL)
}

public enum MoveError: Error, CustomStringConvertible, Sendable {
    case notAMovableGame(String), alreadyMoved, notMoved, gameRunning, notEnoughSpace(needed: Int64, free: Int64)
    case destinationExists(String), unsafeDestination(String), diskNotConnected(String), verificationFailed

    public var description: String {
        let gb = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch self {
        case .notAMovableGame(let why): return "This game cannot be moved: \(why)."
        case .alreadyMoved: return "This game is already on another disk."
        case .notMoved: return "This game is already on this Mac."
        case .gameRunning: return "The game is running. Stop it first."
        case .notEnoughSpace(let needed, let free): return "Not enough free space: \(gb(needed)) needed, \(gb(free)) available."
        case .destinationExists(let path): return "\(path) already exists. Choose another disk or folder."
        case .unsafeDestination(let why): return "Cannot use this destination: \(why)."
        case .diskNotConnected(let path): return "The disk holding this game is not connected (\(path))."
        case .verificationFailed: return "The copy does not match the original, so nothing was changed."
        }
    }
}

public struct MovePlan: Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case toExternal, backToThisMac }
    public let game: Game
    public let direction: Direction
    /// The game's place inside Steam's library: a real folder, or a link to the other disk once moved.
    public let libraryFolder: URL
    /// Where the files are now.
    public let from: URL
    /// Where the files will be (for "back": a temporary folder beside the library folder, renamed at the end).
    public let to: URL
    public let bytes: Int64
}

/// A moved game stays registered in Steam's library: its folder in `steamapps/common` becomes a link to the other disk, so Steam
/// and Wine see the same path as before. Nothing in Steam's own files is edited.
public enum GameMover {
    /// Asked of the file system each time (a URL object caches what it was asked before).
    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    public static func location(of game: Game) -> StorageLocation {
        guard let folder = game.installDirectory, isLink(folder) else { return .thisMac }
        let target = folder.resolvingSymlinksInPath()
        let raw = (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) ?? target.path
        return FileManager.default.fileExists(atPath: folder.path) ? .external(target) : .missing(URL(fileURLWithPath: raw))
    }

    private static func libraryFolder(for game: Game, steamRoot: URL) throws -> URL {
        guard game.store == "steam", let folder = game.installDirectory else { throw MoveError.notAMovableGame("it has no install folder") }
        let common = steamRoot.appendingPathComponent("steamapps/common", isDirectory: true).resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().resolvingSymlinksInPath().path == common.path else {
            throw MoveError.notAMovableGame("its folder is not directly inside Steam's steamapps/common")
        }
        return folder
    }

    public static func plan(for game: Game, to destination: URL, steamRoot: URL) throws -> MovePlan {
        let folder = try libraryFolder(for: game, steamRoot: steamRoot)
        if isLink(folder) { throw MoveError.alreadyMoved }
        guard game.downloadProgress == nil else { throw MoveError.notAMovableGame("Steam is still downloading or updating it") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MoveError.unsafeDestination("the folder does not exist")
        }
        let home = steamRoot.resolvingSymlinksInPath().path
        let dest = destination.resolvingSymlinksInPath()
        if dest.path == home || dest.path.hasPrefix(home + "/") || dest.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") {
            throw MoveError.unsafeDestination("choose a folder outside Steam's own folder")
        }
        guard FileManager.default.isWritableFile(atPath: dest.path) else { throw MoveError.unsafeDestination("the folder is not writable") }
        let target = dest.appendingPathComponent("Stirred Games", isDirectory: true).appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { throw MoveError.destinationExists(target.path) }
        let bytes = Uninstaller.size(of: folder)
        if !sameVolume(folder, dest), let space = DiskSpace.of(dest), space.free < bytes + 1_000_000_000 {
            throw MoveError.notEnoughSpace(needed: bytes + 1_000_000_000, free: space.free)
        }
        return MovePlan(game: game, direction: .toExternal, libraryFolder: folder, from: folder, to: target, bytes: bytes)
    }

    public static func planBack(for game: Game, steamRoot: URL) throws -> MovePlan {
        let folder = try libraryFolder(for: game, steamRoot: steamRoot)
        guard isLink(folder) else { throw MoveError.notMoved }
        guard case .external(let real) = location(of: game) else {
            throw MoveError.diskNotConnected((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) ?? folder.path)
        }
        let bytes = Uninstaller.size(of: real)
        if let space = DiskSpace.of(folder.deletingLastPathComponent()), !sameVolume(real, folder), space.free < bytes + 1_000_000_000 {
            throw MoveError.notEnoughSpace(needed: bytes + 1_000_000_000, free: space.free)
        }
        let temp = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".stirred-moving", isDirectory: true)
        return MovePlan(game: game, direction: .backToThisMac, libraryFolder: folder, from: real, to: temp, bytes: bytes)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func id(_ u: URL) -> AnyHashable? {
            var target = u
            while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 { target.deleteLastPathComponent() }
            return (try? target.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x == y
    }

    /// Copies a folder file by file, reporting progress (0...1). Links inside it stay links.
    static func copyTree(from: URL, to: URL, bytes: Int64, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(atPath: from.path) else { return }
        var done: Int64 = 0
        var lastReported = -1
        for case let relative as String in walker {
            let item = from.appendingPathComponent(relative), target = to.appendingPathComponent(relative)
            let attributes = try fm.attributesOfItem(atPath: item.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: item, to: target)
                done += Int64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
                let percent = bytes > 0 ? Int(Double(done) / Double(bytes) * 100) : 100
                if percent != lastReported { lastReported = percent; progress(min(1, Double(done) / Double(max(bytes, 1)))) }
            }
        }
    }

    /// Moves the files, then switches the library folder. If anything fails before the switch, the original is untouched.
    public static func execute(_ plan: MovePlan, progress: (Double) -> Void = { _ in }) throws {
        let fm = FileManager.default
        switch plan.direction {
        case .toExternal:
            try fm.createDirectory(at: plan.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                if sameVolume(plan.from, plan.to.deletingLastPathComponent()) {
                    try fm.moveItem(at: plan.from, to: plan.to)
                    try fm.createSymbolicLink(at: plan.libraryFolder, withDestinationURL: plan.to)
                    progress(1)
                    return
                }
                try copyTree(from: plan.from, to: plan.to, bytes: plan.bytes, progress: progress)
                guard Uninstaller.size(of: plan.to) == plan.bytes else { throw MoveError.verificationFailed }
            } catch {
                try? fm.removeItem(at: plan.to)
                throw error
            }
            let aside = plan.libraryFolder.deletingLastPathComponent().appendingPathComponent(plan.libraryFolder.lastPathComponent + ".stirred-old")
            try fm.moveItem(at: plan.libraryFolder, to: aside)
            do { try fm.createSymbolicLink(at: plan.libraryFolder, withDestinationURL: plan.to) } catch {
                try? fm.moveItem(at: aside, to: plan.libraryFolder)
                try? fm.removeItem(at: plan.to)
                throw error
            }
            try? fm.removeItem(at: aside)
        case .backToThisMac:
            do {
                if sameVolume(plan.from, plan.to) {
                    try fm.moveItem(at: plan.from, to: plan.to)
                } else {
                    try copyTree(from: plan.from, to: plan.to, bytes: plan.bytes, progress: progress)
                    guard Uninstaller.size(of: plan.to) == plan.bytes else { throw MoveError.verificationFailed }
                }
            } catch {
                try? fm.removeItem(at: plan.to)
                throw error
            }
            try fm.removeItem(at: plan.libraryFolder)          // the link only
            try fm.moveItem(at: plan.to, to: plan.libraryFolder)
            try? fm.removeItem(at: plan.from)                  // the copy on the other disk
            let parent = plan.from.deletingLastPathComponent()
            if parent.lastPathComponent == "Stirred Games", ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).isEmpty {
                try? fm.removeItem(at: parent)
            }
            progress(1)
        }
    }
}

// MARK: - Launcher glue

public struct DiskReport: Sendable {
    public var space: DiskSpace?
    public var gamesOnThisMac: Int64
    public var gamesOnOtherDisks: Int64
    public var engine: Int64
    public var reclaimable: [Reclaimable]
}

extension Launcher {
    public func storageLocation(of game: Game) -> StorageLocation { GameMover.location(of: game) }

    public func diskReport() -> DiskReport {
        let games = (try? installedGames()) ?? []
        var here: Int64 = 0, away: Int64 = 0
        for game in games {
            let size = game.sizeOnDisk ?? 0
            if case .thisMac = GameMover.location(of: game) { here += size } else { away += size }
        }
        return DiskReport(space: DiskSpace.of(paths.root), gamesOnThisMac: here, gamesOnOtherDisks: away,
                          engine: Uninstaller.size(of: paths.engines) + Uninstaller.size(of: paths.components),
                          reclaimable: DiskCleaner.reclaimables(paths: paths, steamRoot: try? steam().steamRoot))
    }

    public func movePlan(for game: Game, to destination: URL) throws -> MovePlan {
        try GameMover.plan(for: game, to: destination, steamRoot: try steam().steamRoot)
    }

    public func movePlanBack(for game: Game) throws -> MovePlan {
        try GameMover.planBack(for: game, steamRoot: try steam().steamRoot)
    }

    /// Closes Steam first (it must not touch the files meanwhile); it starts again by itself at the next Play.
    public func move(_ plan: MovePlan, onPhase: @Sendable (String) -> Void = { _ in }, progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        if SystemSampler.sample(processNeedle: processNeedle(for: plan.game), at: 0).processCount > 0 { throw MoveError.gameRunning }
        if steamState() != .stopped {
            onPhase("Closing Steam…")
            await quitSteam(graceful: true)
        }
        onPhase("Moving…")
        try await Task.detached { try GameMover.execute(plan, progress: progress) }.value
    }
}
