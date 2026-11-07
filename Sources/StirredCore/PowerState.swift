import Foundation
import IOKit.ps

/// Power conditions that silently cap game performance on a MacBook.
public struct PowerState: Sendable, Equatable {
    public var lowPowerMode: Bool
    public var onBattery: Bool

    public init(lowPowerMode: Bool, onBattery: Bool) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
    }

    public static var current: PowerState {
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            onBattery = (type == kIOPMBatteryPowerKey)
        }
        return PowerState(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, onBattery: onBattery)
    }
}

public enum PowerAdvice {
    /// Human-readable warnings. Measured on an M4: Low Power Mode on battery capped Muck at ~25-30 FPS; plugged in
    /// with Low Power Mode off it ran at ~130 FPS.
    public static func warnings(for state: PowerState) -> [String] {
        var result: [String] = []
        if state.lowPowerMode {
            result.append("Low Power Mode is on: macOS caps CPU/GPU speed. Turn it off in System Settings > Battery for full performance.")
        }
        if state.onBattery {
            result.append("Running on battery: plug in the charger for full performance.")
        }
        return result
    }
}
