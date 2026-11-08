import SwiftUI
import AppKit
import StirredCore

/// Pictures already loaded, kept for the session (scrolling a long list must not download again).
@MainActor final class CoverCache {
    static let shared = CoverCache()
    private var images: [Int: NSImage] = [:]
    private var missing: Set<Int> = []
    func image(_ id: Int) -> NSImage? { images[id] }
    func isMissing(_ id: Int) -> Bool { missing.contains(id) }
    func store(_ image: NSImage?, _ id: Int) { if let image { images[id] = image } else { missing.insert(id) } }
}

/// A game's picture (460:215). Tries Steam's own downloaded copy, then public addresses, then the store's address, and
/// finally draws a coloured tile with the game's name, so there is never an empty hole.
struct GameCover: View {
    @Environment(AppModel.self) private var model
    let appID: Int
    let name: String
    var dimmed = false
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Color.clear
            .aspectRatio(460.0 / 215.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if failed {
                    fallbackTile
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .opacity(dimmed ? 0.5 : 1)
            .task(id: appID) { await load() }
    }

    private var fallbackTile: some View {
        let hue = CoverSources.fallbackHue(for: name)
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55), Color(hue: hue, saturation: 0.7, brightness: 0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(name).font(.system(.headline, design: .rounded).bold()).foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center).minimumScaleFactor(0.4).padding(10).lineLimit(3)
        }
    }

    private func load() async {
        if let cached = CoverCache.shared.image(appID) { image = cached; return }
        if CoverCache.shared.isMissing(appID) { failed = true; return }
        let id = appID
        let root = try? model.launcher.steam().steamRoot
        let found: NSImage? = await Task.detached(priority: .utility) { () -> NSImage? in
            if let root, let local = CoverSources.localCover(appID: id, steamRoot: root),
               let data = try? Data(contentsOf: local), let picture = NSImage(data: data) { return picture }
            var urls = CoverSources.remoteCandidates(appID: id)
            if let info = try? await StoreClient().info(appID: id), let header = info.headerImage { urls.insert(header, at: 0) }
            for url in urls {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, let picture = NSImage(data: data) else { continue }
                return picture
            }
            return nil
        }.value
        CoverCache.shared.store(found, id)
        image = found
        failed = found == nil
    }
}
