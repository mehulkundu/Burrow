// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Burrow",
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
