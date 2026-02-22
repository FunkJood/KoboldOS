import Foundation
import AppKit

// MARK: - UpdateManager
// GitHub-based auto-update system.
// Checks the configured GitHub repo for new releases, downloads DMG, installs, and restarts.

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    static let currentVersion = "0.2.5"

    @Published var state: UpdateState = .idle
    @Published var latestVersion: String?
    @Published var releaseNotes: String?
    @Published var downloadProgress: Double = 0

    static let githubRepo = "FunkJood/KoboldOS"

    enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String)
        case downloading(percent: Double)
        case installing
        case error(String)
        case upToDate
    }

    private var downloadTask: URLSessionDownloadTask?

    private init() {}

    // MARK: - Check for Updates

    func checkForUpdates() async {
        guard !Self.githubRepo.isEmpty else {
            state = .error("Kein GitHub-Repository konfiguriert")
            return
        }

        state = .checking

        let urlString = "https://api.github.com/repos/\(Self.githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            state = .error("Ungültige Repository-URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KoboldOS/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                state = .error("Keine HTTP-Antwort")
                return
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    state = .upToDate  // No release yet = up to date
                } else if httpResponse.statusCode == 403 {
                    state = .error("GitHub API Rate-Limit erreicht")
                } else {
                    state = .error("GitHub API Fehler: \(httpResponse.statusCode)")
                }
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                state = .error("Ungültige Antwort von GitHub")
                return
            }

            guard let tagName = json["tag_name"] as? String else {
                state = .error("Kein Tag in Release gefunden")
                return
            }

            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            latestVersion = remoteVersion
            releaseNotes = json["body"] as? String

            if isNewer(remote: remoteVersion, local: Self.currentVersion) {
                state = .available(version: remoteVersion)
            } else {
                state = .upToDate
            }

        } catch {
            state = .error("Verbindungsfehler: \(error.localizedDescription)")
        }
    }

    // MARK: - Download & Install

    func downloadAndInstall() async {
        guard !Self.githubRepo.isEmpty else { return }

        guard case .available = state else { return }

        state = .downloading(percent: 0)
        downloadProgress = 0

        let urlString = "https://api.github.com/repos/\(Self.githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KoboldOS/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else {
                state = .error("Keine Assets im Release")
                return
            }

            // Find DMG asset
            guard let dmgAsset = assets.first(where: {
                ($0["name"] as? String)?.hasSuffix(".dmg") == true
            }), let downloadURL = dmgAsset["browser_download_url"] as? String,
               let dmgURL = URL(string: downloadURL) else {
                state = .error("Keine DMG-Datei im Release gefunden")
                return
            }

            // Download DMG
            let tempDir = FileManager.default.temporaryDirectory
            let dmgPath = tempDir.appendingPathComponent("KoboldOS-update.dmg")

            // Remove old temp file if exists
            try? FileManager.default.removeItem(at: dmgPath)

            let delegate = DownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.state = .downloading(percent: progress)
                }
            }

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let (tempURL, response) = try await session.download(from: dmgURL)

            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                state = .error("Download fehlgeschlagen")
                return
            }

            try FileManager.default.moveItem(at: tempURL, to: dmgPath)

            // Install
            state = .installing
            try await installFromDMG(dmgPath: dmgPath)

        } catch {
            state = .error("Download-Fehler: \(error.localizedDescription)")
        }
    }

    // MARK: - Install from DMG

    private func installFromDMG(dmgPath: URL) async throws {
        let appPath = Bundle.main.bundlePath
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("KoboldOS-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // Run blocking Process calls off the main thread to prevent UI freeze
        let mountStatus = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let mountProcess = Process()
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountProcess.arguments = ["attach", dmgPath.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet"]
            try? mountProcess.run()
            mountProcess.waitUntilExit()
            return mountProcess.terminationStatus
        }.value

        guard mountStatus == 0 else {
            state = .error("DMG konnte nicht gemountet werden")
            return
        }

        // Find .app in DMG
        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let appInDMG = contents.first(where: { $0.pathExtension == "app" }) else {
            // Unmount on error
            await Task.detached {
                let u = Process(); u.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                u.arguments = ["detach", mountPoint.path, "-quiet"]; try? u.run(); u.waitUntilExit()
            }.value
            state = .error("Keine App im DMG gefunden")
            return
        }

        // Create update script that replaces the app after quit
        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("kobold-update.sh")
        let script = """
        #!/bin/bash
        sleep 2
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done
        sleep 1
        rm -rf "\(appPath)"
        cp -R "\(appInDMG.path)" "\(appPath)"
        hdiutil detach "\(mountPoint.path)" -quiet 2>/dev/null
        open "\(appPath)"
        rm -f "\(scriptPath.path)"
        """

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        // chmod + launch off main thread
        await Task.detached {
            let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+x", scriptPath.path]; try? chmod.run(); chmod.waitUntilExit()
        }.value

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptPath.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()

        try await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }

    // MARK: - Version Comparison

    func isNewer(remote: String, local: String) -> Bool {
        let rParts = remote.split(separator: ".").compactMap { Int($0) }
        let lParts = local.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(rParts.count, lParts.count)
        for i in 0..<maxLen {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Cancel

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }
}

// MARK: - Download Delegate (for progress tracking)

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by async/await
    }
}
