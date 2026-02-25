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
        // ml-stable-diffusion removed — caused crashes (BPETokenizer fatal assertion)
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

        // MARK: - PTY C Bridge
        .target(
            name: "CPty",
            path: "Sources/CPty",
            publicHeadersPath: "include"
        ),

        // MARK: - GUI
        .executableTarget(
            name: "KoboldOSControlPanel",
            dependencies: [
                "KoboldCore",
                "CPty",
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
                // StableDiffusion removed — caused crashes
            ],
            path: "Sources/KoboldOSControlPanel",
            exclude: ["Info.plist", "AppIcon.icns"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
                .linkedLibrary("util")
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
