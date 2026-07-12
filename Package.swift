// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPiP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentPiP", targets: ["AgentPiP"])],
    targets: [
        .executableTarget(
            name: "AgentPiP",
            path: "Sources/AgentPiP",
            resources: [.process("ProviderIcons")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Security"), .linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AgentPiPTests", dependencies: ["AgentPiP"], path: "Tests/AgentPiPTests")
    ]
)
