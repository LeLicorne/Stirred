import Foundation

public enum StirredError: Error, CustomStringConvertible, Sendable {
    case engineNotFound
    case prefixMissing(URL)
    case steamNotInstalled
    case blocked(String)

    public var description: String {
        switch self {
        case .engineNotFound: "No Wine engine found. Expected a directory named stirred-* in the engines folder."
        case .prefixMissing(let url): "Wine prefix not initialised at \(url.path)."
        case .steamNotInstalled: "Steam is not installed in the prefix."
        case .blocked(let reason): "Launch blocked: \(reason)"
        }
    }
}

/// Builds and runs Wine processes for one engine + one prefix.
public struct WineRunner: Sendable {
    public let wine: URL
    public let prefix: URL

    public init(engine: Engine, prefix: URL) throws {
        guard let wine = engine.wineBinary else { throw StirredError.engineNotFound }
        self.wine = wine
        self.prefix = prefix
    }

    public var isPrefixInitialised: Bool {
        FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
    }

    /// Process environment: inherited env + our defaults + caller overrides (caller wins).
    public func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Creates (but does not start) a process running `wine <arguments>`.
    public func makeProcess(
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        workingDirectory: URL? = nil,
        logFile: URL? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = wine
        process.arguments = arguments
        process.environment = environment(extra: extraEnvironment)
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let logFile {
            try FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: logFile)
            process.standardOutput = handle
            process.standardError = handle
        }
        return process
    }

    /// Runs to completion and returns the exit status.
    public func runAndWait(
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        workingDirectory: URL? = nil,
        logFile: URL? = nil
    ) async throws -> Int32 {
        let process = try makeProcess(
            arguments: arguments, extraEnvironment: extraEnvironment,
            workingDirectory: workingDirectory, logFile: logFile)
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Creates the prefix (`wineboot -u`). Safe to call on an existing prefix.
    public func initialisePrefix(logFile: URL? = nil) async throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        _ = try await runAndWait(arguments: ["wineboot", "-u"], logFile: logFile)
    }
}
