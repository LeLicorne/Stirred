import SwiftUI
import AppKit
import StirredCore

/// Pictures already loaded, kept for the session (scrolling a long list must not download again).
@MainActor final class CoverCache {
    static let shared = CoverCache()
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    func image(_ id: String) -> NSImage? { images[id] }
    func isMissing(_ id: String) -> Bool { missing.contains(id) }
    func store(_ image: NSImage?, _ id: String) { if let image { images[id] = image } else { missing.insert(id) } }
}

/// A game's picture (460:215). Tries Steam's own downloaded copy, then public addresses, then the store's address, and
/// finally draws a coloured tile with the game's name, so there is never an empty hole.
struct GameCover: View {
    @Environment(AppModel.self) private var model
    /// Steam app id; 0 for a game of another store (then `remote` is its picture).
    let appID: Int
    let name: String
    var dimmed = false
    /// Picture address given by the store itself (Epic).
    var remote: URL? = nil
    private var cacheKey: String { appID != 0 ? "steam:\(appID)" : "url:\(remote?.absoluteString ?? name)" }
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
            .task(id: cacheKey) { await load() }
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
        let key = cacheKey
        if let cached = CoverCache.shared.image(key) { image = cached; failed = false; return }
        if CoverCache.shared.isMissing(key) { image = nil; failed = true; return }
        let id = appID, remote = remote
        let root = try? model.launcher.steam().steamRoot
        let found: NSImage? = await Task.detached(priority: .utility) { () -> NSImage? in
            var urls: [URL] = remote.map { [$0] } ?? []
            if id != 0 {
                if let root, let local = CoverSources.localCover(appID: id, steamRoot: root),
                   let data = try? Data(contentsOf: local), let picture = NSImage(data: data) { return picture }
                urls += CoverSources.remoteCandidates(appID: id)
                if let info = try? await StoreClient().info(appID: id), let header = info.headerImage { urls.insert(header, at: 0) }
            }
            for url in urls {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, let picture = NSImage(data: data) else { continue }
                return picture
            }
            return nil
        }.value
        CoverCache.shared.store(found, key)
        image = found
        failed = found == nil
    }
}
