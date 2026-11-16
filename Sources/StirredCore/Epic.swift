import Foundation

/// A game of the Epic library, as Legendary lists it.
public struct EpicGame: Sendable, Equatable, Identifiable, Codable {
    public var appName: String
    public var title: String
    public var developer: String?
    /// Landscape picture from the store's own metadata.
    public var cover: URL?
    /// Set when the game is only distributed through another launcher (EA App "Origin", Ubisoft "Uplay"...).
    public var thirdPartyStore: String?
    public var id: String { appName }
}

public struct EpicInstalledGame: Sendable, Equatable {
    public var appName: String
    public var title: String
    public var installPath: String
    public var executable: String
    public var installSize: Int64?
    public var platform: String?
}

/// Everything Legendary says is needed to start a game (`legendary launch <app> --json`).
public struct EpicLaunchInfo: Sendable, Equatable {
    public var gameDirectory: String
    public var gameExecutable: String
    public var workingDirectory: String?
    public var gameParameters: [String]
    public var eglParameters: [String]
    public var userParameters: [String]
    public var environment: [String: String]
}

public enum EpicError: Error, CustomStringConvertible, Sendable {
    case toolMissing, notSignedIn, failed(String), unreadable(String)
    public var description: String {
        switch self {
        case .toolMissing: "Epic support is not set up yet (Stores section)."
        case .notSignedIn: "You are not signed in to Epic (Stores section)."
        case .failed(let why): "Epic: \(why)"
        case .unreadable(let what): "Could not read \(what) from the Epic tool."
        }
    }
}

/// Pure parsers for Legendary's JSON (tolerant: a missing field never crashes).
public enum EpicParsing {
    static func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// `legendary status --json` -> account name, nil when signed out.
    public static func account(statusJSON: Data) -> String? {
        guard let dict = object(statusJSON) as? [String: Any], let account = dict["account"] as? String,
              !account.isEmpty, !account.hasPrefix("<") else { return nil }
        return account
    }

