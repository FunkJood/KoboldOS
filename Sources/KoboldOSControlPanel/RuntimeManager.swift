import Foundation
import SwiftUI
import Combine
import KoboldCore

// MARK: - BackendConfig

struct BackendConfig: Sendable {
    var port: Int = 8080
    var authToken: String = "kobold-secret"
    var ollamaURL: String = "http://localhost:11434"
}

// MARK: - RuntimeManager
// Runs the KoboldCore DaemonListener IN-PROCESS — no subprocess required.
// This makes the app fully self-contained and distributable.

@MainActor
class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    @Published var healthStatus: String = "Starting"
    @Published var daemonPID: Int? = nil
    @Published var showErrorAlert: Bool = false
    @Published var errorMessage: String? = nil

    @AppStorage("kobold.port") var port: Int = 8080
    @AppStorage("kobold.authToken") var authToken: String = "kobold-secret"

    private var daemonTask: Task<Void, Never>? = nil
    /// B2: Stored reference für graceful shutdown
    private var daemonInstance: DaemonListener?
    private var healthTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var didPlayBootSound = false

    private init() {
        startHealthMonitor()
        setupTunnelListener()
        setupTunnelRequestListener()
        autoStartTunnelIfNeeded()
        syncElevenLabsOnStartup()
    }

    /// Call on app termination to prevent timer leak
    func cleanup() {
        healthTimer?.invalidate()
        healthTimer = nil
        daemonTask?.cancel()
        // B2: DaemonListener graceful stop
        if let daemon = daemonInstance {
            Task { await daemon.stop() }
        }
    }

    var baseURL: String { "http://localhost:\(port)" }

    // MARK: - In-Process Daemon

    func startDaemon() {
        guard daemonTask == nil else { return }

        let listenPort = port
        let token = authToken  // @AppStorage — same source as RuntimeViewModel

        // STT-Handler registrieren damit Twilio Voice auf Whisper zugreifen kann
        DaemonListener.sttHandler = { url in
            await STTManager.shared.transcribe(audioURL: url)
        }

        let daemon = DaemonListener(port: listenPort, authToken: token)
        daemonInstance = daemon
        daemonTask = Task.detached(priority: .userInitiated) {
            await daemon.start()
        }

        daemonPID = Int(ProcessInfo.processInfo.processIdentifier)
        healthStatus = "Starting"
        print("[RuntimeManager] DaemonListener started in-process on port \(port)")
    }

    func stopDaemon() {
        daemonTask?.cancel()
        daemonTask = nil
        daemonPID = nil
        healthStatus = "Stopped"
    }

    func retryConnection() {
        showErrorAlert = false
        stopDaemon()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            startDaemon()
        }
    }

    // MARK: - Cloudflare Tunnel → Twilio Auto-Sync

    /// Wenn ein Cloudflare-Tunnel gestartet wird, automatisch die URL für Twilio + andere Tools setzen
    private func setupTunnelListener() {
        // Named Tunnel: Beim App-Start sofort die gespeicherte URL nutzen (LaunchAgent läuft unabhängig)
        let namedTunnelUrl = UserDefaults.standard.string(forKey: "kobold.cloudflare.tunnelUrl") ?? ""
        if !namedTunnelUrl.isEmpty {
            applyTunnelURL(namedTunnelUrl, source: "Named Tunnel")
        }

        // Quick Tunnel: Dynamische URL bei Start empfangen
        NotificationCenter.default.publisher(for: Notification.Name("koboldTunnelURLReady"))
            .compactMap { $0.object as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] tunnelURL in
                guard self != nil else { return }
                self?.applyTunnelURL(tunnelURL, source: "Quick Tunnel")
            }
            .store(in: &cancellables)
    }

    /// Setzt die Tunnel-URL für Twilio, ElevenLabs etc.
    /// Named Tunnel hat Vorrang vor Quick Tunnel URLs.
    private func applyTunnelURL(_ tunnelURL: String, source: String) {
        let namedUrl = UserDefaults.standard.string(forKey: "kobold.cloudflare.tunnelUrl") ?? ""
        let currentPublicUrl = UserDefaults.standard.string(forKey: "kobold.twilio.publicUrl") ?? ""

        // Named Tunnel hat immer Vorrang — Quick Tunnel überschreibt Named Tunnel NICHT
        if source == "Quick Tunnel" && !namedUrl.isEmpty && !currentPublicUrl.contains("trycloudflare.com") {
            // Named Tunnel konfiguriert und Twilio nutzt ihn schon → Quick Tunnel ignorieren
            return
        }

        // Tunnel-URL global speichern
        UserDefaults.standard.set(tunnelURL, forKey: "kobold.tunnel.url")

        // Twilio Public URL setzen wenn leer oder alte dynamische URL
        if currentPublicUrl.isEmpty
            || currentPublicUrl.contains("ngrok")
            || currentPublicUrl.contains("trycloudflare.com") {
            UserDefaults.standard.set(tunnelURL, forKey: "kobold.twilio.publicUrl")
            print("[RuntimeManager] \(source) URL für Twilio gesetzt: \(tunnelURL)")
        }

        // Twilio Webhook-URLs aktualisieren
        Task { await Self.updateTwilioWebhooks(publicUrl: tunnelURL) }
        // ElevenLabs Agent-Config synchen
        Task { await Self.syncElevenLabsAgentConfig(publicUrl: tunnelURL) }
    }

    /// Aktualisiert die Twilio-Webhook-URLs automatisch wenn sich die Tunnel-URL ändert
    private static func updateTwilioWebhooks(publicUrl: String) async {
        let accountSid = UserDefaults.standard.string(forKey: "kobold.twilio.accountSid") ?? ""
        let authToken = UserDefaults.standard.string(forKey: "kobold.twilio.authToken") ?? ""
        let fromNumber = UserDefaults.standard.string(forKey: "kobold.twilio.fromNumber") ?? ""
        guard !accountSid.isEmpty, !authToken.isEmpty, !fromNumber.isEmpty else { return }

        // Step 1: Phone Number SID nachschlagen
        let encodedNumber = fromNumber.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fromNumber
        guard let lookupURL = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/IncomingPhoneNumbers.json?PhoneNumber=\(encodedNumber)") else { return }

        var lookupReq = URLRequest(url: lookupURL)
        let credentials = Data("\(accountSid):\(authToken)".utf8).base64EncodedString()
        lookupReq.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: lookupReq)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let numbers = json["incoming_phone_numbers"] as? [[String: Any]],
                  let first = numbers.first,
                  let phoneSid = first["sid"] as? String else {
                print("[Twilio Auto-Update] Keine Nummer gefunden für \(fromNumber)")
                return
            }

            // Step 2: Webhook-URLs aktualisieren
            let voiceUrl = publicUrl.hasSuffix("/") ? "\(publicUrl)twilio/voice/webhook" : "\(publicUrl)/twilio/voice/webhook"
            let smsUrl = publicUrl.hasSuffix("/") ? "\(publicUrl)twilio/sms/webhook" : "\(publicUrl)/twilio/sms/webhook"

            guard let updateURL = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/IncomingPhoneNumbers/\(phoneSid).json") else { return }
            var updateReq = URLRequest(url: updateURL)
            updateReq.httpMethod = "POST"
            updateReq.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            updateReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = [
                "VoiceUrl=\(voiceUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? voiceUrl)",
                "VoiceMethod=POST",
                "SmsUrl=\(smsUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? smsUrl)",
                "SmsMethod=POST"
            ].joined(separator: "&")
            updateReq.httpBody = body.data(using: .utf8)

            let (_, response) = try await URLSession.shared.data(for: updateReq)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                print("[Twilio Auto-Update] Webhooks aktualisiert → \(voiceUrl)")
            } else {
                print("[Twilio Auto-Update] Fehler: HTTP \(status)")
            }
        } catch {
            print("[Twilio Auto-Update] Fehler: \(error.localizedDescription)")
        }
    }

    /// Synct KoboldOS-Persönlichkeit + Konfiguration zum ElevenLabs ConvAI Agent.
    /// Funktioniert in BEIDEN Modi:
    ///  - Custom LLM AUS → Nur Prompt/FirstMessage/Sprache synchen, ElevenLabs behält eigenes LLM
    ///  - Custom LLM AN  → Zusätzlich Ollama als LLM über Tunnel-URL setzen
    /// Wird bei Tunnel-URL-Änderung UND App-Start aufgerufen.
    static func syncElevenLabsAgentConfig(publicUrl: String? = nil) async {
        let d = UserDefaults.standard
        let agentId = d.string(forKey: "kobold.elevenlabs.convai.agentId") ?? ""
        let apiKey = d.string(forKey: "kobold.elevenlabs.apiKey") ?? ""
        guard !agentId.isEmpty, !apiKey.isEmpty else {
            print("[ElevenLabs Sync] Übersprungen: Agent-ID=\(agentId.isEmpty ? "LEER" : "OK"), API-Key=\(apiKey.isEmpty ? "LEER" : "OK")")
            return
        }

        // --- Persönlichkeits-Prompt aus KoboldOS-Einstellungen bauen ---
        let soul = d.string(forKey: "kobold.agent.soul") ?? ""
        let personality = d.string(forKey: "kobold.agent.personality") ?? ""
        let tone = d.string(forKey: "kobold.agent.tone") ?? "freundlich"
        let agentLang = d.string(forKey: "kobold.agent.language") ?? "deutsch"
        let userName = d.string(forKey: "kobold.user.name") ?? ""
        let agentName = d.string(forKey: "kobold.agent.name") ?? "Kobold"
        let hasPersonality = !soul.isEmpty || !personality.isEmpty

        // Prompt nur bauen wenn soul/personality in KoboldOS konfiguriert — sonst ElevenLabs-Prompt in Ruhe lassen
        var systemPrompt: String? = nil
        if hasPersonality {
            var p = "Du bist \(agentName), ein KI-Assistent"
            if !userName.isEmpty { p += " von \(userName)" }
            p += ".\n\n"
            if !soul.isEmpty { p += "## Identität\n\(soul)\n\n" }
            if !personality.isEmpty { p += "## Persönlichkeit\n\(personality)\n\n" }
            p += "## Verhalten am Telefon\n"
            p += "- Sprache: \(agentLang.capitalized)\n"
            p += "- Tonfall: \(tone)\n"
            p += "- Sei natürlich, höflich und zielorientiert\n"
            p += "- Fasse dich kurz — Telefongespräche sollen effizient sein\n"
            p += "- Stelle sicher, dass du alle nötigen Informationen erhältst\n"
            p += "- Wiederhole wichtige Details zur Bestätigung\n"
            p += "- Wenn die Aufgabe erledigt ist, fasse das Ergebnis kurz zusammen und verabschiede dich freundlich"
            systemPrompt = p
        }

        // Begrüßung
        var firstMessage = "Hallo! Hier spricht \(agentName)"
        if !userName.isEmpty { firstMessage += " von \(userName)" }
        firstMessage += ". Wie kann ich Ihnen helfen?"

        // Sprachcode für ElevenLabs (de, en, etc.)
        let langCode: String
        switch agentLang.lowercased() {
        case "deutsch", "german", "de": langCode = "de"
        case "englisch", "english", "en": langCode = "en"
        case "französisch", "french", "fr": langCode = "fr"
        case "spanisch", "spanish", "es": langCode = "es"
        default: langCode = "de"
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentId)") else { return }

        // --- Payload bauen ---
        let useCustomLLM = d.bool(forKey: "kobold.elevenlabs.convai.customLLM")
        var promptDict: [String: Any] = [:]
        if let prompt = systemPrompt {
            promptDict["prompt"] = prompt
        }

        if useCustomLLM, let tunnelUrl = publicUrl ?? d.string(forKey: "kobold.tunnel.url"), !tunnelUrl.isEmpty {
            let llmUrl = tunnelUrl.hasSuffix("/") ? "\(tunnelUrl)v1" : "\(tunnelUrl)/v1"
            let koboldToken = d.string(forKey: "kobold.authToken") ?? "kobold-secret"
            promptDict["llm"] = "custom-llm"
            promptDict["custom_llm"] = [
                "url": llmUrl,
                "model_id": d.string(forKey: "kobold.ollamaModel") ?? "llama3",
                "request_headers": ["Authorization": "Bearer \(koboldToken)"],
                "api_type": "chat_completions"
            ] as [String: Any]
            print("[ElevenLabs Sync] Modus: Custom LLM → \(llmUrl)")
        } else {
            print("[ElevenLabs Sync] Modus: ElevenLabs eigenes LLM (Prompt: \(hasPersonality ? "sync" : "beibehalten"))")
        }

        // Nichts zu synchen? → Skip (kein Prompt, kein Custom LLM)
        guard hasPersonality || !promptDict.isEmpty else {
            print("[ElevenLabs Sync] Übersprungen: Keine Persönlichkeit konfiguriert & kein Custom LLM aktiv")
            return
        }

        // Agent-Dict: first_message + language nur wenn Persönlichkeit vorhanden, prompt nur wenn gebaut
        var agentDict: [String: Any] = ["language": langCode]
        if hasPersonality {
            agentDict["first_message"] = firstMessage
        }
        if !promptDict.isEmpty {
            agentDict["prompt"] = promptDict
        }

        let payload: [String: Any] = [
            "conversation_config": [
                "agent": agentDict
            ] as [String: Any]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[ElevenLabs Sync] Fehler: JSON-Serialisierung fehlgeschlagen")
            return
        }

        print("[ElevenLabs Sync] PATCH → Agent \(agentId.prefix(12))..., Prompt: \(systemPrompt?.prefix(60) ?? "beibehalten"), Lang: \(langCode)")

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.httpBody = bodyData
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                print("[ElevenLabs Sync] ✅ Agent-Persönlichkeit aktualisiert (Sprache: \(langCode), Custom-LLM: \(useCustomLLM ? "AN" : "AUS"))")
                await deployElevenLabsAgent(agentId: agentId, apiKey: apiKey)
            } else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                print("[ElevenLabs Sync] ❌ HTTP \(status) — \(body)")
            }
        } catch {
            print("[ElevenLabs Sync] ❌ Netzwerk-Fehler: \(error.localizedDescription)")
        }
    }

    /// Deployed den ElevenLabs Agent damit PATCH-Änderungen live gehen.
    /// Holt branch_id via GET, dann POST /deployments mit 100% Traffic.
    private static func deployElevenLabsAgent(agentId: String, apiKey: String) async {
        // Step 1: Agent abrufen → branch_id finden
        guard let getUrl = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentId)") else { return }
        var getReq = URLRequest(url: getUrl)
        getReq.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        getReq.timeoutInterval = 10

        do {
            let (getData, getResp) = try await URLSession.shared.data(for: getReq)
            guard (getResp as? HTTPURLResponse)?.statusCode == 200,
                  let agentJson = try? JSONSerialization.jsonObject(with: getData) as? [String: Any] else {
                print("[ElevenLabs Deploy] ❌ Agent-GET fehlgeschlagen")
                return
            }

            // branch_id aus Agent-Config extrahieren
            guard let branchId = agentJson["branch_id"] as? String, !branchId.isEmpty else {
                print("[ElevenLabs Deploy] Kein branch_id gefunden — Agent hat möglicherweise kein Branching aktiviert")
                return
            }

            // Step 2: Deployment erstellen mit 100% Traffic
            guard let deployUrl = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentId)/deployments") else { return }

            let deployPayload: [String: Any] = [
                "deployment_request": [
                    "requests": [
                        [
                            "branch_id": branchId,
                            "deployment_strategy": [
                                "type": "percentage",
                                "traffic_percentage": 1.0
                            ] as [String: Any]
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ]

            guard let deployBody = try? JSONSerialization.data(withJSONObject: deployPayload) else { return }

            var deployReq = URLRequest(url: deployUrl)
            deployReq.httpMethod = "POST"
            deployReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            deployReq.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            deployReq.httpBody = deployBody
            deployReq.timeoutInterval = 10

            let (_, deployResp) = try await URLSession.shared.data(for: deployReq)
            let deployStatus = (deployResp as? HTTPURLResponse)?.statusCode ?? 0
            if deployStatus == 200 {
                print("[ElevenLabs Deploy] ✅ Agent veröffentlicht (branch: \(branchId.prefix(16))...)")
            } else {
                print("[ElevenLabs Deploy] ⚠️ HTTP \(deployStatus) — Änderungen möglicherweise nur im Draft")
            }
        } catch {
            print("[ElevenLabs Deploy] ❌ Fehler: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-Tunnel bei Tool-Anforderung

    /// Empfängt Tunnel-Start-Anforderung von KoboldCore Tools (z.B. TwilioVoiceCallTool)
    private func setupTunnelRequestListener() {
        NotificationCenter.default.publisher(for: Notification.Name("koboldRequestTunnelStart"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self != nil else { return }
                // Nur starten wenn noch kein Tunnel läuft und WebApp-Server aktiv
                guard !WebAppServer.shared.isTunnelRunning else { return }
                guard WebAppServer.isCloudflaredInstalled() else { return }
                let webAppPort = UserDefaults.standard.integer(forKey: "kobold.webapp.port")
                let port = webAppPort > 0 ? webAppPort : 8080
                WebAppServer.shared.startTunnel(localPort: port)
            }
            .store(in: &cancellables)
    }

    /// Bei App-Start automatisch Tunnel starten wenn Toggle aktiviert ist.
    /// Wartet bis der Daemon tatsächlich erreichbar ist (healthStatus == "OK").
    private func autoStartTunnelIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "kobold.tunnel.autoStart") else { return }
        guard WebAppServer.isCloudflaredInstalled() else { return }
        // Auf Daemon-Bereitschaft warten statt blindem Timer
        $healthStatus
            .first { $0 == "OK" }
            .sink { [weak self] _ in
                guard let self, !WebAppServer.shared.isTunnelRunning else { return }
                let webAppPort = UserDefaults.standard.integer(forKey: "kobold.webapp.port")
                let port = webAppPort > 0 ? webAppPort : 8080
                WebAppServer.shared.startTunnel(localPort: port)
                print("[RuntimeManager] Auto-Start Tunnel nach Daemon-Ready auf Port \(port)")
            }
            .store(in: &cancellables)
    }

    /// ElevenLabs Agent-Persönlichkeit bei App-Start synchen (nach Daemon-Bereitschaft).
    /// Kein Tunnel nötig — synct Prompt, Begrüßung und Sprache direkt via ElevenLabs API.
    private func syncElevenLabsOnStartup() {
        $healthStatus
            .first { $0 == "OK" }
            .sink { _ in
                Task { await Self.syncElevenLabsAgentConfig() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Health Monitor

    private func startHealthMonitor() {
        // Reduced: 15s instead of 5s — RuntimeViewModel.checkConnectivity() already pings every 5s
        // Having two 5s timers doubled the network overhead for no benefit
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pingHealth()
            }
        }
    }

    private func pingHealth() async {
        guard let url = URL(string: baseURL + "/health") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                healthStatus = "Error"; return
            }
            // Verify the responding daemon belongs to OUR process
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = json["pid"] as? Int,
               pid != Int(ProcessInfo.processInfo.processIdentifier) {
                // A DIFFERENT process (old instance) is on port 8080
                print("⚠️ Port \(port) occupied by PID \(pid), ours is \(ProcessInfo.processInfo.processIdentifier) — restarting daemon")
                healthStatus = "Stale"
                // Kill old process and restart our daemon
                kill(pid_t(pid), SIGTERM)
                stopDaemon()
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    startDaemon()
                }
                return
            }
            healthStatus = "OK"
            if !didPlayBootSound {
                didPlayBootSound = true
                SoundManager.shared.play(.boot)
            }
        } catch {
            if daemonTask != nil {
                if healthStatus == "Starting" { return }
                healthStatus = "Unreachable"
            }
        }
    }
}
