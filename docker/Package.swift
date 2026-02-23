// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KoboldOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kobold", targets: ["KoboldCLI"]),
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
            exclude: [
                "ModelCommand.swift"
            ]
        ),

        // MARK: - Core Library (minimal for daemon only)
        .target(
            name: "KoboldCore",
            dependencies: [],
            path: "Sources/KoboldCore",
            exclude: [
                // Multi-agent message bus system
                "Agent/BaseAgent.swift",
                "Agent/CodingAgent.swift",
                "Agent/AgentMessageBus.swift",
                "Agent/ToolEngine.swift",
                "Agent/OllamaAgent.swift",
                // GUI-specific files
                "Engine/",
                "Native/",
                // Model files (except our stub)
                "Model/LocalModelBackend.swift",
                "Model/ModelBackend.swift",
                "Model/OllamaBackend.swift",
                "Model/ClaudeCodeBackend.swift",
                "Model/BackendManager.swift",
                // Tools that depend on macOS-specific frameworks
                "Tools/BrowserTool.swift",
                "Tools/DelegateTaskTool.swift",
                "Tools/DelegateParallelTool.swift",
                // Platform-specific files
                "Tools/CalendarTool.swift",
                "Tools/ContactsTool.swift",
                "Tools/AppleScriptTool.swift",
                "Tools/NotifyTool.swift",
                "Security/SecretsManager.swift",
                // Headless/Network files
                "Headless/LinuxSocket.swift",
                // Utils
                "Utils/SHA256Hash.swift",
            ]
        ),

        // MARK: - Web GUI (Linux/Docker support)
        .target(
            name: "WebGUI",
            dependencies: [
                "KoboldCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/KoboldOSControlPanel",
            sources: ["WebAppServer.swift"],
            swiftSettings: [.define("WEB_GUI")]
        ),
    ]
)