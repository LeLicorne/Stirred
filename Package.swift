// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stirred",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StirredCore", targets: ["StirredCore"]),
        .executable(name: "stirredctl", targets: ["stirredctl"]),
    ],
    targets: [
        // All logic lives here: no UI, fully testable.
        .target(name: "StirredCore"),
        // Thin command-line front end used for debugging and CI.
        .executableTarget(name: "stirredctl", dependencies: ["StirredCore"]),
        .testTarget(name: "StirredCoreTests", dependencies: ["StirredCore"]),
    ]
)
