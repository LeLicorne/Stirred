import Foundation
import CryptoKit

public enum SetupStep: String, CaseIterable, Sendable, Identifiable {
    case rosetta, engine, graphics, prefix, steam, steamFirstRun
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rosetta: "Rosetta 2"
        case .engine: "Wine engine"
        case .graphics: "Graphics layer (DXVK)"
        case .prefix: "Windows environment"
        case .steam: "Steam (Windows version)"
        case .steamFirstRun: "Steam first start"
        }
    }

    public var summary: String {
        switch self {
        case .rosetta: "Lets your Mac run Windows (x86) code. Installed by macOS."
        case .engine: "Wine, the layer that runs Windows programs (about 220 MB)."
        case .graphics: "Translates DirectX games to your GPU (about 20 MB)."
        case .prefix: "A private fake Windows folder where Steam and your games live."
        case .steam: "The official Steam client for Windows, from Valve."
        case .steamFirstRun: "Steam updates itself once and gets its display fix."
        }
    }
}

public struct SetupItem: Sendable, Identifiable, Equatable {
    public let step: SetupStep
    public let done: Bool
    public var id: String { step.rawValue }
}

/// Where everything is downloaded from. GitHub archives are pinned by SHA-256.
public struct SetupSources: Sendable {
    public var wineURL: URL
    public var wineSHA256: String
    public var engineName: String
    public var dxvkURL: URL
    public var dxvkSHA256: String
    public var dxvkInnerDirectory: String
    public var steamSetupURL: URL

    public static let standard = SetupSources(
        wineURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-staging-11.21-osx64.tar.xz")!,
        wineSHA256: "d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452",
        engineName: "stirred-wine-11.21",
        dxvkURL: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507/dxvk-macOS-async-v1.10.3-20230507.tar.gz")!,
        dxvkSHA256: "f67d99d0a8eeedd7d406b283a3df9f939b5965acb00efcb33d0c6235c195a516",
        dxvkInnerDirectory: "dxvk-macOS-async-v1.10.3-20230507",
        steamSetupURL: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!)
}

public enum SetupError: Error, CustomStringConvertible, Sendable {
    case rosettaMissing
    case checksumMismatch(String)
    case httpStatus(Int)
    case commandFailed(String)
    case incomplete(String)

    public var description: String {
        switch self {
        case .rosettaMissing:
            "Rosetta 2 is not installed. Open Terminal and run: softwareupdate --install-rosetta --agree-to-license"
        case .checksumMismatch(let name): "The downloaded file \(name) does not match its expected checksum. Nothing was installed."
        case .httpStatus(let code): "The download failed (HTTP \(code))."
        case .commandFailed(let what): "\(what) failed."
        case .incomplete(let what): what
        }
    }
}

/// First-run installation, step by step, each step skipped when already done (safe to run again).
public struct SetupManager: Sendable {
    public let paths: StirredPaths
    public let wrapper: URL?
    public let sources: SetupSources

    public init(paths: StirredPaths = StirredPaths(), wrapper: URL?, sources: SetupSources = .standard) {
        self.paths = paths; self.wrapper = wrapper; self.sources = sources
    }