    /// `legendary list --json`
    public static func library(_ data: Data) -> [EpicGame] {
        guard let list = object(data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> EpicGame? in
            guard let appName = entry["app_name"] as? String else { return nil }
            let metadata = entry["metadata"] as? [String: Any] ?? [:]
            let title = (entry["app_title"] as? String) ?? (metadata["title"] as? String) ?? appName
            let images = metadata["keyImages"] as? [[String: Any]] ?? []
            func image(_ types: [String]) -> URL? {
                for type in types {
                    if let url = images.first(where: { $0["type"] as? String == type })?["url"] as? String { return URL(string: url) }
                }
                return nil
            }
            let attributes = metadata["customAttributes"] as? [String: Any] ?? [:]
            let third = (attributes["ThirdPartyManagedApp"] as? [String: Any])?["value"] as? String
            return EpicGame(appName: appName, title: title, developer: metadata["developer"] as? String,
                            cover: image(["DieselGameBox", "OfferImageWide", "DieselStoreFrontWide", "Thumbnail", "DieselGameBoxTall"]),
                            thirdPartyStore: (third?.isEmpty ?? true) ? nil : third)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Legendary's `installed.json` (a dictionary keyed by app name), read directly: no process to start at every refresh.
    public static func installed(_ data: Data) -> [EpicInstalledGame] {
        guard let dict = object(data) as? [String: Any] else { return [] }
        return dict.compactMap { key, value -> EpicInstalledGame? in
            guard let entry = value as? [String: Any], let path = entry["install_path"] as? String,
                  entry["is_dlc"] as? Bool != true else { return nil }
            return EpicInstalledGame(
                appName: (entry["app_name"] as? String) ?? key, title: (entry["title"] as? String) ?? key, installPath: path,
                executable: (entry["executable"] as? String) ?? "", installSize: (entry["install_size"] as? NSNumber)?.int64Value,
                platform: entry["platform"] as? String)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// `legendary launch <app> --json`
    public static func launchInfo(_ data: Data) -> EpicLaunchInfo? {
        guard let dict = object(data) as? [String: Any], let directory = dict["game_directory"] as? String,
              let executable = dict["game_executable"] as? String, !executable.isEmpty else { return nil }
        func strings(_ key: String) -> [String] { (dict[key] as? [Any] ?? []).compactMap { $0 as? String } }
        var environment: [String: String] = [:]
        for (key, value) in dict["environment"] as? [String: Any] ?? [:] { if let text = value as? String { environment[key] = text } }
        return EpicLaunchInfo(
            gameDirectory: directory, gameExecutable: executable,
            workingDirectory: (dict["working_directory"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            gameParameters: strings("game_parameters"), eglParameters: strings("egl_parameters"), userParameters: strings("user_parameters"),
            environment: environment)
    }

    /// "[DLManager] INFO: = Progress: 12.34% (5/40), Running for 00:00:10, ETA: 00:01:00" -> 0.1234
    public static func progress(line: String) -> Double? {
        guard let range = line.range(of: #"Progress: ([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression) else { return nil }
        let number = line[range].dropFirst("Progress: ".count).dropLast()
        return Double(number).map { min(1, max(0, $0 / 100)) }
    }

    /// The code Epic's sign-in page shows: accepts the bare code or the whole JSON the page displays (`"authorizationCode":"…"`).
    public static func authorizationCode(from pasted: String) -> String? {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8), let dict = object(data) as? [String: Any], let code = dict["authorizationCode"] as? String {
            return code.isEmpty ? nil : code
        }
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard !bare.isEmpty, bare.count <= 128, bare.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return nil }
        return bare
    }
}

/// What to run for an Epic game: the game's own executable with the sign-in parameters Legendary produced, plus Stirred's plan.
public struct EpicLaunchCommand: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL

    public static func make(info: EpicLaunchInfo, plan: LaunchPlan) -> EpicLaunchCommand {
        let directory = URL(fileURLWithPath: info.gameDirectory, isDirectory: true)
        let executable = directory.appendingPathComponent(info.gameExecutable.replacingOccurrences(of: "\\", with: "/"))
        var arguments = info.gameParameters + info.eglParameters + info.userParameters
        for argument in plan.gameArguments where !arguments.contains(argument) { arguments.append(argument) }
        let working = info.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? executable.deletingLastPathComponent()
        return EpicLaunchCommand(executable: executable, arguments: arguments,
                                 environment: info.environment.merging(plan.environment) { _, ours in ours }, workingDirectory: working)
    }
}

/// Runs Legendary with its settings kept inside Stirred's own folder (`tools/legendary-config`), away from any other install.
/// The sign-in token is written there by Legendary itself; Stirred never reads it.
public struct LegendaryCLI: Sendable {
    public let binary: URL
    public let configDirectory: URL

    public init(paths: StirredPaths, tool: StoreTool = .legendary) {
        binary = tool.binary(paths)
        configDirectory = paths.root.appendingPathComponent("tools/legendary-config", isDirectory: true)
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LEGENDARY_CONFIG_PATH"] = configDirectory.path
        process.environment = environment
        return process
    }

    /// Runs to the end. Returns the exit status, what it printed and its messages.
    public func run(_ arguments: [String]) throws -> (status: Int32, output: Data, messages: String) {
        guard isInstalled else { throw EpicError.toolMissing }
        let process = makeProcess(arguments)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        // Read both pipes while it runs, or a long output would block it.
        let box = DataBox()
        let reader = Thread { box.value = err.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while !reader.isFinished { usleep(10_000) }
        return (process.terminationStatus, data, String(decoding: box.value, as: UTF8.self))
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return data }
        set { lock.lock(); data = newValue; lock.unlock() }
    }
}

public struct EpicProvider: GameStoreProvider {
    public let cli: LegendaryCLI
    public let runner: WineRunner?
    public let paths: StirredPaths

    public init(paths: StirredPaths, runner: WineRunner?) {
        self.paths = paths; self.runner = runner; cli = LegendaryCLI(paths: paths)
    }

    public var storeName: String { "epic" }
    public var isInstalled: Bool { cli.isInstalled }
    /// Legendary writes `user.json` when signed in and deletes it on sign-out.
    public var isSignedIn: Bool { FileManager.default.fileExists(atPath: cli.configDirectory.appendingPathComponent("user.json").path) }

    /// Where Epic games are installed: inside the shared Windows environment, so their paths are valid Windows paths.
    public var gamesDirectory: URL {
        paths.prefix(named: Stores.prefixName(forStore: storeName)).appendingPathComponent("drive_c/Games/Epic", isDirectory: true)
    }

    var libraryCache: URL { paths.root.appendingPathComponent("cache/epic-library.json") }

    public func installedRecords() -> [EpicInstalledGame] {
        guard let data = try? Data(contentsOf: cli.configDirectory.appendingPathComponent("installed.json")) else { return [] }
        return EpicParsing.installed(data).filter { ($0.platform ?? "Windows") == "Windows" && FileManager.default.fileExists(atPath: $0.installPath) }
    }

    public func installedGames() throws -> [Game] {
        installedRecords().map {
            Game(store: storeName, storeID: $0.appName, name: $0.title, installDirectory: URL(fileURLWithPath: $0.installPath, isDirectory: true),
                 sizeOnDisk: $0.installSize, executable: $0.executable.isEmpty ? nil : $0.executable)
        }
    }

    public func account() -> String? {
        guard isSignedIn, let result = try? cli.run(["status", "--offline", "--json"]) else { return nil }
        return EpicParsing.account(statusJSON: result.output)
    }

    /// `code` is the authorization code Epic's own sign-in page shows after you signed in there. Never a password.
    public func signIn(code: String) throws {
        let result = try cli.run(["auth", "--code", code])
        guard result.status == 0, isSignedIn else { throw EpicError.failed(Self.lastMessage(result.messages) ?? "sign-in was refused") }
    }

    public func signOut() throws {
        _ = try cli.run(["auth", "--delete"])
        try? FileManager.default.removeItem(at: libraryCache)
    }

    /// The Windows games you own. `refresh` asks Epic; otherwise the copy kept on disk is used.
    public func library(refresh: Bool) throws -> [EpicGame] {
        if !refresh, let data = try? Data(contentsOf: libraryCache), let cached = try? JSONDecoder().decode([EpicGame].self, from: data) { return cached }
        guard isSignedIn else { throw EpicError.notSignedIn }
        let result = try cli.run(["list", "--platform", "Windows", "--third-party", "--json"])
        guard result.status == 0 else { throw EpicError.failed(Self.lastMessage(result.messages) ?? "could not list your games") }
        let games = EpicParsing.library(result.output)
        try? FileManager.default.createDirectory(at: libraryCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(games).write(to: libraryCache)
        return games
    }

    /// Downloads and installs the Windows version. `progress` gets 0...1.
    public func install(appName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard isSignedIn else { throw EpicError.notSignedIn }
        try FileManager.default.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
        let process = cli.makeProcess(["-y", "install", appName, "--platform", "Windows", "--base-path", gamesDirectory.path, "--skip-sdl"])
        let pipe = Pipe()
        process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
        let tail = DataBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) { if let value = EpicParsing.progress(line: String(line)) { progress(value) } }
            tail.value = Data((String(decoding: tail.value, as: UTF8.self) + text).suffix(2000).utf8)
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard status == 0 else { throw EpicError.failed(Self.lastMessage(String(decoding: tail.value, as: UTF8.self)) ?? "the install stopped (status \(status))") }
    }

    public func uninstall(appName: String) throws {
        let result = try cli.run(["-y", "uninstall", appName, "--skip-uninstaller"])
        guard result.status == 0 else { throw EpicError.failed(Self.lastMessage(result.messages) ?? "could not uninstall") }
    }

    public func launchInfo(appName: String) throws -> EpicLaunchInfo {
        var result = try cli.run(["launch", appName, "--json", "--no-wine"])
        if result.status != 0 { result = try cli.run(["launch", appName, "--json", "--no-wine", "--offline"]) }   // no network: games that allow it
        guard result.status == 0 else { throw EpicError.failed(Self.lastMessage(result.messages) ?? "could not prepare the launch") }
        guard let info = EpicParsing.launchInfo(result.output) else { throw EpicError.unreadable("the launch details") }
        return info
    }

    public func launch(_ game: Game, plan: LaunchPlan) throws -> Process {
        guard let runner else { throw StirredError.engineNotFound }
        if let reason = plan.blockedReason { throw StirredError.blocked(reason) }
        let command = EpicLaunchCommand.make(info: try launchInfo(appName: game.storeID), plan: plan)
        var environment = command.environment
        environment["DXVK_LOG_PATH"] = paths.logs.appendingPathComponent("dxvk", isDirectory: true).path
        environment["DXVK_LOG_LEVEL"] = "info"
        let process = try runner.makeProcess(
            arguments: [command.executable.path] + command.arguments, extraEnvironment: environment,
            workingDirectory: command.workingDirectory, logFile: paths.logs.appendingPathComponent("game-epic-\(game.key.id).log"))
        try process.run()
        return process
    }

    /// Legendary's last meaningful message, without its log prefix ("[cli] ERROR: ...").
    static func lastMessage(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = lines.last(where: { $0.contains("ERROR") || $0.contains("CRITICAL") }) ?? lines.last else { return nil }
        return line.replacingOccurrences(of: #"^\[[^\]]*\]\s*[A-Z]+:\s*"#, with: "", options: .regularExpression)
    }
}
