import SwiftUI
import AppKit

@main
struct StirredApp: App {
    @State private var model = AppModel()

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
        MenuBarExtra("Stirred", systemImage: "gamecontroller.fill") {
            MenuBarContent().environment(model)
        }
    }
}