    private var launcher: Launcher { Launcher(paths: paths) }
    private var prefix: URL { paths.prefix(named: "steam") }
    private var steamRoot: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true) }

    public func items() -> [SetupItem] {
        SetupStep.allCases.map { SetupItem(step: $0, done: isDone($0)) }
    }

    public var isComplete: Bool { items().allSatisfy(\.done) }

    func isDone(_ step: SetupStep) -> Bool {
        let fm = FileManager.default
        switch step {
        case .rosetta: return fm.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
        case .engine: return EngineLocator.preferred(paths: paths) != nil
        case .graphics: return fm.fileExists(atPath: paths.components.appendingPathComponent("dxvk-macos-1.10.3/x64/d3d11.dll").path)
        case .prefix: return fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
        case .steam: return fm.fileExists(atPath: steamRoot.appendingPathComponent("Steam.exe").path)
        case .steamFirstRun: return WebHelperWrapper.isInstalled(steamRoot: steamRoot)
        }
    }

    /// Does every missing step. `onProgress` receives short human-readable messages.
    public func run(onProgress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        for directory in [paths.downloads, paths.engines, paths.components, paths.prefixes, paths.logs] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for item in items() where !item.done {
            onProgress("\(item.step.title)…")
            switch item.step {
            case .rosetta: throw SetupError.rosettaMissing
            case .engine: try await installEngine(onProgress)
            case .graphics: try await installGraphics(onProgress)
            case .prefix: try await createPrefix(onProgress)
            case .steam: try await installSteam(onProgress)
            case .steamFirstRun: try await firstSteamStart(onProgress)
            }
        }
        onProgress("Done")
    }

    // MARK: Steps

    private func installEngine(_ progress: @escaping @Sendable (String) -> Void) async throws {
        try await installEngine(EngineRelease(name: sources.engineName, version: "11.21", url: sources.wineURL, sha256: sources.wineSHA256,
                                              archiveName: "wine-staging-11.21-osx64.tar.xz"), progress)
    }

    /// Downloads (checksum-verified), unpacks and puts an engine in `engines/<name>`. Does not make it the active one.
    func installEngine(_ release: EngineRelease, _ progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: paths.downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.engines, withIntermediateDirectories: true)
        let archive = try await downloadVerified(
            release.url, name: release.archiveName, sha256: release.sha256, label: "Wine", progress)
        progress("Unpacking Wine (about a minute)…")
        let fm = FileManager.default
        let tmp = paths.engines.appendingPathComponent("_installing", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Self.runChecked("/usr/bin/tar", ["-xf", archive.path, "-C", tmp.path], what: "Unpacking Wine")
        _ = SystemSampler.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", tmp.path])
        let target = paths.engines.appendingPathComponent(release.name, isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
        guard Engine(directory: target).wineBinary != nil else {
            throw SetupError.incomplete("The Wine archive did not contain the expected files.")
        }
    }

    private func installGraphics(_ progress: @escaping @Sendable (String) -> Void) async throws {
        let archive = try await downloadVerified(
            sources.dxvkURL, name: "dxvk-macOS-async-v1.10.3-20230507.tar.gz", sha256: sources.dxvkSHA256, label: "DXVK", progress)
        let fm = FileManager.default
        let tmp = paths.components.appendingPathComponent("_installing", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Self.runChecked("/usr/bin/tar", ["-xzf", archive.path, "-C", tmp.path], what: "Unpacking DXVK")
        let target = paths.components.appendingPathComponent("dxvk-macos-1.10.3", isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp.appendingPathComponent(sources.dxvkInnerDirectory), to: target)
        try? fm.removeItem(at: tmp)
    }

    private func createPrefix(_ progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Creating the Windows environment (about 30 s)…")
        try await launcher.runner().initialisePrefix(logFile: paths.logs.appendingPathComponent("wineboot.log"))
        guard isDone(.prefix) else { throw SetupError.commandFailed("Creating the Windows environment") }
    }

    private func installSteam(_ progress: @escaping @Sendable (String) -> Void) async throws {
        let installer = try await downloadVerified(
            sources.steamSetupURL, name: "SteamSetup.exe", sha256: nil, label: "Steam", progress)
        progress("Installing Steam (about a minute)…")
        _ = try await launcher.runner().runAndWait(
            arguments: [installer.path, "/S"], logFile: paths.logs.appendingPathComponent("steam-install.log"))
        guard isDone(.steam) else { throw SetupError.commandFailed("Installing Steam") }
    }

    /// Steam updates itself on its first start (a few minutes) and only then has the Chromium helper we must wrap.
    private func firstSteamStart(_ progress: @escaping @Sendable (String) -> Void) async throws {
        guard let wrapper else { throw SetupError.incomplete("The Steam display fix is missing from this build of Stirred.") }
        let steam = try launcher.steam()
        progress("Starting Steam: it updates itself, this takes a few minutes…")
        _ = try steam.launchClient(silent: false, firstRun: true)
        let helper = WebHelperWrapper.cefDirectory(steamRoot: steam.steamRoot).appendingPathComponent("steamwebhelper.exe")
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: helper.path)[.size]) as? Int ?? 0
            if size > WebHelperWrapper.sizeCeiling { break }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)   // let Steam finish writing its files
        guard try WebHelperWrapper.ensure(steamRoot: steam.steamRoot, wrapper: wrapper) || isDone(.steamFirstRun) else {
            throw SetupError.incomplete("Steam did not finish its first update. Run setup again.")
        }
        // Steam restarts its helper by itself: the new one is our wrapper.
        _ = SystemSampler.run("/usr/bin/pkill", ["-f", "steamwebhelper.exe"])
        try await Task.sleep(nanoseconds: 4_000_000_000)
    }

    // MARK: Helpers

    func downloadVerified(
        _ url: URL, name: String, sha256: String?, label: String, _ progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let destination = paths.downloads.appendingPathComponent(name)
        if let sha256, FileManager.default.fileExists(atPath: destination.path),
           (try? Self.sha256Hex(of: destination)) == sha256 { return destination }   // cached and intact
        let last = Counter()
        try await DownloadTask(destination: destination) { written, expected in
            guard expected > 0 else { return }
            let percent = Int(written * 100 / expected)
            if last.update(percent) { progress("Downloading \(label)… \(percent)%") }
        }.run(url: url)
        if let sha256, try Self.sha256Hex(of: destination) != sha256 {
            try? FileManager.default.removeItem(at: destination)
            throw SetupError.checksumMismatch(name)
        }
        return destination
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4_194_304), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func runChecked(_ path: String, _ arguments: [String], what: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SetupError.commandFailed(what) }
    }
}

/// Reports a value only when it changes (progress callbacks fire thousands of times).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func update(_ new: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard new != value else { return false }
        value = new
        return true
    }
}

/// One file download with progress.
final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); self.continuation = continuation; lock.unlock()
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            finish(SetupError.httpStatus(status)); return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch { finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
}
