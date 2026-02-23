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
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
    ],
    targets: [
        // MARK: - CLI
        .executableTarget(
            name: "KoboldCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "KoboldCore",
                .target(name: "WebGUI", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/KoboldCLI",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                .swiftLanguageMode(.v5),
            ]
        ),

        // MARK: - GUI
        .executableTarget(
            name: "KoboldOSControlPanel",
            dependencies: [
                "KoboldCore",
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
            ],
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
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/KoboldCore",
            exclude: [
                // Multi-agent message bus system (not needed for GUI)
                "Agent/BaseAgent.swift",
                "Agent/CodingAgent.swift",
                "Agent/AgentMessageBus.swift",
                "Agent/ToolEngine.swift",
                "Agent/OllamaAgent.swift",
            ]
        ),
        // MARK: - Web GUI (Linux/Docker support)
        .target(
            name: "WebGUI",
            dependencies: [
                "KoboldCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/WebGUI",
            swiftSettings: [.define("WEB_GUI")]
        ),

        // MARK: - Tests
        .testTarget(
            name: "KoboldCoreTests",
            dependencies: ["KoboldCore"],
            path: "Tests/KoboldCoreTests"
        ),
    ]
)
