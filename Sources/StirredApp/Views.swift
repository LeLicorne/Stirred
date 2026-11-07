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
    @State private var section: Section? = .library

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SteamStatusBar().padding(10) }
        } detail: {
            switch section ?? .library {
            case .library: LibraryView()
            case .activity: ActivityView()
            case .logs: LogsView()
            }
        }
    }
}

// MARK: - Steam status

struct SteamStatusBar: View {
    @Environment(AppModel.self) private var model

    private var label: (text: String, color: Color) {
        switch model.steam {
        case .stopped: ("Steam stopped", .secondary)
        case .running: ("Steam starting / not logged in", .orange)
        case .ready: ("Steam ready", .green)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.engineName == nil {
                    Banner(text: "No Wine engine found. Run Scripts/assemble-engine.sh, then relaunch.", color: .red)
                }
                ForEach(model.warnings, id: \.self) { Banner(text: $0, color: .yellow) }
                if let message = model.message { Banner(text: message, color: .red) }

                if model.games.isEmpty {
                    ContentUnavailableView(
                        "No games yet", systemImage: "gamecontroller",
                        description: Text("Open Steam, sign in and install a game. It shows up here automatically."))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)], spacing: 16) {
                        ForEach(model.games) { GameCard(game: $0) }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem { Toggle(isOn: Bindable(model).showHUD) { Label("FPS overlay", systemImage: "speedometer") }.toggleStyle(.button) }
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
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(game.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(badge.text).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(badge.color.opacity(0.25), in: Capsule())
                }
                if let notes = recipe?.notes {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    Picker("Latency", selection: Binding(
                        get: { model.selectedLatency(for: game) },
                        set: { model.latency[game.id] = $0 })) {
                        ForEach(LatencyProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden().frame(width: 110).disabled(phase != nil)
                    .help("Lower = less input delay. 'Lowest' also turns V-Sync off.")
                    Spacer()
                    if let phase {
                        if phase == "Playing" {
                            Button("Stop", role: .destructive) { model.stop(game) }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(phase).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(recipe?.status == .unsupported || model.engineName == nil)
                    }
                }
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: SessionSummary?

    var body: some View {
        HSplitView {
            List(model.sessions, selection: $selected) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(s.title).font(.headline)
                        if s.crashed { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red) }
                    }
                    Text(s.startedAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                .tag(s)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            Group {
                if let selected { SessionDetail(session: selected).id(selected.id) }
                else { ContentUnavailableView("Select a session", systemImage: "waveform.path.ecg",
                                              description: Text("Every game launch is recorded here.")) }
            }
            .frame(minWidth: 480)
        }
        .navigationTitle("Activity")
    }
}

struct SessionDetail: View {
    let session: SessionSummary
    @State private var report: String = ""
    @State private var samples: [SessionSample] = []

    private struct Point: Identifiable { let id = UUID(); let t: Double; let value: Double; let series: String }

    private var points: [Point] {
        samples.filter { $0.processCount > 0 }.flatMap { s in
            [Point(t: s.t, value: Double(s.gpuPercent ?? 0), series: "GPU %"),
             Point(t: s.t, value: min(s.cpuPercent, 800), series: "Game CPU % (100 = 1 core)")]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !points.isEmpty {
                    Chart(points) { LineMark(x: .value("Seconds", $0.t), y: .value("%", $0.value)).foregroundStyle(by: .value("Series", $0.series)) }
                        .frame(height: 200)
                }
                Text(.init(report)).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            report = (try? String(contentsOf: session.url.appendingPathComponent("report.md"), encoding: .utf8)) ?? "(no report yet)"
            samples = (try? SessionRecorder.load(session.url).record.samples) ?? []
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var source = "steam-client.log"
    @State private var text = ""

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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Log", selection: $source) { ForEach(files, id: \.name) { Text($0.name).tag($0.name) } }.frame(width: 280)
                Spacer()
                Button("Reveal in Finder") { model.revealLogs() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { proxy.scrollTo("end") }
            }
        }
        .navigationTitle("Logs")
        .task(id: source) {
            while !Task.isCancelled {
                if let url = files.first(where: { $0.name == source })?.url {
                    text = LogCollector.tail(url, maxBytes: 60_000) ?? "(empty or missing)"
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
