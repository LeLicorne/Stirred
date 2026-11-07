import Foundation

public enum LogRotation {
    /// If `url` is bigger than `maxBytes`, keep it as `<name>.1` (replacing an older one) and start fresh.
    /// Wine + MoltenVK are chatty: an unbounded log reached 7 GB once.
    @discardableResult
    public static func rotateIfNeeded(_ url: URL, maxBytes: Int = 20_000_000) -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes else { return false }
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        return (try? fm.moveItem(at: url, to: old)) != nil
    }
}
