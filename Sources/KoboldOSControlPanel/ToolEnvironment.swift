import Foundation
import KoboldCore

// MARK: - ToolEnvironment
// Detects available system tools and runtimes at launch.

@MainActor
final class ToolEnvironment: ObservableObject {
    static let shared = ToolEnvironment()

    struct ToolInfo: Identifiable {
        let id: String
        let name: String
        let path: String?
        let version: String?
        var isAvailable: Bool { path != nil }
    }

    @Published var tools: [ToolInfo] = []
    @Published var isScanning = false
    @Published var pythonDownloadProgress: Double?

    private let pythonSupportDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KoboldOS/python")
    }()

    var bundledPythonPath: String? {
        let path = pythonSupportDir.appendingPathComponent("bin/python3").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    var enhancedPATH: String {
        var paths: [String] = []

        // 1. App bundle (for future bundled tools like qjs)
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            paths.append(bundlePath)
        }

        // 2. Downloaded Python
        if bundledPythonPath != nil {
            paths.append(pythonSupportDir.appendingPathComponent("bin").path)
        }

        // 3. Homebrew
        paths.append("/opt/homebrew/bin")
        paths.append("/opt/homebrew/sbin")

        // 4. MacPorts / manual
        paths.append("/usr/local/bin")

        // 5. System
        paths.append("/usr/bin")
        paths.append("/bin")
        paths.append("/usr/sbin")
        paths.append("/sbin")

        return paths.joined(separator: ":")
    }

    private init() {}

    // MARK: - Scan

    func scan() async {
        isScanning = true

        let checks: [(id: String, name: String, binary: String, versionFlag: String)] = [
            ("python3", "Python", "python3", "--version"),
            ("node", "Node.js", "node", "--version"),
            ("git", "Git", "git", "--version"),
            ("ollama", "Ollama", "ollama", "--version"),
            ("brew", "Homebrew", "brew", "--version"),
            ("curl", "curl", "curl", "--version"),
            ("npm", "npm", "npm", "--version"),
            ("pip3", "pip", "pip3", "--version"),
            ("docker", "Docker", "docker", "--version"),
            ("ruby", "Ruby", "ruby", "--version"),
            ("swift", "Swift", "swift", "--version"),
            ("playwright", "Playwright", "npx", "playwright --version"),
        ]

        var results: [ToolInfo] = []

        for check in checks {
            let (path, version) = await probeToolNonisolated(binary: check.binary, versionFlag: check.versionFlag)
            results.append(ToolInfo(id: check.id, name: check.name, path: path, version: version))
        }

        tools = results
        isScanning = false
    }

    private nonisolated func probeToolNonisolated(binary: String, versionFlag: String) async -> (String?, String?) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Find binary
                let which = Process()
                which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                which.arguments = [binary]
                let whichPipe = Pipe()
                which.standardOutput = whichPipe
                which.standardError = FileHandle.nullDevice

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                which.environment = env

                do {
                    try which.run()
                    which.waitUntilExit()
                } catch {
                    continuation.resume(returning: (nil, nil))
                    return
                }

                guard which.terminationStatus == 0 else {
                    continuation.resume(returning: (nil, nil))
                    return
                }

                let pathData = whichPipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                guard let toolPath = path, !toolPath.isEmpty else {
                    continuation.resume(returning: (nil, nil))
                    return
                }

                // Get version
                let ver = Process()
                ver.executableURL = URL(fileURLWithPath: toolPath)
                ver.arguments = [versionFlag]
                let verPipe = Pipe()
                ver.standardOutput = verPipe
                ver.standardError = verPipe

                do {
                    try ver.run()
                    ver.waitUntilExit()
                } catch {
                    continuation.resume(returning: (toolPath, nil))
                    return
                }

                let verData = verPipe.fileHandleForReading.readDataToEndOfFile()
                let verStr = String(data: verData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n").first

                continuation.resume(returning: (toolPath, verStr))
            }
        }
    }

    // MARK: - On-Demand Python Download

    var hasPython: Bool {
        bundledPythonPath != nil || tools.first(where: { $0.id == "python3" })?.isAvailable == true
    }

    func downloadPython() async throws {
        // Download python-build-standalone for macOS ARM64
        let arch = "aarch64"
        let urlString = "https://github.com/astral-sh/python-build-standalone/releases/latest/download/cpython-3.12.8+20250106-\(arch)-apple-darwin-install_only_stripped.tar.gz"

        guard let url = URL(string: urlString) else {
            throw ToolError.executionFailed("Ungültige Download-URL")
        }

        pythonDownloadProgress = 0

        // Create directory
        try FileManager.default.createDirectory(at: pythonSupportDir.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in
                self?.pythonDownloadProgress = progress
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: url)

        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            pythonDownloadProgress = nil
            throw ToolError.executionFailed("Python Download fehlgeschlagen")
        }

        // Extract tar.gz
        let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("python-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["xzf", tempURL.path, "-C", extractDir.path]
        try tar.run()
        tar.waitUntilExit()

        guard tar.terminationStatus == 0 else {
            pythonDownloadProgress = nil
            throw ToolError.executionFailed("Python konnte nicht entpackt werden")
        }

        // Move python directory to App Support
        let extractedPython = extractDir.appendingPathComponent("python")
        if FileManager.default.fileExists(atPath: pythonSupportDir.path) {
            try FileManager.default.removeItem(at: pythonSupportDir)
        }
        try FileManager.default.moveItem(at: extractedPython, to: pythonSupportDir)

        // Cleanup
        try? FileManager.default.removeItem(at: extractDir)
        try? FileManager.default.removeItem(at: tempURL)

        pythonDownloadProgress = nil
        await scan()
    }
}
