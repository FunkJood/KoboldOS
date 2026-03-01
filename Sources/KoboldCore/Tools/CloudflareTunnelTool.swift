#if os(macOS)
import Foundation

// MARK: - CloudflareTunnelTool (Named Tunnel via Cloudflare API — no browser login needed)

public struct CloudflareTunnelTool: Tool, @unchecked Sendable {
    public let name = "cloudflare_tunnel"
    public let description = "Cloudflare Tunnel verwalten: permanente HTTPS-URL für KoboldOS einrichten. Tunnel erstellen (create), DNS konfigurieren (setup_dns), Tunnel starten/stoppen (start/stop), Status prüfen (status), Tunnel löschen (delete), Zonen auflisten (list_zones), Tunnel auflisten (list_tunnels)"
    public let riskLevel: RiskLevel = .high

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "create | setup_dns | start | stop | status | delete | list_zones | list_tunnels", required: true),
            "tunnel_name": ToolSchemaProperty(type: "string", description: "Name für den Tunnel (z.B. 'koboldos') — für create"),
            "subdomain": ToolSchemaProperty(type: "string", description: "Subdomain (z.B. 'kobold') — für setup_dns. Wird mit Zone-Domain kombiniert."),
            "target_port": ToolSchemaProperty(type: "string", description: "Lokaler Port (Standard: 8090 für WebUI, 8080 für Daemon API)"),
            "tunnel_id": ToolSchemaProperty(type: "string", description: "Tunnel-ID — für delete. Ohne = aktiver Tunnel."),
        ], required: ["action"])
    }

    public init() {}

    // MARK: - Credential Helpers

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.apiKey") ?? ""
    }
    private var email: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.email") ?? ""
    }
    private var accountId: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.accountId") ?? ""
    }
    private var zoneId: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.zoneId") ?? ""
    }
    private var storedTunnelId: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.tunnelId") ?? ""
    }
    private var storedTunnelToken: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.tunnelToken") ?? ""
    }
    private var storedTunnelUrl: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.tunnelUrl") ?? ""
    }
    private var storedDomain: String {
        UserDefaults.standard.string(forKey: "kobold.cloudflare.domain") ?? ""
    }

    private func checkCredentials() -> String? {
        if apiKey.isEmpty { return "Error: Kein Cloudflare API-Key konfiguriert. Bitte unter Einstellungen → Integrationen → Cloudflare eintragen." }
        if email.isEmpty { return "Error: Keine Cloudflare E-Mail konfiguriert." }
        if accountId.isEmpty { return "Error: Keine Cloudflare Account-ID konfiguriert." }
        return nil
    }

    // MARK: - Execute

    public func execute(arguments: [String: String]) async throws -> String {
        switch arguments["action"] ?? "" {
        case "status": return await tunnelStatus()
        case "create": return await createTunnel(arguments)
        case "setup_dns": return await setupDNS(arguments)
        case "start": return await startTunnel(arguments)
        case "stop": return stopTunnel()
        case "delete": return await deleteTunnel(arguments)
        case "list_zones": return await listZones()
        case "list_tunnels": return await listTunnels()
        default: return "Unbekannte Aktion. Verfügbar: create, setup_dns, start, stop, status, delete, list_zones, list_tunnels"
        }
    }

    // MARK: - Status

    private func tunnelStatus() async -> String {
        // Check cloudflared installed
        let installed = cloudflaredPath() != nil
        // Check LaunchAgent running
        let launchAgentRunning = isLaunchAgentLoaded()
        // Check stored config
        let hasConfig = !storedTunnelId.isEmpty && !storedTunnelToken.isEmpty
        let url = storedTunnelUrl

        var out = "Cloudflare Tunnel Status:\n\n"
        out += "- cloudflared installiert: \(installed ? "Ja" : "Nein")\n"
        out += "- Tunnel konfiguriert: \(hasConfig ? "Ja" : "Nein")\n"
        if !storedTunnelId.isEmpty {
            out += "- Tunnel-ID: \(storedTunnelId)\n"
        }
        out += "- LaunchAgent aktiv: \(launchAgentRunning ? "Ja" : "Nein")\n"
        if !url.isEmpty {
            out += "- URL: \(url)\n"
        }
        if !storedDomain.isEmpty {
            out += "- Domain: \(storedDomain)\n"
        }

        // If tunnel exists, check Cloudflare API for connections
        if hasConfig, !apiKey.isEmpty, !email.isEmpty {
            if let info = await fetchTunnelInfo(tunnelId: storedTunnelId) {
                out += "- Cloudflare Status: \(info.status)\n"
                out += "- Verbindungen: \(info.connections)\n"
            }
        }

        return out
    }

    // MARK: - Create Tunnel

    private func createTunnel(_ args: [String: String]) async -> String {
        if let err = checkCredentials() { return err }

        let tunnelName = args["tunnel_name"] ?? "koboldos"

        // Generate tunnel secret
        var secretBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes)
        let tunnelSecret = Data(secretBytes).base64EncodedString()

        // Create tunnel via Cloudflare API
        let url = "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel"
        let body: [String: Any] = [
            "name": tunnelName,
            "tunnel_secret": tunnelSecret,
            "config_src": "cloudflare"
        ]

        guard let result = await cloudflareRequest(method: "POST", url: url, body: body) else {
            return "Error: Cloudflare API nicht erreichbar."
        }

        guard let success = result["success"] as? Bool, success,
              let resultData = result["result"] as? [String: Any],
              let tunnelId = resultData["id"] as? String,
              let token = resultData["token"] as? String else {
            let errors = (result["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String }.joined(separator: ", ") ?? "Unbekannter Fehler"
            return "Error: Tunnel konnte nicht erstellt werden — \(errors)"
        }

        // Store tunnel info
        UserDefaults.standard.set(tunnelId, forKey: "kobold.cloudflare.tunnelId")
        UserDefaults.standard.set(token, forKey: "kobold.cloudflare.tunnelToken")
        UserDefaults.standard.set(tunnelName, forKey: "kobold.tunnel.name")

        return "Tunnel '\(tunnelName)' erfolgreich erstellt!\n\nTunnel-ID: \(tunnelId)\n\nNächster Schritt: Nutze action='setup_dns' mit subdomain='kobold' (oder anderem Namen) um eine permanente URL einzurichten. Dann action='start' um den Tunnel zu starten."
    }

    // MARK: - Setup DNS (Ingress + CNAME)

    private func setupDNS(_ args: [String: String]) async -> String {
        if let err = checkCredentials() { return err }
        if zoneId.isEmpty { return "Error: Keine Zone-ID konfiguriert. Bitte unter Einstellungen → Cloudflare eintragen oder action='list_zones' nutzen." }

        let tunnelId = args["tunnel_id"] ?? storedTunnelId
        if tunnelId.isEmpty { return "Error: Kein Tunnel vorhanden. Bitte zuerst action='create' ausführen." }

        let subdomain = args["subdomain"] ?? "kobold"
        let targetPort = Int(args["target_port"] ?? "8090") ?? 8090

        // Step 1: Get domain name from zone
        var domain = storedDomain
        if domain.isEmpty {
            let zoneUrl = "https://api.cloudflare.com/client/v4/zones/\(zoneId)"
            if let zoneResult = await cloudflareRequest(method: "GET", url: zoneUrl),
               let zoneData = zoneResult["result"] as? [String: Any],
               let zoneName = zoneData["name"] as? String {
                domain = zoneName
                UserDefaults.standard.set(domain, forKey: "kobold.cloudflare.domain")
            } else {
                return "Error: Zone-Informationen konnten nicht abgerufen werden."
            }
        }

        let hostname = "\(subdomain).\(domain)"

        // Step 2: Configure tunnel ingress
        let ingressUrl = "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel/\(tunnelId)/configurations"
        let ingressBody: [String: Any] = [
            "config": [
                "ingress": [
                    ["hostname": hostname, "service": "http://localhost:\(targetPort)"],
                    ["service": "http_status:404"]
                ]
            ]
        ]

        guard let ingressResult = await cloudflareRequest(method: "PUT", url: ingressUrl, body: ingressBody),
              let ingressSuccess = ingressResult["success"] as? Bool, ingressSuccess else {
            return "Error: Tunnel-Ingress konnte nicht konfiguriert werden."
        }

        // Step 3: Check if DNS record already exists
        let dnsListUrl = "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records?name=\(hostname)&type=CNAME"
        var dnsRecordExists = false
        if let dnsListResult = await cloudflareRequest(method: "GET", url: dnsListUrl),
           let dnsResults = dnsListResult["result"] as? [[String: Any]] {
            dnsRecordExists = !dnsResults.isEmpty
            // Update existing record if content differs
            if let existing = dnsResults.first,
               let recordId = existing["id"] as? String,
               let content = existing["content"] as? String,
               content != "\(tunnelId).cfargotunnel.com" {
                let updateUrl = "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records/\(recordId)"
                let updateBody: [String: Any] = [
                    "type": "CNAME",
                    "name": subdomain,
                    "content": "\(tunnelId).cfargotunnel.com",
                    "proxied": true,
                    "ttl": 1
                ]
                _ = await cloudflareRequest(method: "PUT", url: updateUrl, body: updateBody)
            }
        }

        // Step 4: Create DNS record if not exists
        if !dnsRecordExists {
            let dnsUrl = "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records"
            let dnsBody: [String: Any] = [
                "type": "CNAME",
                "name": subdomain,
                "content": "\(tunnelId).cfargotunnel.com",
                "proxied": true,
                "ttl": 1
            ]

            guard let dnsResult = await cloudflareRequest(method: "POST", url: dnsUrl, body: dnsBody),
                  let dnsSuccess = dnsResult["success"] as? Bool, dnsSuccess else {
                return "Error: DNS-Eintrag konnte nicht erstellt werden. Ingress wurde konfiguriert."
            }
        }

        // Store the URL
        let tunnelUrl = "https://\(hostname)"
        UserDefaults.standard.set(tunnelUrl, forKey: "kobold.cloudflare.tunnelUrl")

        return "DNS konfiguriert!\n\nURL: \(tunnelUrl)\nIngress: localhost:\(targetPort)\n\(dnsRecordExists ? "DNS-Eintrag aktualisiert." : "DNS-Eintrag erstellt.")\n\nNächster Schritt: Nutze action='start' um den Tunnel zu starten."
    }

    // MARK: - Start Tunnel (LaunchAgent)

    private func startTunnel(_ args: [String: String]) async -> String {
        let token = storedTunnelToken
        if token.isEmpty { return "Error: Kein Tunnel-Token vorhanden. Bitte zuerst action='create' ausführen." }

        guard let binary = cloudflaredPath() else {
            return "Error: cloudflared nicht installiert. Bitte mit Homebrew installieren: brew install cloudflared"
        }

        let plistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.cloudflare.koboldos-tunnel.plist")
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/cloudflared-koboldos.log")

        // Write LaunchAgent plist
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.cloudflare.koboldos-tunnel</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>tunnel</string>
                <string>--no-autoupdate</string>
                <string>run</string>
                <string>--token</string>
                <string>\(token)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
            <key>ThrottleInterval</key>
            <integer>10</integer>
        </dict>
        </plist>
        """

        do {
            // Unload if already loaded
            if isLaunchAgentLoaded() {
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["unload", plistPath]
                try? unload.run()
                unload.waitUntilExit()
            }

            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

            // Load LaunchAgent
            let load = Process()
            load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            load.arguments = ["load", plistPath]
            try load.run()
            load.waitUntilExit()

            if load.terminationStatus != 0 {
                return "Error: LaunchAgent konnte nicht geladen werden (Exit-Code: \(load.terminationStatus))."
            }

            // Wait briefly and verify
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let running = isLaunchAgentLoaded()

            var out = "Tunnel gestartet!\n\n"
            out += "- LaunchAgent: \(running ? "Aktiv" : "Unbekannt")\n"
            out += "- Auto-Start bei Login: Ja (KeepAlive)\n"
            out += "- Log: ~/Library/Logs/cloudflared-koboldos.log\n"
            if !storedTunnelUrl.isEmpty {
                out += "- URL: \(storedTunnelUrl)\n"
            }
            return out
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Stop Tunnel

    private func stopTunnel() -> String {
        let plistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.cloudflare.koboldos-tunnel.plist")

        guard FileManager.default.fileExists(atPath: plistPath) else {
            return "Kein LaunchAgent installiert — Tunnel ist bereits gestoppt."
        }

        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plistPath]
        try? unload.run()
        unload.waitUntilExit()

        // Remove plist
        try? FileManager.default.removeItem(atPath: plistPath)

        return "Tunnel gestoppt und LaunchAgent entfernt.\n\nDer Tunnel kann jederzeit mit action='start' wieder gestartet werden."
    }

    // MARK: - Delete Tunnel

    private func deleteTunnel(_ args: [String: String]) async -> String {
        if let err = checkCredentials() { return err }

        let tunnelId = args["tunnel_id"] ?? storedTunnelId
        if tunnelId.isEmpty { return "Error: Keine Tunnel-ID angegeben und kein aktiver Tunnel vorhanden." }

        // Stop first
        _ = stopTunnel()

        // Delete DNS records pointing to this tunnel
        if !zoneId.isEmpty {
            let tunnelCname = "\(tunnelId).cfargotunnel.com"
            let dnsListUrl = "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records?type=CNAME&content=\(tunnelCname)"
            if let dnsResult = await cloudflareRequest(method: "GET", url: dnsListUrl),
               let records = dnsResult["result"] as? [[String: Any]] {
                for record in records {
                    if let recordId = record["id"] as? String {
                        let deleteUrl = "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records/\(recordId)"
                        _ = await cloudflareRequest(method: "DELETE", url: deleteUrl)
                    }
                }
            }
        }

        // Delete tunnel via API
        // Must clean up connections first
        let cleanUrl = "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel/\(tunnelId)/connections"
        _ = await cloudflareRequest(method: "DELETE", url: cleanUrl)

        let deleteUrl = "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel/\(tunnelId)"
        guard let result = await cloudflareRequest(method: "DELETE", url: deleteUrl),
              let success = result["success"] as? Bool, success else {
            return "Error: Tunnel konnte nicht gelöscht werden. Eventuell manuell im Cloudflare Dashboard löschen."
        }

        // Clear stored config
        UserDefaults.standard.removeObject(forKey: "kobold.cloudflare.tunnelId")
        UserDefaults.standard.removeObject(forKey: "kobold.cloudflare.tunnelToken")
        UserDefaults.standard.removeObject(forKey: "kobold.cloudflare.tunnelUrl")
        UserDefaults.standard.removeObject(forKey: "kobold.tunnel.name")

        return "Tunnel '\(tunnelId)' gelöscht.\n\n- DNS-Einträge entfernt\n- LaunchAgent entfernt\n- Lokale Konfiguration bereinigt"
    }

    // MARK: - List Zones

    private func listZones() async -> String {
        if apiKey.isEmpty || email.isEmpty { return "Error: Cloudflare API-Key und E-Mail erforderlich." }

        let url = "https://api.cloudflare.com/client/v4/zones?per_page=50"
        guard let result = await cloudflareRequest(method: "GET", url: url),
              let zones = result["result"] as? [[String: Any]] else {
            return "Error: Zonen konnten nicht abgerufen werden."
        }

        if zones.isEmpty { return "Keine Zonen gefunden. Bitte eine Domain in Cloudflare hinzufügen." }

        var out = "Verfügbare Cloudflare-Zonen (\(zones.count)):\n\n"
        for zone in zones {
            let name = zone["name"] as? String ?? "?"
            let id = zone["id"] as? String ?? "?"
            let status = zone["status"] as? String ?? "?"
            let plan = (zone["plan"] as? [String: Any])?["name"] as? String ?? ""
            out += "- \(name) [ID: \(id)] Status: \(status) (\(plan))\n"
        }
        out += "\nTrage die gewünschte Zone-ID in den Einstellungen ein oder teile sie mir mit."
        return out
    }

    // MARK: - List Tunnels

    private func listTunnels() async -> String {
        if let err = checkCredentials() { return err }

        let url = "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel?is_deleted=false&per_page=20"
        guard let result = await cloudflareRequest(method: "GET", url: url),
              let tunnels = result["result"] as? [[String: Any]] else {
            return "Error: Tunnel konnten nicht abgerufen werden."
        }

        if tunnels.isEmpty { return "Keine Tunnel vorhanden. Erstelle einen mit action='create'." }

        var out = "Cloudflare Tunnel (\(tunnels.count)):\n\n"
        for tunnel in tunnels {
            let name = tunnel["name"] as? String ?? "?"
            let id = tunnel["id"] as? String ?? "?"
            let status = tunnel["status"] as? String ?? "?"
            let connections = tunnel["connections"] as? [[String: Any]] ?? []
            let connInfo = connections.isEmpty ? "keine Verbindungen" : "\(connections.count) Verbindung(en)"
            let isActive = id == storedTunnelId ? " ← aktiv" : ""
            out += "- \(name) [ID: \(id)] \(status) (\(connInfo))\(isActive)\n"
        }
        return out
    }

    // MARK: - API Helper

    private func cloudflareRequest(method: String, url urlString: String, body: [String: Any]? = nil) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(email, forHTTPHeaderField: "X-Auth-Email")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    // MARK: - Tunnel Info

    private struct TunnelInfo {
        let status: String
        let connections: String
    }

    private func fetchTunnelInfo(tunnelId: String) async -> TunnelInfo? {
        let url = "https://api.cloudflare.com/client/v4/accounts/\(accountId)/cfd_tunnel/\(tunnelId)"
        guard let result = await cloudflareRequest(method: "GET", url: url),
              let data = result["result"] as? [String: Any] else { return nil }

        let status = data["status"] as? String ?? "unknown"
        let connections = data["connections"] as? [[String: Any]] ?? []
        let connDetails = connections.compactMap { conn -> String? in
            guard let loc = conn["colo_name"] as? String else { return nil }
            return loc
        }
        let connStr = connDetails.isEmpty ? "0" : "\(connDetails.count) (\(connDetails.joined(separator: ", ")))"
        return TunnelInfo(status: status, connections: connStr)
    }

    // MARK: - Helpers

    private func cloudflaredPath() -> String? {
        let paths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func isLaunchAgentLoaded() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("com.cloudflare.koboldos-tunnel")
    }
}

#elseif os(Linux)
import Foundation

public struct CloudflareTunnelTool: Tool, Sendable {
    public let name = "cloudflare_tunnel"
    public let description = "Cloudflare Tunnel (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .high
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func execute(arguments: [String: String]) async throws -> String { "Cloudflare Tunnel ist auf Linux deaktiviert." }
}
#endif
