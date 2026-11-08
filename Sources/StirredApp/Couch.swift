import SwiftUI
import AppKit
import GameController
import StirredCore

/// Game controllers for the couch view: D-pad or left stick to choose, A to play, Y to stop, B to leave.
/// (Inside a game, the controller is the game's business: Wine hands it to the game as usual.)
@MainActor
final class ControllerInput {
    var onEvent: ((CouchEvent) -> Void)?
    private(set) var controllerName: String?
    private var observers: [NSObjectProtocol] = []
    private var stickWasPushed = false

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { for controller in GCController.controllers() { self?.attach(controller) } }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllerName = GCController.controllers().first?.vendorName }
        })
        for controller in GCController.controllers() { attach(controller) }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for controller in GCController.controllers() {
            controller.extendedGamepad?.dpad.valueChangedHandler = nil
            controller.extendedGamepad?.leftThumbstick.valueChangedHandler = nil
            controller.extendedGamepad?.buttonA.pressedChangedHandler = nil
            controller.extendedGamepad?.buttonB.pressedChangedHandler = nil
            controller.extendedGamepad?.buttonY.pressedChangedHandler = nil
        }
    }

    private func send(_ event: CouchEvent) { onEvent?(event) }

    private func attach(_ controller: GCController) {
        controllerName = controller.vendorName ?? "Controller"
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.send(.left) } }
        }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.send(.right) } }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let event = StickMapper.event(x: x, y: y) {
                    if !self.stickWasPushed { self.stickWasPushed = true; self.send(event) }
                } else if abs(x) < 0.3 { self.stickWasPushed = false }
            }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { MainActor.assumeIsolated { self?.send(.select) } } }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { MainActor.assumeIsolated { self?.send(.back) } } }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { MainActor.assumeIsolated { self?.send(.stop) } } }
    }
}

/// A simple full-screen "big picture": one row of large covers, keyboard or controller.
struct CouchView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = CouchSelection(count: 0)
    @State private var controller = ControllerInput()
    @State private var controllerName: String?
    @State private var enteredFullScreen = false
    @FocusState private var focused: Bool

    private func handle(_ event: CouchEvent) {
        switch selection.apply(event) {
        case .none: break
        case .play(let i): if model.games.indices.contains(i), model.phases[model.games[i].id] == nil { model.play(model.games[i]) }
        case .stop(let i): if model.games.indices.contains(i) { model.stop(model.games[i]) }
        case .exit: model.couchMode = false
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                if model.games.isEmpty {
                    Text("No games installed yet").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                } else {
                    GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 28) {
                                ForEach(Array(model.games.enumerated()), id: \.element.id) { index, game in
                                    card(game, selected: index == selection.index).id(index)
                                        .onTapGesture { selection = CouchSelection(count: model.games.count, index: index); handle(.select) }
                                }
                            }
                            .padding(.horizontal, max((geo.size.width - 420) / 2, 40)).padding(.vertical, 30)
                        }
                        .onChange(of: selection.index) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
                    }
                    }.frame(height: 280)
                    if model.games.indices.contains(selection.index) {
                        let game = model.games[selection.index]
                        VStack(spacing: 6) {
                            Text(game.name).font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                            Text(model.phases[game.id] ?? "Press A or Return to play")
                                .font(.title3).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                Spacer()
                HStack(spacing: 24) {
                    Text("◀ ▶  choose").bold()
                    Text("A / Return  play")
                    Text("Y / S  stop")
                    Text("B / Esc  leave")
                    Text(controllerName.map { "🎮 \($0)" } ?? "No controller detected").foregroundStyle(.white.opacity(0.5))
                }
                .font(.callout).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 24)
            }
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { handle(.left); return .handled }
        .onKeyPress(.rightArrow) { handle(.right); return .handled }
        .onKeyPress(.return) { handle(.select); return .handled }
        .onKeyPress(.escape) { handle(.back); return .handled }
        .onKeyPress("s") { handle(.stop); return .handled }
        .onAppear {
            selection = CouchSelection(count: model.games.count)
            focused = true
            controller.onEvent = { handle($0) }
            controller.start()
            controllerName = controller.controllerName
            if let window = NSApp.keyWindow ?? NSApp.windows.first, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil); enteredFullScreen = true
            }
        }
        .onChange(of: model.games.count) { _, new in selection.update(count: new) }
        .onDisappear {
            controller.stop()
            if enteredFullScreen, let window = NSApp.keyWindow ?? NSApp.windows.first, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    private func card(_ game: Game, selected: Bool) -> some View {
        AsyncImage(url: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.storeID)/header.jpg")) { image in
            image.resizable().aspectRatio(460.0 / 215.0, contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.gray.opacity(0.3)).aspectRatio(460.0 / 215.0, contentMode: .fit)
                .overlay(Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.white.opacity(0.5)))
        }
        .frame(width: 420, height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: selected ? 5 : 0))
        .scaleEffect(selected ? 1.1 : 0.92).opacity(selected ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// The menu bar icon: what is running, play or stop a game, close Steam, open the window.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var steamText: String {
        switch model.steam { case .stopped: "Steam stopped"; case .running: "Steam starting…"; case .ready: "Steam ready" }
    }

    var body: some View {
        Text(steamText)
        Divider()
        if model.games.isEmpty { Text("No games installed") }
        ForEach(model.games) { game in
            let phase = model.phases[game.id]
            if phase == "Playing" || phase == "Updating" {
                Button("Stop \(game.name)") { model.stop(game) }
            } else if let phase {
                Text("\(game.name): \(phase)")
            } else {
                Button("Play \(game.name)") { model.play(game) }
            }
        }
        Divider()
        Button("Couch mode") { show(); model.couchMode = true }
        Button("Open Stirred") { show() }
        if model.steam != .stopped { Button("Close Steam") { model.quitSteam() } }
        Divider()
        Button("Quit Stirred") { NSApp.terminate(nil) }
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.windows.contains(where: { $0.canBecomeMain }) { NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        else { openWindow(id: "main") }
    }
}
