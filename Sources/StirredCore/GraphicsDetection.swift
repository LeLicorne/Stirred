import Foundation

public enum GraphicsAPI: String, CaseIterable, Sendable {
    case d3d9, d3d10, d3d11, d3d12, vulkan

    /// DLL names that betray the API in a PE import table (matched case-insensitively by trying common spellings).
    var dllNames: [String] {
        switch self {
        case .d3d9: ["d3d9.dll"]
        case .d3d10: ["d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
        case .d3d11: ["d3d11.dll"]
        case .d3d12: ["d3d12.dll"]
        case .vulkan: ["vulkan-1.dll"]
        }
    }
}

/// Cheap heuristic: look for DLL names in the executable's bytes. A game may also load APIs at runtime,
/// so this is a hint for the LaunchPlanner, never a guarantee; recipes override it.
public enum GraphicsDetector {
    public static func detect(in data: Data) -> Set<GraphicsAPI> {
        var found: Set<GraphicsAPI> = []
        for api in GraphicsAPI.allCases {
            for name in api.dllNames where contains(data, name) {
                found.insert(api)
            }
        }
        return found
    }

    public static func detect(executables: [URL]) -> Set<GraphicsAPI> {
        var all: Set<GraphicsAPI> = []
        for url in executables {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            all.formUnion(detect(in: data))
        }
        return all
    }

    private static func contains(_ data: Data, _ name: String) -> Bool {
        // Import tables keep the compiler's casing: d3d11.dll, D3D11.dll, D3D11.DLL, D3d11.dll...
        let stem = name.dropLast(4)
        let variants = [
            name, name.uppercased(), stem.uppercased() + ".dll",
            name.prefix(1).uppercased() + name.dropFirst(),
        ]
        return variants.contains { variant in
            data.range(of: Data(variant.utf8)) != nil
        }
    }
}
