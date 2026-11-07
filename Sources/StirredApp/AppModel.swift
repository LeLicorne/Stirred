import SwiftUI
import StirredCore

struct SessionSummary: Identifiable, Hashable {
    var id: String { url.lastPathComponent }
    let url: URL
    let title: String
    let startedAt: Date
    let crashed: Bool
    let sampleCount: Int
}

@MainActor @Observable
final class AppModel {
    let launcher = Launcher()

    var games: [Game] = []
    var steam: SteamState = .stopped
    var engineName: String?
    var warnings: [String] = []
    var message: String?
    var phases: [String: String] = [:]          // game id -> "Starting Steam…" / "Playing"
    var latency: [String: LatencyProfile] = [:]  // user's choice per game id
    var showHUD = false
    var sessions: [SessionSummary] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { while true { await refresh(); try? await Task.sleep(nanoseconds: 3_000_000_000) } }
    }

    func refresh() async {
        let launcher = self.launcher
        let snapshot = await Task.detached { () -> (Engine?, [Game], SteamState, [SessionSummary]) in
            let engine = try? launcher.engine()
            let games = (try? launcher.installedGames()) ?? []
            let steam = engine == nil ? SteamState.stopped : launcher.steamState()
            let sessions = launcher.sessionDirectories().prefix(40).compactMap { dir -> SessionSummary? in
                guard let r = try? SessionRecorder.load(dir) else { return nil }
                let crashed = (try? String(contentsOf: dir.appendingPathComponent("report.md"), encoding: .utf8))?
                    .contains("Crash detected | YES") ?? false
                return SessionSummary(url: dir, title: r.record.gameName, startedAt: r.record.startedAt,
                                      crashed: crashed, sampleCount: r.record.samples.count)
            }
            return (engine, games, steam, Array(sessions))
        }.value
        engineName = snapshot.0?.name
        games = snapshot.1
        steam = snapshot.2
        sessions = snapshot.3
        warnings = PowerAdvice.warnings(for: .current)
    }

    func recipe(for game: Game) -> Recipe? { launcher.recipe(for: game) }

    func selectedLatency(for game: Game) -> LatencyProfile {
        latency[game.id] ?? recipe(for: game)?.latency ?? .low
    }

    func play(_ game: Game) {
        guard phases[game.id] == nil else { return }
        message = nil
        phases[game.id] = "Preparing…"
        let options = LaunchOptions(latency: selectedLatency(for: game), hud: showHUD)
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                var recorder = try await launcher.play(game, options: options) { phase in
                    Task { @MainActor in self?.phases[game.id] = phase }
                }
                await MainActor.run { self?.phases[game.id] = "Playing" }
                await recorder.watch(maxSeconds: 8 * 3600)
                try launcher.finish(&recorder)
            } catch {
                await MainActor.run { self?.message = "\(error)" }
            }
            await MainActor.run { self?.phases[game.id] = nil }
            await self?.refresh()
        }
    }

    func stop(_ game: Game) {
        let launcher = self.launcher
        Task.detached { launcher.stopGame(game) }
    }

    func startSteam() {
        Task.detached { [launcher] in try? launcher.startSteam(silent: false) }
    }

    func openSteamWindow() {
        let launcher = self.launcher
        Task.detached {
            if launcher.steamState() == .stopped { try? launcher.startSteam(silent: false) }
            else { try? launcher.openSteamWindow() }
        }
    }

    func quitSteam() {
        let launcher = self.launcher
        Task { await launcher.quitSteam(); await refresh() }
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([launcher.paths.logs])
    }
}
