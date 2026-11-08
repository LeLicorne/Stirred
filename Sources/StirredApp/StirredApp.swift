import SwiftUI
import AppKit

@main
struct StirredApp: App {
    @State private var model = AppModel()
    @AppStorage("uiZoom") private var zoom: Double = 1

    private func zoom(by step: Double) { zoom = min(2.0, max(0.7, ((zoom + step) * 10).rounded() / 10)) }

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Stirred", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    model.start()
                    // `open Stirred.app --args -couch YES` opens couch mode (handy for screenshots).
                    if UserDefaults.standard.bool(forKey: "couch") {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.couchMode = true
                    }
                }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                // "=" and "+" both zoom in: on many keyboards "+" needs Shift.
                Button("Zoom In") { zoom(by: 0.1) }.keyboardShortcut("+", modifiers: .command)
                Button("Zoom In ") { zoom(by: 0.1) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { zoom(by: -0.1) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { zoom = 1 }.keyboardShortcut("0", modifiers: .command)
            }
        }
        MenuBarExtra("Stirred", systemImage: "gamecontroller.fill") {
            MenuBarContent().environment(model)
        }
    }
}
