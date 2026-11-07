import Foundation

public enum PEArchitecture: Sendable, Equatable {
    case x86, x64, arm64, unknown
}

/// Reads just enough of a Windows executable (PE) header to know its CPU architecture.
public enum PEInfo {
    public static func architecture(of header: Data) -> PEArchitecture {
        guard header.count >= 0x40, header[0] == 0x4D, header[1] == 0x5A else { return .unknown }   // "MZ"
        let peOffset = Int(header[0x3C]) | Int(header[0x3D]) << 8 | Int(header[0x3E]) << 16 | Int(header[0x3F]) << 24
        guard peOffset >= 0, peOffset + 6 <= header.count,
              header[peOffset] == 0x50, header[peOffset + 1] == 0x45,
              header[peOffset + 2] == 0, header[peOffset + 3] == 0 else { return .unknown }       // "PE\0\0"
        let machine = Int(header[peOffset + 4]) | Int(header[peOffset + 5]) << 8
        switch machine {
        case 0x014C: return .x86
        case 0x8664: return .x64
        case 0xAA64: return .arm64
        default: return .unknown
        }
    }

    public static func architecture(ofFile url: URL) -> PEArchitecture {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        return architecture(of: (try? handle.read(upToCount: 4096)) ?? Data())
    }
}

/// Installs DXVK next to a game executable and tells Wine to prefer those DLLs for that executable only.
/// Why per-executable: Steam is already running when a game starts, so per-game environment variables never
/// reach the game; and a global override would also affect the Steam client itself.
public enum DXVKInstaller {
    public static let dlls = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]

    /// `package` is a folder containing `x32/` and `x64/` (the DXVK release layout).
    @discardableResult
    public static func install(package: URL, executable: URL, architecture: PEArchitecture) throws -> [URL] {
        let subdirectory: String
        switch architecture {
        case .x86: subdirectory = "x32"
        case .x64: subdirectory = "x64"
        default: throw StirredError.blocked("Cannot install DXVK for an executable with unknown architecture.")
        }
        let source = package.appendingPathComponent(subdirectory, isDirectory: true)
        let destination = executable.deletingLastPathComponent()
        var copied: [URL] = []
        for name in dlls {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: from, to: to)
            copied.append(to)
        }
        return copied
    }

    /// `wine reg add ...` argument lists that make Wine load our native DLLs for this executable only.
    public static func registryCommands(executableName: String) -> [[String]] {
        dlls.map { dll in
            ["reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\\(executableName)\\DllOverrides",
             "/v", String(dll.dropLast(4)), "/d", "native,builtin", "/f"]
        }
    }
}

public enum GameExecutableFinder {
    private static let ignoredFragments = ["crash", "unins", "setup", "redist", "vcredist", "dxsetup", "helper", "launcher_"]

    /// Likely game executables at the top of an install directory (skips crash handlers, installers…).
    public static func candidates(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { url in
            let name = url.lastPathComponent.lowercased()
            return url.pathExtension.lowercased() == "exe" && !ignoredFragments.contains { name.contains($0) }
        }
    }
}
