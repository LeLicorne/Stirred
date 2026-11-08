import Foundation

/// A one-choice summary of "how smooth versus how pretty". Presets only use levers Stirred really controls and has checked:
/// the frame queue and V-Sync (input delay), background shader compilation, and a frame-rate cap. They do NOT change a game's own
/// graphics options (those live in each game's files). A render-resolution lever was tried and dropped: Unity's `-screen-width`
/// is overridden by games that set their own resolution at startup (Muck did).
public enum QualityPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case performance, balanced, quality
    public var id: String { rawValue }

    public var title: String {
        switch self { case .performance: "Faster"; case .balanced: "Balanced"; case .quality: "Prettier" }
    }

    public var summary: String {
        switch self {
        case .performance: "Least input delay, V-Sync off, shaders compiled in the background so there is less stutter."
        case .balanced: "A good middle: low input delay and the game's own V-Sync setting."
        case .quality: "Even frame pacing, frames capped at 60 for a cooler, quieter Mac."
        }
    }
}

public struct PresetSettings: Sendable, Equatable {
    public var latency: LatencyProfile
    /// Extra dxvk.conf lines (recipe and personal settings win over these).
    public var dxvkOptions: [String: String]
}

public enum PresetCatalog {
    public static func settings(for preset: QualityPreset, hardware: HardwareProfile) -> PresetSettings {
        switch preset {
        case .performance:
            return PresetSettings(latency: .lowest, dxvkOptions: ["dxvk.enableAsync": "True"])
        case .balanced:
            return PresetSettings(latency: .low, dxvkOptions: [:])
        case .quality:
            return PresetSettings(latency: .balanced, dxvkOptions: ["dxgi.maxFrameRate": "60"])
        }
    }

    /// What suits the machine when the user has not chosen: small RAM favours speed, lots of RAM favours looks.
    public static func recommended(for hardware: HardwareProfile) -> QualityPreset {
        hardware.memoryGB <= 8 ? .performance : (hardware.memoryGB <= 16 ? .balanced : .quality)
    }
}
