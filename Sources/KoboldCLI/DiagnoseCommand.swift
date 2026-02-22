import ArgumentParser
import Foundation

struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Diagnose KoboldOS setup and dependencies"
    )

    @Option(name: .long, help: "Daemon port") var port: Int = 8080

    mutating func run() async throws {
        print("🔍 KoboldOS Diagnose")
        print(String(repeating: "─", count: 40))

        // Check Ollama
        print("\n📦 Ollama:")
        let ollamaRunning = await checkOllama()
        print("   Status: \(ollamaRunning ? "✅ Running" : "❌ Not running")")

        // Check daemon
        print("\n🐲 Daemon:")
        let daemonOK = await checkDaemon(port: port)
        print("   Port \(port): \(daemonOK ? "✅ Responding" : "❌ Not responding")")

        // Check disk space
        print("\n💾 Disk:")
        let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        if let free = attrs?[.systemFreeSize] as? Int64 {
            let freeGB = Double(free) / 1_073_741_824
            print("   Free: \(String(format: "%.1f", freeGB)) GB")
        }

        // Check app support dir
        print("\n📁 App Support:")
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("KoboldOS")
        if let path = appSupport {
            let exists = FileManager.default.fileExists(atPath: path.path)
            print("   KoboldOS dir: \(exists ? "✅ Exists" : "⚠️  Not created yet")")
        }

        print("\n" + String(repeating: "─", count: 40))
        print("Diagnose abgeschlossen.")
    }

    private func checkOllama() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        if let (_, resp) = try? await URLSession.shared.data(from: url) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }

    private func checkDaemon(port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/health") else { return false }
        if let (_, resp) = try? await URLSession.shared.data(from: url) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }
}
