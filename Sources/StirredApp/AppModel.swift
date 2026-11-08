import UniformTypeIdentifiers
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

/// Lets the background refinement see a "stop" request from the UI thread.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
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
    /// Bumped when a preset changes so cards redraw (presets are stored on disk).
    var presetRevision = 0
    var showHUD = false
    var sessions: [SessionSummary] = []
    var setupItems: [SetupItem] = []
    var setupComplete: Bool?                      // nil until the first check
    var setupBusy = false
    var setupMessage: String?
    var setupError: String?
    /// Set when the user opened Steam by hand: then Stirred never closes it for them.
    private var userOpenedSteam = false
    // Diagnosis sheet
    struct DiagnosisState {
        var game: Game
        var items: [Diagnosis]
        var done: Set<String> = []
        var busy: String?
        var phase: String?
        var error: String?
        var hasOverrides = false
    }
    var diagnosis: DiagnosisState?
    // "All my games"
    var allGames: [LibraryEntry] = []
    var allGamesError: String?
    var allGamesLoading = false
    var refining: (done: Int, total: Int)?
    private var ownedInfo: [AppInfoEntry] = []
    private let stopRefine = StopFlag()
    // "Check a game"
    var checkBusy = false
    var checkError: String?
    var checkResults: [StoreSearchResult] = []
    var checkResult: GameCheck?
    var installPhase: [Int: String] = [:]          // appID -> what Stirred is doing for the install
    /// After an install: close the Steam Stirred started once the download is over.
    private var installWatch: (startedSteam: Bool, sawDownload: Bool, since: Date)?
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
            if steam == .stopped { launcher.reapOrphans() }
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
        diskSpace = DiskSpace.of(launcher.paths.root)
        loadEngineStatus()
        if let watch = installWatch {
            if games.contains(where: { $0.downloadProgress != nil }) {
                installWatch?.sawDownload = true
            } else if (watch.sawDownload || Date().timeIntervalSince(watch.since) > 900) && phases.isEmpty && installPhase.isEmpty {
                installWatch = nil
                if watch.startedSteam && !userOpenedSteam && closeSteamAfterPlaying { quitSteam() }
            }
        }
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

    /// Copies the game's recipe (bundled or imported, plus personal settings) so it can be shared. Nothing is uploaded.
    func copyRecipe(_ game: Game) {
        do {
            let data = try launcher.exportRecipe(for: game, tested: false)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            message = "Recipe for \(game.name) copied. Paste it in a file or send it to someone; to add it to the project, open a pull request with it."
        } catch { message = "\(error)" }
    }

    /// Asks for a recipe file and imports it (checked first: only graphics settings, launch arguments and harmless variables).
    func importRecipeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose a Stirred recipe (.json). Imported recipes are never marked as verified."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try launcher.importRecipe(from: try Data(contentsOf: url))
            message = "\(result.replaced ? "Replaced" : "Imported") the recipe for \(result.recipe.name). It applies at the next launch."
            presetRevision += 1
        } catch { message = "\(error)" }
    }

    // MARK: Engine

    var engineStatus: EngineStatus?
    var engineBusy: String?
    var upstreamNote: String?

    func loadEngineStatus() { engineStatus = launcher.engineUpdater.status() }

    private func runEngine(_ work: @escaping @Sendable (Launcher, @escaping @Sendable (String) -> Void) async throws -> String) {
        guard engineBusy == nil, phases.values.allSatisfy({ $0 != "Playing" && $0 != "Updating" }) else {
            message = "Close your games first."; return
        }
        message = nil; engineBusy = "Starting…"
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                let done = try await work(launcher) { phase in Task { @MainActor in self?.engineBusy = phase } }
                await MainActor.run { self?.message = done }
            } catch { await MainActor.run { self?.message = "\(error)" } }
            await MainActor.run { self?.engineBusy = nil; self?.loadEngineStatus() }
            await self?.refresh()
        }
    }

    func updateEngine(_ release: EngineRelease) {
        runEngine { launcher, phase in
            try await launcher.engineUpdater.install(release.name, progress: phase)
            try await launcher.useEngine(release.name, onPhase: phase)
            return "Now using Wine \(release.version). You can go back from the Engine section."
        }
    }

    func rollbackEngine() {
        runEngine { launcher, phase in
            try await launcher.rollbackEngine(onPhase: phase)
            return "Went back to the previous engine."
        }
    }

    func removeEngine(_ name: String) {
        do { try launcher.engineUpdater.remove(name); loadEngineStatus() } catch { message = "\(error)" }
    }

    func checkUpstream() {
        upstreamNote = "Checking…"
        let active = engineStatus?.active.map { EngineVersion.version(ofEngineNamed: $0.name) } ?? "0"
        Task { [weak self] in
            let latest = await EngineUpdater.checkUpstream()
            await MainActor.run {
                guard let latest else { self?.upstreamNote = "Could not reach GitHub."; return }
                self?.upstreamNote = EngineVersion.isNewer(latest, than: active)
                    ? "Wine \(latest) exists upstream. Stirred has not tested it, so it is not offered yet."
                    : "You have the latest Wine build (\(latest))."
            }
        }
    }

    // MARK: Disk

    var diskSpace: DiskSpace?
    var diskReport: DiskReport?
    var diskBusy = false

    func loadDiskReport() {
        diskBusy = true
        let launcher = self.launcher
        Task.detached { [weak self] in
            let report = launcher.diskReport()
            await MainActor.run { self?.diskReport = report; self?.diskSpace = report.space; self?.diskBusy = false }
        }
    }

    func clean(_ item: Reclaimable) {
        diskBusy = true
        Task.detached { [weak self] in
            let freed = DiskCleaner.clean(item)
            await MainActor.run { self?.message = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))." }
            await self?.loadDiskReport()
        }
    }

    func location(of game: Game) -> StorageLocation { launcher.storageLocation(of: game) }

    /// Asks for a folder on another disk, then moves the game there (Steam is closed meanwhile).
    func moveToAnotherDisk(_ game: Game) {
        guard phases[game.id] == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = "Move here"
        panel.message = "Choose the disk or folder for \(game.name). Stirred creates a \"Stirred Games\" folder there. Steam is closed while the files move."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        runMove(game) { try $0.movePlan(for: game, to: folder) }
    }

    func moveBack(_ game: Game) { runMove(game) { try $0.movePlanBack(for: game) } }

    private func runMove(_ game: Game, plan makePlan: @escaping @Sendable (Launcher) throws -> MovePlan) {
        message = nil
        phases[game.id] = "Checking…"
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                let plan = try makePlan(launcher)
                try await launcher.move(plan, onPhase: { phase in Task { @MainActor in self?.phases[game.id] = phase } },
                                        progress: { p in Task { @MainActor in self?.phases[game.id] = "Moving \(Int(p * 100))%" } })
                await MainActor.run { self?.message = "\(game.name) moved. Steam starts again at the next Play." }
            } catch {
                await MainActor.run { self?.message = "\(error)" }
            }
            await MainActor.run { self?.phases[game.id] = nil }
            await self?.refresh()
        }
    }

    func hasUpdater(_ game: Game) -> Bool { launcher.updater(for: game) != nil }

    func preset(for game: Game) -> QualityPreset? {
        _ = presetRevision
        return launcher.preset(for: game)
    }

    func setPreset(_ preset: QualityPreset?, for game: Game) {
        try? launcher.overrides.update(game.steamAppID ?? 0) { $0.preset = preset }
        presetRevision += 1
    }

    /// `update`: run the game's own updater through Steam instead of the game.
    func play(_ game: Game, update: Bool = false) {
        guard phases[game.id] == nil else { return }
        message = nil
        phases[game.id] = update ? "Preparing update…" : "Preparing…"
        let options = update ? LaunchOptions(launchMode: .steam) : LaunchOptions(hud: showHUD)
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                if update { try await launcher.prepareUpdater(for: game) }
                var recorder = try await launcher.play(game, options: options) { phase in
                    Task { @MainActor in self?.phases[game.id] = phase }
                }
                await MainActor.run { self?.phases[game.id] = update ? "Updating" : "Playing" }
                await recorder.watch(maxSeconds: 8 * 3600)
                try launcher.finish(&recorder)
                let (keep, others) = await MainActor.run { () -> (Bool, Bool) in
                    guard let self else { return (true, true) }
                    let others = self.phases.contains { $0.key != game.id && ($0.value == "Playing" || $0.value == "Updating") }
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

    /// Looks a game up: an app id or store link gives a verdict, anything else is a name to search for.
    func runCheck(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        checkBusy = true; checkError = nil; checkResult = nil; checkResults = []
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                if let id = StoreClient.parseAppID(from: text) {
                    let result = try await launcher.check(appID: id)
                    await MainActor.run {
                        self?.checkResult = result
                        if result == nil { self?.checkError = "Steam has no public store page for app \(id)." }
                    }
                } else {
                    let found = try await StoreClient().search(text)
                    let best = StoreClient.bestMatch(found, for: text)
                    let results = (best.map { [$0] } ?? []) + found.filter { $0.id != best?.id }
                    await MainActor.run {
                        self?.checkResults = results
                        if results.isEmpty { self?.checkError = "No game found for \u{201C}\(text)\u{201D}." }
                    }
                }
            } catch {
                await MainActor.run { self?.checkError = "Could not reach Steam's store: \(error)" }
            }
            await MainActor.run { self?.checkBusy = false }
        }
    }

    /// Reads the owned library from Steam's own cache files (instant), then improves the verdicts through the store in the background.
    func loadAllGames() {
        guard !allGamesLoading else { return }
        allGamesLoading = true
        allGamesError = nil
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                let (games, entries) = try launcher.libraryEntries()
                await MainActor.run {
                    self?.ownedInfo = games
                    self?.allGames = entries
                    self?.allGamesLoading = false
                    self?.startRefining()
                }
            } catch {
                await MainActor.run { self?.allGamesError = "\(error)"; self?.allGamesLoading = false }
            }
        }
    }

    func startRefining() {
        guard refining == nil else { return }
        let todo = allGames.filter(LibraryAnalysis.needsRefinement)
        guard !todo.isEmpty else { return }
        refining = (0, todo.count)
        stopRefine.set(false)
        let launcher = self.launcher, games = ownedInfo, entries = allGames, flag = stopRefine
        Task.detached { [weak self] in
            await LibraryAnalysis.refine(entries, games: games, recipes: launcher.recipes, cache: launcher.storeCache,
                                         client: StoreClient(), shouldStop: { flag.isSet }) { updated, done, total in
                Task { @MainActor in
                    guard let self else { return }
                    if let index = self.allGames.firstIndex(where: { $0.appID == updated.appID }) { self.allGames[index] = updated }
                    self.refining = (done, total)
                }
            }
            await MainActor.run { self?.refining = nil }
        }
    }

    func stopRefining() { stopRefine.set(true) }

    func openCheck(appID: Int) {
        runCheck(String(appID))
    }

    /// Installs a game through Steam (Steam shows its own "Install" window to accept).
    func installGame(appID: Int) {
        guard installPhase[appID] == nil else { return }
        message = nil
        installPhase[appID] = "Starting…"
        let launcher = self.launcher
        Task.detached { [weak self] in
            do {
                let started = try await launcher.install(appID: appID) { phase in
                    Task { @MainActor in self?.installPhase[appID] = phase }
                }
                await MainActor.run { self?.installWatch = (started, false, Date()) }
            } catch {
                await MainActor.run { self?.message = "\(error)" }
            }
            await MainActor.run { self?.installPhase[appID] = nil }
            await self?.refresh()
        }
    }

    /// Looks for known problems with this game (setup, graphics layer, logs, power...) and offers a fix for each.
    func diagnose(_ game: Game) {
        let launcher = self.launcher
        Task.detached { [weak self] in
            let items = launcher.diagnose(game)
            let overrides = game.steamAppID.map { !launcher.overrides.read($0).isEmpty } ?? false
            await MainActor.run { self?.diagnosis = DiagnosisState(game: game, items: items, hasOverrides: overrides) }
        }
    }

    func applyFix(_ item: Diagnosis) {
        guard let fix = item.fix, var state = diagnosis, state.busy == nil else { return }
        state.busy = item.id; state.error = nil; state.phase = "Working…"
        diagnosis = state
        let game = state.game, launcher = self.launcher
        Task.detached { [weak self] in
            do {
                try await launcher.apply(fix, to: game) { phase in
                    Task { @MainActor in self?.diagnosis?.phase = phase }
                }
                let items = launcher.diagnose(game)
                await MainActor.run {
                    self?.diagnosis?.items = items
                    self?.diagnosis?.done.insert(item.id)
                    self?.diagnosis?.hasOverrides = game.steamAppID.map { !launcher.overrides.read($0).isEmpty } ?? false
                }
            } catch {
                await MainActor.run { self?.diagnosis?.error = "\(error)" }
            }
            await MainActor.run { self?.diagnosis?.busy = nil; self?.diagnosis?.phase = nil }
            await self?.refresh()
        }
    }

    /// Forgets the settings fixes added for this game (the recipe applies again).
    func resetSettings() {
        guard let state = diagnosis, let appID = state.game.steamAppID else { return }
        try? launcher.overrides.reset(appID)
        diagnose(state.game)
    }

    func copyDiagnosis() {
        guard let state = diagnosis else { return }
        let text = Diagnoser.text(for: state.game, diagnoses: state.items, system: .current())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
