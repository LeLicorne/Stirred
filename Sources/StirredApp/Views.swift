import SwiftUI
import Charts
import StirredCore

enum Section: String, CaseIterable, Identifiable {
    case library = "Library", activity = "Activity", logs = "Logs"
    var id: String { rawValue }
    var icon: String {
        switch self { case .library: "gamecontroller"; case .activity: "waveform.path.ecg"; case .logs: "doc.text.magnifyingglass" }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // `open Stirred.app --args -section activity` opens a given tab (handy for screenshots).
    @State private var section: Section? = Section(rawValue: (UserDefaults.standard.string(forKey: "section") ?? "").capitalized) ?? .library

    var body: some View {
        switch model.setupComplete {
        case nil: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case false?: SetupView()
        case true?: mainView
        }
    }

    private var mainView: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SteamStatusBar().padding(12) }
        } detail: {
            switch section ?? .library {
            case .library: LibraryView()
            case .activity: ActivityView()
            case .logs: LogsView()
            }
        }
        // One flat background under the title: removes the lighter title strip and the notch where its edge met the divider.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - First-run setup

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Welcome to Stirred").font(.largeTitle.bold())
                Text("Play your Windows Steam games on this Mac. A one-time setup installs what is needed (about 300 MB).")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.setupItems) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? Color.green : Color.secondary).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.step.title).font(.headline)
                            Text(item.step.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20).frame(maxWidth: 520, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            if let error = model.setupError {
                Banner(text: error, color: .red).frame(maxWidth: 520)
            }

            if model.setupBusy {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(model.setupMessage ?? "").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button { model.runSetup() } label: {
                    Label(model.setupError == nil ? "Set up Stirred" : "Try again", systemImage: "arrow.down.circle.fill")
                        .font(.title3).padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }

            Text("When it is done, a Steam window opens: sign in once, and your games appear in Stirred.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Steam status

struct SteamStatusBar: View {
    @Environment(AppModel.self) private var model

    private var label: (text: String, color: Color) {
        switch model.steam {
        case .stopped: ("Steam stopped", .secondary)
        case .running: ("Steam starting…", .orange)
        case .ready: ("Steam ready", .green)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(label.color).frame(width: 9, height: 9)
                Text(label.text).font(.callout)
            }
            HStack {
                Button(model.steam == .stopped ? "Start Steam" : "Open Steam") { model.openSteamWindow() }
                if model.steam != .stopped { Button("Quit") { model.quitSteam() } }
            }
            .controlSize(.small)
            if let engine = model.engineName {
                Text(engine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Library

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("closeSteamAfterPlaying") private var closeSteam = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.engineName == nil {
                    Banner(text: "No Wine engine found. Run Scripts/assemble-engine.sh, then relaunch.", color: .red)
                }
                ForEach(model.warnings, id: \.self) { Banner(text: $0, color: .yellow) }
                if model.steam == .running && model.games.isEmpty {
                    Banner(text: "Steam is starting or waiting for you to sign in: use Open Steam in the sidebar.", color: .blue)
                }
                if let message = model.message { Banner(text: message, color: .red) }

                if model.games.isEmpty {
                    ContentUnavailableView(
                        "No games yet", systemImage: "gamecontroller",
                        description: Text("Open Steam, sign in and install a game. It shows up here automatically."))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 18, alignment: .top)], spacing: 18) {
                        ForEach(model.games) { GameCard(game: $0) }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Library")
        .confirmationDialog(
            "Uninstall \(model.pendingUninstall?.game.name ?? "")?",
            isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } }),
            titleVisibility: .visible, presenting: model.pendingUninstall
        ) { plan in
            Button("Uninstall (\(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)))", role: .destructive) {
                model.confirmUninstall(plan)
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("This deletes the game's files (\(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))) from this Mac. Your Steam Cloud saves are kept. Steam is closed first and starts again the next time you press Play.")
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $closeSteam) { Label("Close Steam after playing", systemImage: "power") }
                    .toggleStyle(.button)
                    .help("Stirred closes the Steam it started once your game ends (not if you opened Steam yourself)")
            }
            ToolbarItem {
                Toggle(isOn: Bindable(model).showHUD) { Label("FPS overlay", systemImage: "speedometer") }
                    .toggleStyle(.button)
                    .help("Show FPS and frame times inside the game (next launch)")
            }
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game

    private var phase: String? { model.phases[game.id] }
    private var recipe: Recipe? { model.recipe(for: game) }
    private var unsupported: Bool { recipe?.status == .unsupported }

    private var badge: (text: String, color: Color) {
        switch recipe?.status {
        case .perfect?: ("Perfect", .green)
        case .playable?: ("Playable", .green)
        case .experimental?: ("Experimental", .orange)
        case .offlineOnly?: ("Offline only", .orange)
        case .unsupported?: ("Unsupported", .red)
        default: ("Untested", .gray)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.storeID)/header.jpg")) { image in
                image.resizable().aspectRatio(460.0 / 215.0, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary).aspectRatio(460.0 / 215.0, contentMode: .fit)
                    .overlay(Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary))
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .opacity(unsupported ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(badge.text).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(badge.color.opacity(0.25), in: Capsule())
                    Menu {
                        Button("Uninstall…", role: .destructive) { model.askUninstall(game) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(phase != nil)
                    .help("More actions")
                }
                // Fixed height so every card has the same size, with or without notes.
                Text(recipe?.notes ?? "No notes yet. Play it once and Stirred will record how it ran.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                HStack {
                    Picker("Latency", selection: Binding(
                        get: { model.selectedLatency(for: game) },
                        set: { model.latency[game.id] = $0 })) {
                        ForEach(LatencyProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden().frame(width: 110).disabled(phase != nil || unsupported)
                    .help("Lower = less input delay. 'Lowest' also turns V-Sync off (tearing possible).")
                    Spacer()
                    action
                }
            }
            .padding(14)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Uninstall…", role: .destructive) { model.askUninstall(game) }.disabled(phase != nil)
        }
    }

    @ViewBuilder private var action: some View {
        if unsupported {
            Text("Can't run on macOS").font(.caption).foregroundStyle(.red)
        } else if let phase {
            if phase == "Playing" {
                Button("Stop", role: .destructive) { model.stop(game) }
            } else {
                ProgressView().controlSize(.small)
                Text(phase).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(model.engineName == nil)
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: SessionSummary?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet", systemImage: "waveform.path.ecg",
                                           description: Text("Press Play on a game: every launch is recorded here."))
                } else {
                    List(model.sessions, selection: $selected) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(s.title).font(.headline).lineLimit(1)
                                if s.crashed { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red) }
                            }
                            Text(s.startedAt, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(s)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(width: 260)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            Group {
                if let selected { SessionDetail(session: selected).id(selected.id) }
                else if !model.sessions.isEmpty {
                    ContentUnavailableView("Select a session", systemImage: "arrow.left",
                                           description: Text("Pick a launch on the left to see how it ran."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Activity")
        .onAppear { if selected == nil { selected = model.sessions.first } }
        .onChange(of: model.sessions) { if selected == nil { selected = model.sessions.first } }
    }
}

struct Metric: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SessionDetail: View {
    let session: SessionSummary
    @State private var record: SessionRecord?
    @State private var findings: [String] = []
    @State private var fullReport = ""

    private struct Point: Identifiable { let id = UUID(); let t: Double; let value: Double; let series: String }

    private var live: [SessionSample] { record?.samples.filter { $0.processCount > 0 } ?? [] }

    private var points: [Point] {
        live.flatMap { s in
            [Point(t: s.t, value: Double(s.gpuPercent ?? 0), series: "GPU % (whole machine)"),
             Point(t: s.t, value: min(s.cpuPercent, 800), series: "Game CPU % (100 = one core)")]
        }
    }

    private func icon(for finding: String) -> (String, Color) {
        if finding.hasPrefix("CRASH") { return ("exclamationmark.octagon.fill", .red) }
        if finding.contains("MoltenVK") { return ("cube.transparent", .orange) }
        if finding.contains("Low Power") || finding.contains("battery") { return ("battery.50percent", .yellow) }
        if finding.contains("-bound") || finding.contains("saturated") { return ("gauge.with.dots.needle.67percent", .blue) }
        return ("info.circle", .secondary)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title).font(.title.bold())
                    Text(session.startedAt, format: .dateTime.day().month().year().hour().minute()).foregroundStyle(.secondary)
                    Spacer()
                    Text(session.crashed ? "Crash detected" : "No crash")
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                        .background((session.crashed ? Color.red : .green).opacity(0.25), in: Capsule())
                }

                if let record {
                    let gpu = ReportBuilder.stats(live.compactMap { $0.gpuPercent.map(Double.init) })
                    let cpu = ReportBuilder.stats(live.map(\.cpuPercent))
                    let mem = ReportBuilder.stats(live.map { Double($0.rssMB) })
                    // Time actually played (first to last sample), not including the wait for Steam and the game to start.
                    let seconds = live.last.map { Int($0.t) } ?? record.endedAt.map { Int($0.timeIntervalSince(record.startedAt)) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        Metric(title: "Played", value: seconds.map { "\($0 / 60) min \($0 % 60) s" } ?? "n/a", icon: "clock")
                        Metric(title: "GPU (avg / max)", value: gpu.map { "\(Int($0.avg))% / \(Int($0.max))%" } ?? "n/a", icon: "cpu")
                        Metric(title: "Game CPU (avg)", value: cpu.map { "\(Int($0.avg))%" } ?? "n/a", icon: "speedometer")
                        Metric(title: "Memory (max)", value: mem.map { "\(Int($0.max)) MB" } ?? "n/a", icon: "memorychip")
                        Metric(title: "Graphics", value: "\(record.backend.uppercased()) · \(record.latency)", icon: "paintpalette")
                    }

                    if !points.isEmpty {
                        GroupBox("CPU and GPU over time") {
                            Chart(points) {
                                LineMark(x: .value("Seconds", $0.t), y: .value("%", $0.value))
                                    .foregroundStyle(by: .value("Series", $0.series))
                            }
                            .chartLegend(position: .bottom)
                            .frame(height: 190)
                            .padding(.top, 6)
                        }
                    }

                    GroupBox("Findings") {
                        VStack(alignment: .leading, spacing: 10) {
                            if findings.isEmpty { Text("Nothing notable.").foregroundStyle(.secondary) }
                            ForEach(findings, id: \.self) { f in
                                let (name, color) = icon(for: f)
                                Label { Text(f).fixedSize(horizontal: false, vertical: true) }
                                icon: { Image(systemName: name).foregroundStyle(color) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }

                    Text("\(record.system.chip) · \(record.system.memoryGB) GB · macOS \(record.system.macOS)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("FPS are not recorded: turn on “FPS overlay” in the Library and take a screenshot.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
                    Button("Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullReport, forType: .string)
                    }
                }
                DisclosureGroup("Full report (text)") {
                    Text(fullReport).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            record = try? SessionRecorder.load(session.url).record
            fullReport = (try? String(contentsOf: session.url.appendingPathComponent("report.md"), encoding: .utf8)) ?? ""
            findings = ReportBuilder.findingsSection(of: fullReport)
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var source = "steam-client.log"
    @State private var text = ""
    @State private var errorsOnly = false
    @State private var search = ""

    private var files: [(name: String, url: URL)] {
        var result: [(String, URL)] = [("steam-client.log", model.launcher.paths.logs.appendingPathComponent("steam-client.log"))]
        if let steam = try? model.launcher.steam() {
            for name in ["connection_log.txt", "console_log.txt", "gameprocess_log.txt", "bootstrap_log.txt"] {
                result.append((name, steam.steamRoot.appendingPathComponent("logs/\(name)")))
            }
        }
        let dxvk = model.launcher.paths.logs.appendingPathComponent("dxvk")
        for url in LogCollector.recentFiles(in: dxvk, extension: "log", after: .distantPast) {
            result.append(("dxvk/\(url.lastPathComponent)", url))
        }
        return result
    }

    private var shown: String {
        guard errorsOnly || !search.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let l = line.lowercased()
            let isError = l.contains("err:") || l.contains("error") || l.contains("fail") || l.contains("crash") || l.contains("warn")
            return (!errorsOnly || isError) && (search.isEmpty || l.contains(search.lowercased()))
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Log", selection: $source) { ForEach(files, id: \.name) { Text($0.name).tag($0.name) } }
                    .labelsHidden().frame(width: 260)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle("Errors only", isOn: $errorsOnly)
                Spacer()
                Button("Reveal in Finder") { model.revealLogs() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(shown.isEmpty ? "(nothing to show)" : shown)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: shown) { proxy.scrollTo("end") }
            }
        }
        .navigationTitle("Logs")
        .task(id: source) {
            while !Task.isCancelled {
                if let url = files.first(where: { $0.name == source })?.url {
                    text = LogCollector.tail(url, maxBytes: 80_000) ?? "(empty or missing)"
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
