import Foundation

/// Steam's UI (Chromium) paints a black window under Wine 11. The fix: `steamwebhelper.exe` is replaced by a tiny
/// wrapper (Resources/wrappers, source in Wrapper/) that starts the original, kept as `steamwebhelper_real.exe`, with
/// `--disable-gpu --single-process`. Steam must be started with `-noverifyfiles` so it does not restore the original.
public enum WebHelperWrapper {
    /// Valve's helper is ~7.5 MB, our wrapper ~150 KB: the SIZE tells them apart (never compare hashes: a rebuilt wrapper
    /// has another hash, and once treating an old wrapper as "the original" made the wrapper launch itself forever).
    static let sizeCeiling = 500_000

    public enum Failure: Error, CustomStringConvertible {
        case originalMissing(URL)
        public var description: String {
            switch self {
            case .originalMissing(let dir):
                "steamwebhelper_real.exe in \(dir.path) is missing or is not Valve's file. Start Steam once without -noverifyfiles so it restores it."
            }
        }
    }

    private static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    public static func cefDirectory(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("bin/cef/cef.win64", isDirectory: true)
    }

    /// True once Steam's real helper has been saved next to the wrapper.
    public static func isInstalled(steamRoot: URL) -> Bool {
        let dir = cefDirectory(steamRoot: steamRoot)
        return (size(of: dir.appendingPathComponent("steamwebhelper.exe")) ?? Int.max) < sizeCeiling
            && (size(of: dir.appendingPathComponent("steamwebhelper_real.exe")) ?? 0) > sizeCeiling
    }

    /// Makes sure the wrapper is in place. Returns true if something changed, false if nothing to do
    /// (including "Steam has not downloaded its UI yet").
    @discardableResult
    public static func ensure(steamRoot: URL, wrapper: URL) throws -> Bool {
        let fm = FileManager.default
        let dir = cefDirectory(steamRoot: steamRoot)
        let target = dir.appendingPathComponent("steamwebhelper.exe")
        let real = dir.appendingPathComponent("steamwebhelper_real.exe")
        guard let targetSize = size(of: target) else { return false }
        if targetSize < sizeCeiling {
            // Already a wrapper: refresh it, never touch the real helper.
            guard (size(of: real) ?? 0) > sizeCeiling else { throw Failure.originalMissing(dir) }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: wrapper, to: target)
            return false
        }
        try? fm.removeItem(at: real)
        try fm.copyItem(at: target, to: real)
        try fm.removeItem(at: target)
        try fm.copyItem(at: wrapper, to: target)
        return true
    }
}
