#if os(macOS)
import Foundation

// MARK: - MQTT Tool (via mosquitto CLI)
public struct MQTTTool: Tool {
    public let name = "mqtt"
    public let description = "MQTT: IoT/Smart-Home Nachrichten publizieren und abonnieren (mosquitto CLI)"
    public let riskLevel: RiskLevel = .medium

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: publish, subscribe, list_subscriptions", enumValues: ["publish", "subscribe", "list_subscriptions"], required: true),
            "topic": ToolSchemaProperty(type: "string", description: "MQTT Topic (z.B. 'home/living-room/temperature')"),
            "message": ToolSchemaProperty(type: "string", description: "Nachricht für publish"),
            "qos": ToolSchemaProperty(type: "string", description: "Quality of Service: 0, 1 oder 2 (Standard: 0)"),
            "count": ToolSchemaProperty(type: "string", description: "Anzahl Nachrichten für subscribe (Standard: 1)"),
            "timeout": ToolSchemaProperty(type: "string", description: "Timeout in Sekunden für subscribe (Standard: 5)")
        ], required: ["action"])
    }

    public init() {}

    public func validate(arguments: [String: String]) throws {
        guard let action = arguments["action"], !action.isEmpty else {
            throw ToolError.missingRequired("action")
        }
    }

    private struct MQTTConfig {
        let host: String
        let port: String
        let username: String
        let password: String
    }

    private func loadConfig() -> MQTTConfig? {
        let d = UserDefaults.standard
        let host = d.string(forKey: "kobold.mqtt.host") ?? ""
        guard !host.isEmpty else { return nil }
        return MQTTConfig(
            host: host,
            port: d.string(forKey: "kobold.mqtt.port") ?? "1883",
            username: d.string(forKey: "kobold.mqtt.username") ?? "",
            password: d.string(forKey: "kobold.mqtt.password") ?? ""
        )
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let action = arguments["action"] ?? ""

        guard let config = loadConfig() else {
            return "Error: MQTT nicht konfiguriert. Bitte unter Einstellungen → Verbindungen → MQTT den Host eintragen."
        }

        switch action {
        case "publish":
            guard let topic = arguments["topic"], !topic.isEmpty else { return "Error: 'topic' Parameter fehlt." }
            guard let message = arguments["message"], !message.isEmpty else { return "Error: 'message' Parameter fehlt." }
            let qos = arguments["qos"] ?? "0"
            return await publish(config: config, topic: topic, message: message, qos: qos)

        case "subscribe":
            guard let topic = arguments["topic"], !topic.isEmpty else { return "Error: 'topic' Parameter fehlt." }
            let count = arguments["count"] ?? "1"
            let timeout = arguments["timeout"] ?? "5"
            return await subscribe(config: config, topic: topic, count: count, timeout: timeout)

        case "list_subscriptions":
            return listSubscriptions()

        default:
            return "Error: Unbekannte Aktion '\(action)'."
        }
    }

    private func buildMosquittoArgs(config: MQTTConfig, extra: [String]) -> [String] {
        var args = ["-h", config.host, "-p", config.port]
        if !config.username.isEmpty {
            args += ["-u", config.username]
            if !config.password.isEmpty {
                args += ["-P", config.password]
            }
        }
        return args + extra
    }

    private func publish(config: MQTTConfig, topic: String, message: String, qos: String) async -> String {
        let mosquittoPub = findMosquitto("mosquitto_pub")
        guard let path = mosquittoPub else {
            return "Error: mosquitto_pub nicht gefunden. Bitte installieren: brew install mosquitto"
        }

        let args = buildMosquittoArgs(config: config, extra: ["-t", topic, "-m", message, "-q", qos])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return "Error: mosquitto_pub fehlgeschlagen: \(err)"
            }
            return "MQTT Nachricht publiziert: \(topic) → \(message)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func subscribe(config: MQTTConfig, topic: String, count: String, timeout: String) async -> String {
        let mosquittoSub = findMosquitto("mosquitto_sub")
        guard let path = mosquittoSub else {
            return "Error: mosquitto_sub nicht gefunden. Bitte installieren: brew install mosquitto"
        }

        let args = buildMosquittoArgs(config: config, extra: ["-t", topic, "-C", count, "-W", timeout, "-v"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8) ?? ""

            if outStr.isEmpty {
                return "Keine Nachrichten empfangen innerhalb von \(timeout)s auf Topic '\(topic)'."
            }
            return "MQTT Empfangen:\n\(outStr)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func listSubscriptions() -> String {
        let topics = UserDefaults.standard.stringArray(forKey: "kobold.mqtt.savedTopics") ?? []
        if topics.isEmpty { return "Keine gespeicherten MQTT-Topics." }
        return "Gespeicherte Topics:\n" + topics.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private func findMosquitto(_ name: String) -> String? {
        let paths = ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

#elseif os(Linux)
import Foundation

public struct MQTTTool: Tool {
    public let name = "mqtt"
    public let description = "MQTT (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .medium
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "MQTT ist auf Linux deaktiviert." }
}
#endif
