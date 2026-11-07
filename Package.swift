// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stirred",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StirredCore", targets: ["StirredCore"]),
        .executable(name: "stirredctl", targets: ["stirredctl"]),
        .executable(name: "StirredApp", targets: ["StirredApp"]),
    ],
    targets: [
        // All logic lives here: no UI, fully testable.
        .target(name: "StirredCore"),
        // Thin command-line front end used for debugging and CI.
        .executableTarget(name: "stirredctl", dependencies: ["StirredCore"]),
        // The Mac app (SwiftUI). Bundled into Stirred.app by Scripts/build-app.sh.
        .executableTarget(name: "StirredApp", dependencies: ["StirredCore"]),
        .testTarget(name: "StirredCoreTests", dependencies: ["StirredCore"]),
    ]
)
