// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KoboldOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kobold", targets: ["KoboldCLI"]),
        .executable(name: "KoboldOSControlPanel", targets: ["KoboldOSControlPanel"]),
        .library(name: "KoboldCore", targets: ["KoboldCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ],
    targets: [
        // MARK: - CLI
        .executableTarget(
            name: "KoboldCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "KoboldCore"
            ],
            path: "Sources/KoboldCLI",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),

        // MARK: - GUI
        .executableTarget(
            name: "KoboldOSControlPanel",
            dependencies: ["KoboldCore"],
            path: "Sources/KoboldOSControlPanel",
            exclude: ["Info.plist", "AppIcon.icns"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security")
            ]
        ),

        // MARK: - Core Library
        .target(
            name: "KoboldCore",
            dependencies: [],
            path: "Sources/KoboldCore",
            exclude: [
                // Multi-agent message bus system (not needed for GUI)
                "Agent/BaseAgent.swift",
                "Agent/CodingAgent.swift",
                "Agent/AgentMessageBus.swift",
                "Agent/ToolEngine.swift",
                "Agent/OllamaAgent.swift",
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "KoboldCoreTests",
            dependencies: ["KoboldCore"],
            path: "Tests/KoboldCoreTests"
        ),
    ]
)
