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
    var setupItems: [SetupItem] = []
    var setupComplete: Bool?                      // nil until the first check
    var setupBusy = false
    var setupMessage: String?
    var setupError: String?
    /// Set when the user opened Steam by hand: then Stirred never closes it for them.
    private var userOpenedSteam = false
    /// The uninstall waiting for the user's confirmation.
    var pendingUninstall: UninstallPlan?
    private var started = false

    /// Settings key shared with the toggle in the Library toolbar. Default: close Steam after playing.
    var closeSteamAfterPlaying: Bool { UserDefaults.standard.object(forKey: "closeSteamAfterPlaying") as? Bool ?? true }

    func start() {
        guard !started else { return }
        started = true
        Task { while true { await refresh(); try? await Task.sleep(nanoseconds: 3_000_000_000) } }
    }

    func refresh() async {
        let launcher = self.launcher
        let snapshot = await Task.detached { () -> (Engine?, [Game], SteamState, [SessionSummary], [SetupItem]) in
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
            return (engine, games, steam, Array(sessions), launcher.setup.items())
        }.value
        engineName = snapshot.0?.name
        games = snapshot.1
        steam = snapshot.2
        if snapshot.2 == .stopped { userOpenedSteam = false }
        sessions = snapshot.3
        setupItems = snapshot.4
        setupComplete = snapshot.4.allSatisfy(\.done)
        warnings = PowerAdvice.warnings(for: .current)
    }

    /// First-run installation (Wine, DXVK, Windows environment, Steam). Runs in the background.
    func runSetup() {
        guard !setupBusy else { return }
        setupBusy = true
        setupError = nil
        setupMessage = "Starting…"
        let manager = launcher.setup
        Task.detached { [weak self] in
            do {
                try await manager.run { message in Task { @MainActor in self?.setupMessage = message } }
            } catch {
                await MainActor.run { self?.setupError = "\(error)" }
            }
            await MainActor.run { self?.setupBusy = false; self?.setupMessage = nil }
            await self?.refresh()
        }
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
                let (keep, others) = await MainActor.run { () -> (Bool, Bool) in
                    guard let self else { return (true, true) }
                    let others = self.phases.contains { $0.key != game.id && $0.value == "Playing" }
                    return (self.userOpenedSteam || !self.closeSteamAfterPlaying, others)
                }
                await launcher.cleanUpAfterGame(game, startedSteam: recorder.record.startedSteam ?? false,
                                                keepSteam: keep, otherGamesRunning: others)
            } catch {
                await MainActor.run { self?.message = "\(error)" }
            }
            await MainActor.run { self?.phases[game.id] = nil }
            await self?.refresh()
        }
    }

    /// Step 1: work out what would be deleted, then let the user confirm.
    func askUninstall(_ game: Game) {
        guard phases[game.id] == nil else { return }
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                let plan = try launcher.uninstallPlan(for: game)
                await MainActor.run { self?.pendingUninstall = plan }
            } catch {
                await MainActor.run { self?.message = "\(error)" }
            }
        }
    }

    /// Step 2: the user confirmed.
    func confirmUninstall(_ plan: UninstallPlan) {
        let game = plan.game
        guard phases[game.id] == nil else { return }
        pendingUninstall = nil
        message = nil
        phases[game.id] = "Uninstalling…"
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                try await launcher.uninstall(game) { phase in Task { @MainActor in self?.phases[game.id] = phase } }
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
        userOpenedSteam = true
        Task.detached { [launcher] in try? launcher.startSteam(silent: false) }
    }

    func openSteamWindow() {
        userOpenedSteam = true
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
