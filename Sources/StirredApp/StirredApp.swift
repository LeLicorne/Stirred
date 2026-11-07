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
        WindowGroup("Stirred") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .task { model.start() }
        }
    }
}
