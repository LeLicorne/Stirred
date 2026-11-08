import Foundation

/// Where a game's picture can come from, best first. Newer Steam games are no longer served from the classic
/// `steam/apps/<id>/header.jpg` address (it answers 404), which is why some pictures were missing.
public enum CoverSources {
    /// A picture Steam itself already downloaded (works offline, and for new games): `appcache/librarycache/<id>/...`.
    /// Landscape pictures only: `library_header.jpg` (460x215), the old flat `header.jpg`, then `library_hero.jpg`.
    public static func localCover(appID: Int, steamRoot: URL) -> URL? {
        let folder = steamRoot.appendingPathComponent("appcache/librarycache/\(appID)", isDirectory: true)
        let fm = FileManager.default
        for name in ["header.jpg", "library_header.jpg", "library_hero.jpg"] {
            if fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return folder.appendingPathComponent(name) }
        }
        guard let walker = fm.enumerator(atPath: folder.path) else { return nil }
        let found = (walker.allObjects as? [String]) ?? []
        for name in ["library_header.jpg", "header.jpg", "library_hero.jpg"] {
            if let rel = found.first(where: { ($0 as NSString).lastPathComponent == name }) { return folder.appendingPathComponent(rel) }
        }
        return nil
    }

    /// Public addresses to try in order; the store's own `header_image` (hashed address) is tried after these.
    public static func remoteCandidates(appID: Int) -> [URL] {
        [
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg",
            "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/header.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/capsule_616x353.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero.jpg",
        ].compactMap(URL.init(string:))
    }

    /// Hue (0...1) derived from the name, so the generated tile of a game keeps its colour.
    public static func fallbackHue(for name: String) -> Double {
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return Double(hash % 360) / 360
    }
}
