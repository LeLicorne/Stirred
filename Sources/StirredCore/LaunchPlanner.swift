import Foundation

public struct HardwareProfile: Sendable, Equatable {
    public var memoryGB: Int
    public init(memoryGB: Int) { self.memoryGB = memoryGB }

    public static var current: HardwareProfile {
        HardwareProfile(memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }
}

/// Everything needed to start a game, computed from pure inputs so it is easy to test.
public struct LaunchPlan: Sendable, Equatable {
    public var backend: GraphicsBackend
    public var environment: [String: String]
    public var gameArguments: [String]
    public var warnings: [String]
    /// Extra components (e.g. "dxvk", "vcrun2022") that must be installed in the prefix first.
    public var requiredComponents: [String]
    /// Non-nil means we refuse to launch and explain why.
    public var blockedReason: String?
}

public enum LaunchPlanner {
    public static func plan(
        recipe: Recipe?,
        detectedAPIs: Set<GraphicsAPI>,
        hardware: HardwareProfile = .current,
        hud: Bool = false
    ) -> LaunchPlan {
        var warnings: [String] = []
        var components: [String] = []

        // 1. Backend: recipe wins, then detected API, then DX11 default.
        let backend: GraphicsBackend
        if let chosen = recipe?.graphics {
            backend = chosen
        } else if detectedAPIs.contains(.d3d12) {
            backend = .vkd3d
        } else {
            // DXMT cannot create its Metal view on current upstream Wine builds (needs exported macdrv
            // symbols), so DXVK-macOS + MoltenVK is the default for DX9/10/11 until that changes.
            backend = .dxvk
        }

        switch backend {
        case .dxvk: components.append("dxvk")
        case .vkd3d: components.append("vkd3d-proton")
        case .dxmt, .wined3d: break
        }

        // 2. Environment: sensible defaults, then recipe overrides.
        var env: [String: String] = ["WINEMSYNC": "1", "WINEDEBUG": "-all"]
        if hud { env["MTL_HUD_ENABLED"] = "1" }
        if let overrides = recipe?.dllOverrides, !overrides.isEmpty {
            env["WINEDLLOVERRIDES"] = overrides
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ";")
        }
        for (key, value) in recipe?.env ?? [:] { env[key] = value }

        // 3. Warnings and blocking.
        var blocked: String?
        switch recipe?.status {
        case .unsupported:
            let why = recipe?.blockers?.joined(separator: ", ") ?? "known incompatibility"
            blocked = "\(recipe?.name ?? "This game") is not supported (\(why))."
        case .offlineOnly:
            warnings.append("Offline/bots only: online play is blocked by an anti-cheat that cannot run on macOS.")
        case .experimental:
            warnings.append("Experimental compatibility: expect crashes or low performance.")
        default:
            break
        }
        if backend == .vkd3d {
            warnings.append("DirectX 12 runs through vkd3d-proton + MoltenVK: experimental.")
            if hardware.memoryGB <= 16 {
                warnings.append("Only \(hardware.memoryGB) GB of unified memory: lower graphics settings.")
            }
        }
        if recipe == nil {
            warnings.append("No recipe for this game yet: using defaults.")
        }

        return LaunchPlan(
            backend: backend, environment: env, gameArguments: recipe?.launchArgs ?? [],
            warnings: warnings, requiredComponents: components, blockedReason: blocked)
    }
}
