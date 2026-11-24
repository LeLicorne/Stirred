import Foundation

/// Real frame pacing of a session, measured by Apple's Metal HUD (it writes every frame's duration to the log when
/// `MTL_HUD_ENABLED=1` and `MTL_HUD_LOG_ENABLED=1`; the HUD must be visible, so this exists only for runs with the FPS overlay on).
public struct FrameStats: Codable, Sendable, Equatable {
    public var frames: Int
    public var averageFPS: Double
    /// FPS of the slowest 1 % of frames ("1 % low"): what stutter feels like.
    public var onePercentLowFPS: Double
    public var medianFrameMs: Double

    public init?(frameTimesMs: [Double]) {
        let times = frameTimesMs.filter { $0 > 0 && $0 < 10_000 }
        guard times.count >= 30 else { return nil }                 // under half a second of frames says nothing
        let total = times.reduce(0, +)
        let sorted = times.sorted()
        let slowest = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.down)))]
        frames = times.count
        averageFPS = (Double(times.count) / total * 1000 * 10).rounded() / 10
        onePercentLowFPS = (1000 / slowest * 10).rounded() / 10
        medianFrameMs = (sorted[sorted.count / 2] * 100).rounded() / 100
    }
}

public enum MetalHUDLog {
    /// Frame durations (ms) from every `metal-HUD:` line of `text` written at or after `since`.
    /// Line: `2026-11-16 10:53:06.722 wine[pid:tid] metal-HUD: <first frame>,<x>,<memory MB>,<interval ms>,<gpu ms>,<interval ms>,<gpu ms>,...`
    public static func frameTimes(in text: String, since: Date? = nil) -> [Double] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var result: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "metal-HUD: ") else { continue }
            if let since {
                guard line.count >= 23, let stamp = formatter.date(from: String(line.prefix(23))), stamp >= since else { continue }
            }
            let fields = line[marker.upperBound...].split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 4 else { continue }
            var index = 3
            while index < fields.count {
                if let value = Double(fields[index].trimmingCharacters(in: .whitespaces)) { result.append(value) }
                index += 2
            }
        }
        return result
    }
}
