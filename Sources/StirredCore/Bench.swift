import Foundation

/// What an unattended run of a game showed. It can tell "starts and keeps running" from "never starts" or "closes at once";
/// it cannot tell whether the picture is right: that still needs a human look, so a bench never marks a recipe verified.
public enum BenchOutcome: String, Codable, Sendable {
    case runs            // the process appeared and was still alive when the bench stopped it
    case exitedEarly     // it appeared, then ended by itself before the time was up
    case neverStarted    // the process never appeared
    case blocked         // Stirred refused to start it (recipe says unsupported, engine missing...)
    case failed          // starting it raised an error
}

public struct BenchResult: Codable, Sendable, Equatable {
    public var game: String
    public var key: String
    public var outcome: BenchOutcome
    public var backend: String?
    public var secondsAlive: Int
    public var averageCPU: Double?
    public var peakMemoryMB: Int?
    /// Ids of the diagnosis rules that fired on the logs of this run (`needs-dxmt`, `unity-vulkan`...).
    public var findings: [String]
    public var note: String?
}

public enum Bench {
    /// Pure verdict from what the sampler recorded.
    public static func outcome(neverDetected: Bool, samples: [SessionSample], requestedSeconds: Int) -> BenchOutcome {
        if neverDetected || samples.isEmpty { return .neverStarted }
        // The sampler takes one sample every 3 s; a game stopped by the bench lived (almost) the whole time.
        let alive = Int(samples.last?.t ?? 0)
        return alive >= max(1, requestedSeconds - 9) ? .runs : .exitedEarly
    }

    public static func summarize(game: Game, record: SessionRecord, requestedSeconds: Int, findings: [String]) -> BenchResult {
        let samples = record.samples
        let cpu = samples.isEmpty ? nil : samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
        return BenchResult(
            game: game.name, key: game.key.description,
            outcome: outcome(neverDetected: record.neverDetected ?? false, samples: samples, requestedSeconds: requestedSeconds),
            backend: record.backend, secondsAlive: Int(samples.last?.t ?? 0), averageCPU: cpu.map { ($0 * 10).rounded() / 10 },
            peakMemoryMB: samples.map(\.rssMB).max(), findings: findings, note: nil)
    }

    /// A Markdown table a human can read and paste.
    public static func report(_ results: [BenchResult], date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["# Stirred bench, \(formatter.string(from: date))", "",
                     "Unattended runs: \"runs\" means the game stayed alive, not that its picture is right.", "",
                     "| Game | Result | Graphics | Alive (s) | CPU % | Memory (MB) | Findings |", "|---|---|---|---|---|---|---|"]
        for r in results {
            lines.append("| \(r.game) | \(r.outcome.rawValue) | \(r.backend ?? "-") | \(r.secondsAlive) | \(r.averageCPU.map { String($0) } ?? "-") | \(r.peakMemoryMB.map(String.init) ?? "-") | \((r.findings + [r.note].compactMap { $0 }).joined(separator: "; ")) |")
        }
        let ok = results.filter { $0.outcome == .runs }.count
        lines += ["", "\(ok) of \(results.count) stayed alive."]
        return lines.joined(separator: "\n") + "\n"
    }
}

extension Launcher {
    /// Starts one game, watches it for `seconds`, stops it, and says what happened. Steam is left running between games.
    public func bench(_ game: Game, seconds: Int, onEvent: @Sendable (String) -> Void = { _ in }) async -> BenchResult {
        let plan = plan(for: game)
        if let reason = plan.blockedReason {
            return BenchResult(game: game.name, key: game.key.description, outcome: .blocked, backend: plan.backend.rawValue,
                               secondsAlive: 0, averageCPU: nil, peakMemoryMB: nil, findings: [], note: reason)
        }
        do {
            var recorder = try await play(game, onPhase: onEvent)
            await recorder.watch(maxSeconds: seconds, onEvent: onEvent)
            _ = try? finish(&recorder)
            _ = await stopGameEscalating(game)
            await cleanUpAfterGame(game, startedSteam: false, keepSteam: true, otherGamesRunning: false)
            let findings = diagnose(game).map(\.id).filter { $0 != "nothing" }
            return Bench.summarize(game: game, record: recorder.record, requestedSeconds: seconds, findings: findings)
        } catch {
            return BenchResult(game: game.name, key: game.key.description, outcome: .failed, backend: plan.backend.rawValue,
                               secondsAlive: 0, averageCPU: nil, peakMemoryMB: nil, findings: [], note: "\(error)")
        }
    }

    /// Where bench reports are kept.
    public var benchDirectory: URL { paths.logs.appendingPathComponent("bench", isDirectory: true) }
}
