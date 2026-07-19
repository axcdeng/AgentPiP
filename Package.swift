// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPiP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentPiP", targets: ["AgentPiP"]),
        .executable(name: "AgentPiPHook", targets: ["AgentPiPHook"])
    ],
    targets: [
        .executableTarget(
            name: "AgentPiP",
            path: "Sources/AgentPiP",
            resources: [.process("ProviderIcons")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Security"), .linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "AgentPiPHook", path: "Sources/AgentPiPHook"),
        .testTarget(name: "AgentPiPTests", dependencies: ["AgentPiP"], path: "Tests/AgentPiPTests")
    ]
)
