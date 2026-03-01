#if os(macOS)
import Foundation

// MARK: - Twilio Voice Call Tool (AccountSID + AuthToken)
public struct TwilioVoiceCallTool: Tool {
    public let name = "phone_call"
    public let description = "Telefonanruf tätigen oder beenden über Twilio. Nutzt automatisch den Cloudflare-Tunnel wenn aktiv."
    public let riskLevel: RiskLevel = .critical

    public var schema: ToolSchema {
        ToolSchema(properties: [
            "action": ToolSchemaProperty(type: "string", description: "Aktion: call (Anruf starten) oder hangup (Anruf beenden)", enumValues: ["call", "hangup"], required: true),
            "to": ToolSchemaProperty(type: "string", description: "Ziel-Telefonnummer im E.164 Format, z.B. +491701234567 (Pflicht bei call)"),
            "purpose": ToolSchemaProperty(type: "string", description: "Zweck des Anrufs, z.B. 'Termin beim Friseur buchen' (Pflicht bei call)"),
            "call_sid": ToolSchemaProperty(type: "string", description: "Call-SID des laufenden Anrufs (Pflicht bei hangup)")
        ], required: ["action"])
    }

    public init() {}

    /// Robuste Argument-Auflösung: LLMs verwechseln häufig Parameter-Namen.
    /// Akzeptiert gängige Synonyme und normalisiert sie.
    private func resolveArgs(_ arguments: [String: String]) -> [String: String] {
        var resolved = arguments

        // action: Default "call" wenn fehlend (99% der Aufrufe)
        if resolved["action"] == nil || resolved["action"]?.isEmpty == true {
            // Versuche Synonyme
            let actionAliases = ["type", "command", "mode"]
            for alias in actionAliases {
                if let val = resolved[alias], !val.isEmpty {
                    resolved["action"] = val
                    break
                }
            }
            // Immer noch leer? Default "call"
            if resolved["action"] == nil || resolved["action"]?.isEmpty == true {
                resolved["action"] = "call"
            }
        }

        // purpose: Akzeptiere Synonyme die LLMs häufig verwenden
        if resolved["purpose"] == nil || resolved["purpose"]?.isEmpty == true {
            let purposeAliases = ["script", "reason", "message", "text", "goal", "task", "description", "zweck", "grund"]
            for alias in purposeAliases {
                if let val = resolved[alias], !val.isEmpty {
                    resolved["purpose"] = val
                    break
                }
            }
        }

        // to: Akzeptiere Synonyme für Telefonnummer
        if resolved["to"] == nil || resolved["to"]?.isEmpty == true {
            let toAliases = ["number", "phone", "phone_number", "nummer", "telefon"]
            for alias in toAliases {
                if let val = resolved[alias], !val.isEmpty {
                    resolved["to"] = val
                    break
                }
            }
        }

        // call_sid: Akzeptiere Synonyme
        if resolved["call_sid"] == nil || resolved["call_sid"]?.isEmpty == true {
            let sidAliases = ["callSid", "sid", "call_id", "callId"]
            for alias in sidAliases {
                if let val = resolved[alias], !val.isEmpty {
                    resolved["call_sid"] = val
                    break
                }
            }
        }

        return resolved
    }

    public func validate(arguments: [String: String]) throws {
        let args = resolveArgs(arguments)
        let action = args["action"] ?? "call"
        if action == "call" {
            guard let to = args["to"], !to.isEmpty else {
                throw ToolError.missingRequired("to")
            }
            _ = to
            // purpose ist jetzt optional — Default-Wert wenn fehlend
        } else if action == "hangup" {
            guard let callSid = args["call_sid"], !callSid.isEmpty else {
                throw ToolError.missingRequired("call_sid")
            }
            _ = callSid
        }
    }

    public func execute(arguments: [String: String]) async throws -> String {
        let args = resolveArgs(arguments)
        let action = args["action"] ?? "call"

        let d = UserDefaults.standard
        let accountSid = d.string(forKey: "kobold.twilio.accountSid") ?? ""
        let authToken = d.string(forKey: "kobold.twilio.authToken") ?? ""
        let defaultFrom = d.string(forKey: "kobold.twilio.fromNumber") ?? ""
        // Cloudflare Tunnel-URL als Fallback wenn keine explizite Public URL gesetzt
        let explicitUrl = d.string(forKey: "kobold.twilio.publicUrl") ?? ""
        let tunnelUrl = d.string(forKey: "kobold.tunnel.url") ?? ""
        let publicUrl = explicitUrl.isEmpty ? tunnelUrl : explicitUrl

        guard !accountSid.isEmpty, !authToken.isEmpty else {
            return "Error: Twilio nicht konfiguriert. Bitte AccountSID und AuthToken unter Einstellungen → Integrationen → Twilio eintragen."
        }

        let credentials = "\(accountSid):\(authToken)"
        guard let credData = credentials.data(using: .utf8) else {
            return "Error: Authentifizierung fehlgeschlagen"
        }
        let authHeader = "Basic \(credData.base64EncodedString())"

        switch action {
        case "call":
            return await executeCall(
                accountSid: accountSid,
                authHeader: authHeader,
                to: args["to"] ?? "",
                from: defaultFrom,
                purpose: args["purpose"] ?? "Anruf",
                publicUrl: publicUrl
            )
        case "hangup":
            return await executeHangup(
                accountSid: accountSid,
                authHeader: authHeader,
                callSid: args["call_sid"] ?? ""
            )
        default:
            return "Error: Unbekannte Aktion '\(action)'. Verwende 'call' oder 'hangup'."
        }
    }

    // MARK: - Anruf starten

    private func executeCall(accountSid: String, authHeader: String, to: String, from: String, purpose: String, publicUrl: String) async -> String {
        guard !to.isEmpty else {
            return "Error: Keine Ziel-Telefonnummer angegeben."
        }
        guard !from.isEmpty else {
            return "Error: Keine Absender-Nummer konfiguriert. Bitte Twilio-Nummer in den Einstellungen setzen."
        }

        // ElevenLabs-Modus: Outbound Call über ElevenLabs ConvAI API
        let voiceMode = UserDefaults.standard.string(forKey: "kobold.twilio.voiceMode") ?? "native"
        if voiceMode == "elevenlabs" {
            let result = await executeElevenLabsOutboundCall(to: to, from: from, purpose: purpose)
            if let result { return result }
            // Fallback auf native bei Fehler
        }

        // Auto-Tunnel: Wenn keine URL → Tunnel-Start anfordern und warten
        var resolvedPublicUrl = publicUrl
        if resolvedPublicUrl.isEmpty {
            // Notification an KoboldOSControlPanel senden → startet Cloudflare-Tunnel
            await MainActor.run {
                NotificationCenter.default.post(name: Notification.Name("koboldRequestTunnelStart"), object: nil)
            }

            // Auf Tunnel-URL warten (max 25s, alle 500ms prüfen)
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let freshTunnel = UserDefaults.standard.string(forKey: "kobold.tunnel.url") ?? ""
                let freshExplicit = UserDefaults.standard.string(forKey: "kobold.twilio.publicUrl") ?? ""
                let freshUrl = freshExplicit.isEmpty ? freshTunnel : freshExplicit
                if !freshUrl.isEmpty {
                    resolvedPublicUrl = freshUrl
                    break
                }
            }

            guard !resolvedPublicUrl.isEmpty else {
                return "Error: Cloudflare-Tunnel konnte nicht automatisch gestartet werden. Bitte unter Einstellungen prüfen ob cloudflared installiert ist und der WebApp-Server läuft."
            }
        }

        let webhookUrl = resolvedPublicUrl.hasSuffix("/")
            ? "\(resolvedPublicUrl)twilio/voice/webhook"
            : "\(resolvedPublicUrl)/twilio/voice/webhook"

        // Purpose VORAB speichern damit handleTwilioVoiceWebhook ihn beim Callback abrufen kann
        await TwilioVoiceHandler.shared.setPendingPurpose(toNumber: to, purpose: purpose)
        // Auch in UserDefaults für den ElevenLabs Custom LLM Proxy-Path
        UserDefaults.standard.set(purpose, forKey: "kobold.activeCall.purpose")

        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Calls.json") else {
            return "Error: Ungültige AccountSID"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let bodyParts = [
            "To=\(to.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? to)",
            "From=\(from.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? from)",
            "Url=\(webhookUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? webhookUrl)"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(4096), encoding: .utf8) ?? "(leer)"

            if status >= 400 {
                return "Error: HTTP \(status): \(responseStr)"
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sid"] as? String,
               let callStatus = json["status"] as? String {
                return "Anruf gestartet! SID: \(sid), Status: \(callStatus), An: \(to), Zweck: \(purpose)"
            }
            return "Anruf gestartet an \(to) — Zweck: \(purpose)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Anruf beenden

    private func executeHangup(accountSid: String, authHeader: String, callSid: String) async -> String {
        guard !callSid.isEmpty else {
            return "Error: Keine Call-SID angegeben."
        }

        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Calls/\(callSid).json") else {
            return "Error: Ungültige AccountSID oder Call-SID"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body = "Status=completed"
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data.prefix(4096), encoding: .utf8) ?? "(leer)"

            if status >= 400 {
                return "Error: HTTP \(status): \(responseStr)"
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let callStatus = json["status"] as? String {
                return "Anruf beendet. SID: \(callSid), Status: \(callStatus)"
            }
            return "Anruf \(callSid) beendet."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - ElevenLabs Outbound Call

    /// Baut einen kompakten Voice-Prompt aus KoboldOS-Persönlichkeit + Anruf-Zweck.
    /// ElevenLabs nutzt sein eigenes LLM (kein Custom-LLM / Tunnel nötig → minimale Latenz).
    private func buildVoicePrompt(purpose: String) -> String {
        let d = UserDefaults.standard
        let soul = d.string(forKey: "kobold.agent.soul") ?? ""
        let personality = d.string(forKey: "kobold.agent.personality") ?? d.string(forKey: "kobold.personality") ?? ""
        let tone = d.string(forKey: "kobold.agent.tone") ?? "freundlich"
        let agentLang = d.string(forKey: "kobold.agent.language") ?? "deutsch"
        let userName = d.string(forKey: "kobold.user.name") ?? ""

        var prompt = "Du führst einen Telefonanruf im Auftrag"
        if !userName.isEmpty { prompt += " von \(userName)" }
        prompt += ".\n\n"
        prompt += "## Deine Aufgabe\n\(purpose)\n\n"
        prompt += "## Verhalten\n"
        prompt += "- Sprache: \(agentLang.capitalized)\n"
        prompt += "- Tonfall: \(tone)\n"
        if !soul.isEmpty { prompt += "- Identität: \(soul)\n" }
        if !personality.isEmpty { prompt += "- Stil: \(personality)\n" }
        prompt += "- Sei natürlich, höflich und zielorientiert\n"
        prompt += "- Fasse dich kurz — Telefongespräche sollen effizient sein\n"
        prompt += "- Stelle sicher, dass du alle nötigen Informationen erhältst (Datum, Uhrzeit, Bestätigung etc.)\n"
        prompt += "- Wiederhole wichtige Details zur Bestätigung (z.B. 'Also Donnerstag um 14 Uhr, richtig?')\n"
        prompt += "- Wenn du die Aufgabe erledigt hast, fasse das Ergebnis kurz zusammen und verabschiede dich freundlich\n"
        prompt += "- NIEMALS nach der ersten Nachricht auflegen! Kurze Antworten (okay, ja, hallo) sind KEINE Verabschiedungen\n"
        prompt += "- end_call NUR wenn BEIDE Seiten sich verabschiedet haben ODER das Gespräch über 3 Minuten dauert (dann höflich ankündigen und beenden)"
        return prompt
    }

    /// Baut eine passende Begrüßung für den Anruf.
    private func buildFirstMessage(purpose: String) -> String {
        let userName = UserDefaults.standard.string(forKey: "kobold.user.name") ?? ""
        var msg = "Hallo! Hier spricht der Assistent"
        if !userName.isEmpty { msg += " von \(userName)" }
        msg += ". "
        // Kurzer Hinweis zum Zweck des Anrufs
        let purposeLower = purpose.lowercased()
        if purposeLower.contains("termin") {
            msg += "Ich rufe an wegen eines Termins."
        } else if purposeLower.contains("frage") || purposeLower.contains("information") {
            msg += "Ich hätte eine kurze Frage."
        } else {
            msg += "Ich rufe an bezüglich: \(purpose.prefix(100))."
        }
        return msg
    }

    /// Holt die ElevenLabs Phone-Number-ID (phnum_xxx) anhand der Twilio-Nummer.
    /// Cached das Ergebnis in UserDefaults damit nicht jedes Mal ein API-Call nötig ist.
    private func resolveElevenLabsPhoneNumberId(twilioNumber: String, apiKey: String) async -> String? {
        // 1) Cache prüfen
        let cacheKey = "kobold.elevenlabs.convai.phoneNumberId"
        if let cached = UserDefaults.standard.string(forKey: cacheKey), !cached.isEmpty {
            return cached
        }

        // 2) Von ElevenLabs API abrufen
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/phone-numbers") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 10

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // API gibt entweder Array oder {"phone_numbers": [...]} zurück
        let numbers: [[String: Any]]
        if let arr = json as? [[String: Any]] {
            numbers = arr
        } else if let dict = json as? [String: Any], let arr = dict["phone_numbers"] as? [[String: Any]] {
            numbers = arr
        } else {
            return nil
        }

        // Passende Nummer finden (oder erste nehmen)
        let cleanTwilio = twilioNumber.replacingOccurrences(of: " ", with: "")
        let match = numbers.first { entry in
            let num = entry["phone_number"] as? String ?? entry["number"] as? String ?? ""
            return num == cleanTwilio
        } ?? numbers.first

        guard let phoneId = match?["phone_number_id"] as? String ?? match?["id"] as? String else { return nil }

        // Cachen
        UserDefaults.standard.set(phoneId, forKey: cacheKey)
        print("[EL-Twilio] Phone-Number-ID aufgelöst: \(phoneId)")
        return phoneId
    }

    private func executeElevenLabsOutboundCall(to: String, from: String, purpose: String) async -> String? {
        let d = UserDefaults.standard
        let agentId = d.string(forKey: "kobold.elevenlabs.convai.agentId") ?? ""
        let apiKey = d.string(forKey: "kobold.elevenlabs.apiKey") ?? ""

        guard !agentId.isEmpty, !apiKey.isEmpty else { return nil }

        // ElevenLabs braucht die Phone-Number-ID (phnum_xxx), NICHT die Twilio-Nummer (+1xxx)
        guard let phoneNumberId = await resolveElevenLabsPhoneNumberId(twilioNumber: from, apiKey: apiKey) else {
            print("[EL-Twilio] Fehler: Keine ElevenLabs Phone-Number-ID gefunden für \(from)")
            return nil
        }

        // ── SCHRITT 1: Purpose + Persönlichkeit VOR dem Anruf in den Agent-Prompt PATCHen ──
        // Default true: object(forKey:) == nil → noch nie gesetzt → true
        let syncPurpose = d.object(forKey: "kobold.elevenlabs.convai.syncPurpose") == nil ? true : d.bool(forKey: "kobold.elevenlabs.convai.syncPurpose")
        let syncPersonality = d.object(forKey: "kobold.elevenlabs.convai.syncPersonality") == nil ? true : d.bool(forKey: "kobold.elevenlabs.convai.syncPersonality")

        if syncPurpose || syncPersonality {
            await patchAgentBeforeCall(
                agentId: agentId, apiKey: apiKey,
                purpose: purpose,
                syncPurpose: syncPurpose,
                syncPersonality: syncPersonality
            )
        }

        // ── SCHRITT 2: Outbound Call starten ──
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/twilio/outbound-call") else { return nil }

        let firstMessage = buildFirstMessage(purpose: purpose)
        let agentLang = d.string(forKey: "kobold.agent.language") ?? "deutsch"
        let langCode: String
        switch agentLang.lowercased() {
        case "deutsch", "german", "de": langCode = "de"
        case "englisch", "english", "en": langCode = "en"
        default: langCode = "de"
        }

        // Minimaler Payload — Prompt steht bereits im Agent via PATCH
        var callPayload: [String: Any] = [
            "agent_id": agentId,
            "agent_phone_number_id": phoneNumberId,
            "to_number": to
        ]

        // Falls syncPurpose AUS → conversation_config_override als Fallback (alter Weg)
        if !syncPurpose {
            let voicePrompt = buildVoicePrompt(purpose: purpose)
            let voiceLLM = d.string(forKey: "kobold.elevenlabs.convai.llm") ?? "gemini-2.0-flash"
            callPayload["conversation_initiation_client_data"] = [
                "conversation_config_override": [
                    "agent": [
                        "prompt": ["prompt": voicePrompt, "llm": voiceLLM] as [String: Any],
                        "first_message": firstMessage,
                        "language": langCode
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
            print("[EL-Twilio] Outbound Call mit Override-Fallback")
        } else {
            print("[EL-Twilio] Outbound Call — Purpose bereits via PATCH im Agent-Prompt")
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: callPayload) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = bodyData
        request.timeoutInterval = 15

        let conversationId: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status >= 400 {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                print("[EL-Twilio] Outbound HTTP \(status): \(body)")
                return nil  // Fallback auf native
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cid = json["conversation_id"] as? String ?? json["call_id"] as? String ?? json["id"] as? String else {
                return "ElevenLabs-Anruf gestartet an \(to) — Zweck: \(purpose) (keine Conversation-ID erhalten)"
            }
            conversationId = cid
            print("[EL-Twilio] Anruf gestartet, Conversation-ID: \(conversationId)")
        } catch {
            print("[EL-Twilio] Outbound Fehler: \(error)")
            return nil
        }

        // UI-Notification: Call-Monitor-Popup öffnen
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("koboldElevenLabsCallStarted"),
                object: nil,
                userInfo: [
                    "conversationId": conversationId,
                    "to": to,
                    "purpose": purpose
                ]
            )
        }

        // ── SCHRITT 3: Auf Gesprächsende warten + Ergebnis abrufen ──
        let transcript = await pollConversationResult(conversationId: conversationId, apiKey: apiKey, to: to, purpose: purpose)

        // ── SCHRITT 4: Agent-Prompt nach Anruf zurücksetzen (Purpose entfernen) ──
        if syncPurpose {
            await resetAgentAfterCall(agentId: agentId, apiKey: apiKey)
        }

        // Ergebnis formatieren — geht zurück an den KoboldOS Agent
        // Datums-Kontext mitgeben damit der Agent relative Angaben (Freitag, morgen, nächste Woche) korrekt umrechnen kann
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "de_DE")
        dateFmt.dateFormat = "EEEE, dd.MM.yyyy HH:mm"
        let isoFmt = DateFormatter()
        isoFmt.locale = Locale(identifier: "en_US_POSIX")
        isoFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = Date()
        let dateContext = "Aktuelles Datum: \(dateFmt.string(from: now)) (ISO: \(isoFmt.string(from: now)))"

        if let transcript {
            return "ElevenLabs-Anruf an \(to) beendet.\nZweck: \(purpose)\n\(dateContext)\n\nWICHTIG: Wenn im Gespräch Termine vereinbart wurden, berechne das exakte Datum aus den genannten Wochentagen/Zeiten relativ zum aktuellen Datum und erstelle den Kalender-Eintrag mit korrektem ISO-Datum (z.B. 2026-03-06T14:00:00).\n\n## Gesprächsverlauf\n\(transcript)"
        } else {
            return "ElevenLabs-Anruf an \(to) gestartet (Conversation-ID: \(conversationId)), Zweck: \(purpose). \(dateContext). Das Gespräch läuft noch oder konnte nicht abgerufen werden."
        }
    }

    // MARK: - Pre-Call Agent PATCH

    /// PATCHt den ElevenLabs Agent-Prompt VOR dem Anruf mit Purpose + optional Persönlichkeit.
    /// So weiß der ElevenLabs-Agent genau was er in diesem Anruf zu tun hat.
    private func patchAgentBeforeCall(agentId: String, apiKey: String, purpose: String, syncPurpose: Bool, syncPersonality: Bool) async {
        let d = UserDefaults.standard
        let agentName = d.string(forKey: "kobold.agent.name") ?? "Kobold"
        let userName = d.string(forKey: "kobold.user.name") ?? ""

        // Basis-Prompt bauen
        var prompt = "Du bist \(agentName)"
        if !userName.isEmpty { prompt += ", der KI-Assistent von \(userName)" }
        prompt += ".\n\n"

        // Persönlichkeit einfügen wenn Toggle aktiv
        if syncPersonality {
            let soul = d.string(forKey: "kobold.agent.soul") ?? ""
            let personality = d.string(forKey: "kobold.agent.personality") ?? ""
            let tone = d.string(forKey: "kobold.agent.tone") ?? "freundlich"
            if !soul.isEmpty { prompt += "## Identität\n\(soul)\n\n" }
            if !personality.isEmpty { prompt += "## Persönlichkeit\n\(personality)\n\n" }
            prompt += "## Kommunikation\n- Tonfall: \(tone)\n"
        }

        // Aufgabe einfügen wenn Toggle aktiv
        if syncPurpose {
            prompt += "\n## AKTUELLE AUFGABE FÜR DIESEN ANRUF\n"
            prompt += "\(purpose)\n\n"
            prompt += "## Anruf-Regeln\n"
            prompt += "- Erledige die oben genannte Aufgabe zielstrebig\n"
            prompt += "- Fasse dich kurz — Telefongespräche sollen effizient sein\n"
            prompt += "- Stelle sicher, dass du alle nötigen Informationen erhältst (Datum, Uhrzeit, Bestätigung etc.)\n"
            prompt += "- Wiederhole wichtige Details zur Bestätigung\n"
            prompt += "- Wenn die Aufgabe erledigt ist, fasse das Ergebnis kurz zusammen und verabschiede dich freundlich\n"
            prompt += "- NIEMALS nach der ersten Nachricht auflegen! Wenn dein Gesprächspartner dich unterbricht oder nur kurz antwortet (okay, ja, hallo), führe das Gespräch WEITER und erkläre dein Anliegen\n"
            prompt += "- Kurze Antworten wie 'okay', 'ja', 'mhm', 'hallo' sind KEINE Verabschiedungen — das Gespräch geht weiter!\n"
            prompt += "\n## Wann auflegen (end_call)?\n"
            prompt += "- Wenn BEIDE Seiten sich verabschiedet haben (tschüss, auf wiederhören, ciao, etc.)\n"
            prompt += "- ODER wenn das Gespräch länger als 3 Minuten dauert: Sage 'Ich muss das Gespräch leider aus zeitlichen Gründen beenden. Vielen Dank für Ihre Zeit!' und nutze dann end_call\n"
            prompt += "- In KEINEM anderen Fall end_call nutzen!\n"
        }

        // Begrüßung passend zum Zweck
        let firstMessage = buildFirstMessage(purpose: purpose)

        // Sprachcode
        let agentLang = d.string(forKey: "kobold.agent.language") ?? "deutsch"
        let langCode: String
        switch agentLang.lowercased() {
        case "deutsch", "german", "de": langCode = "de"
        case "englisch", "english", "en": langCode = "en"
        default: langCode = "de"
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentId)") else { return }

        let payload: [String: Any] = [
            "conversation_config": [
                "agent": [
                    "prompt": [
                        "prompt": prompt,
                        "built_in_tools": [
                            "end_call": [
                                "type": "system",
                                "name": "end_call",
                                "description": "Beendet den Anruf. Nutze dieses Tool NACHDEM du dich verabschiedet hast, wenn die Aufgabe erledigt ist, oder wenn der Gesprächspartner sich verabschiedet."
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "first_message": firstMessage,
                    "language": langCode
                ] as [String: Any],
                "turn": [
                    "silence_end_call_timeout": 30.0
                ] as [String: Any]
            ] as [String: Any]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                print("[EL-Twilio] ✅ Agent-Prompt vor Anruf gesetzt: \(purpose.prefix(60))...")
            } else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                print("[EL-Twilio] ❌ Pre-Call PATCH HTTP \(status): \(body)")
            }
        } catch {
            print("[EL-Twilio] ❌ Pre-Call PATCH Fehler: \(error.localizedDescription)")
        }
    }

    /// Setzt den Agent-Prompt nach dem Anruf zurück auf den Standard (ohne Purpose).
    private func resetAgentAfterCall(agentId: String, apiKey: String) async {
        let d = UserDefaults.standard
        let agentName = d.string(forKey: "kobold.agent.name") ?? "Kobold"
        let userName = d.string(forKey: "kobold.user.name") ?? ""

        // Standard-Prompt wiederherstellen (ohne AKTUELLE AUFGABE)
        var defaultPrompt = "Du bist \(agentName)"
        if !userName.isEmpty { defaultPrompt += ", der KI-Assistent von \(userName)" }
        defaultPrompt += ".\n\n"
        defaultPrompt += "## Telefonverhalten\n"
        defaultPrompt += "- Sei natürlich, höflich und zielorientiert\n"
        defaultPrompt += "- Fasse dich kurz\n"
        defaultPrompt += "- Frage wie du helfen kannst wenn du nicht weißt warum jemand anruft\n"
        defaultPrompt += "- Wenn sich dein Gesprächspartner verabschiedet, verabschiede dich und nutze das end_call Tool"

        // Persönlichkeit beibehalten wenn syncPersonality aktiv
        if d.bool(forKey: "kobold.elevenlabs.convai.syncPersonality") {
            let soul = d.string(forKey: "kobold.agent.soul") ?? ""
            let personality = d.string(forKey: "kobold.agent.personality") ?? ""
            let tone = d.string(forKey: "kobold.agent.tone") ?? "freundlich"
            if !soul.isEmpty { defaultPrompt = "## Identität\n\(soul)\n\n" + defaultPrompt }
            if !personality.isEmpty { defaultPrompt += "\n- Stil: \(personality)" }
            defaultPrompt += "\n- Tonfall: \(tone)"
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentId)") else { return }

        let payload: [String: Any] = [
            "conversation_config": [
                "agent": [
                    "prompt": ["prompt": defaultPrompt] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[EL-Twilio] Agent-Prompt nach Anruf zurückgesetzt (HTTP \(status))")
        } catch {
            print("[EL-Twilio] Reset-Fehler: \(error.localizedDescription)")
        }
    }

    // MARK: - ElevenLabs Conversation Polling

    /// Pollt die ElevenLabs ConvAI API bis das Gespräch beendet ist und gibt das Transcript zurück.
    /// Max 5 Minuten (30 Polls à 5s). Postet Live-Updates an die UI via Notification.
    private func pollConversationResult(conversationId: String, apiKey: String, to: String, purpose: String) async -> String? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/conversations/\(conversationId)") else { return nil }

        let maxPolls = 60  // 60 × 5s = 5 Minuten
        var lastTranscriptCount = 0

        for poll in 1...maxPolls {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s (schneller für Live-Updates)

            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            req.timeoutInterval = 10

            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let httpStatus = (response as? HTTPURLResponse)?.statusCode,
                  httpStatus == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[EL-Twilio] Poll \(poll)/\(maxPolls): Fehler beim Abrufen")
                continue
            }

            let status = json["status"] as? String ?? ""

            // Transcript extrahieren (auch während des Gesprächs für Live-Updates)
            var transcriptLines: [String] = []
            if let transcriptArray = json["transcript"] as? [[String: Any]] {
                for entry in transcriptArray {
                    let role = entry["role"] as? String ?? "?"
                    let message = entry["message"] as? String ?? ""
                    let speaker = role == "agent" ? "Assistent" : "Gesprächspartner"
                    if !message.isEmpty {
                        transcriptLines.append("**\(speaker):** \(message)")
                    }
                }
            }

            // Live-Update an UI senden wenn sich Transcript geändert hat
            if transcriptLines.count != lastTranscriptCount {
                lastTranscriptCount = transcriptLines.count
                let currentTranscript = transcriptLines.joined(separator: "\n")
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Notification.Name("koboldElevenLabsCallUpdate"),
                        object: nil,
                        userInfo: [
                            "conversationId": conversationId,
                            "status": status,
                            "transcript": currentTranscript,
                            "to": to,
                            "purpose": purpose
                        ]
                    )
                }
            }

            print("[EL-Twilio] Poll \(poll)/\(maxPolls): Status = \(status), Lines = \(transcriptLines.count)")

            // "done" oder "failed" = Gespräch beendet
            guard status == "done" || status == "failed" else { continue }

            // Analyse extrahieren (falls vorhanden)
            var analysisSummary = ""
            if let analysis = json["analysis"] as? [String: Any] {
                if let evalResult = analysis["evaluation_criteria_results"] as? [String: Any] {
                    let results = evalResult.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                    analysisSummary = "\n\n## Analyse\n\(results)"
                }
                if let dataResults = analysis["data_collection_results"] as? [String: Any] {
                    let collected = dataResults.compactMap { key, val -> String? in
                        guard let strVal = val as? String, !strVal.isEmpty else { return nil }
                        return "- \(key): \(strVal)"
                    }.joined(separator: "\n")
                    if !collected.isEmpty {
                        analysisSummary += "\n\n## Gesammelte Daten\n\(collected)"
                    }
                }
            }

            let finalTranscript: String
            if transcriptLines.isEmpty && status == "failed" {
                finalTranscript = "Anruf fehlgeschlagen (Status: failed)"
            } else {
                finalTranscript = transcriptLines.joined(separator: "\n") + analysisSummary
            }

            // Abschluss-Notification an UI
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("koboldElevenLabsCallEnded"),
                    object: nil,
                    userInfo: [
                        "conversationId": conversationId,
                        "status": status,
                        "transcript": finalTranscript,
                        "to": to,
                        "purpose": purpose
                    ]
                )
            }

            return finalTranscript
        }

        // Timeout-Notification
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("koboldElevenLabsCallEnded"),
                object: nil,
                userInfo: [
                    "conversationId": conversationId,
                    "status": "timeout",
                    "transcript": "Timeout — Gespräch nach 5 Minuten nicht beendet",
                    "to": to,
                    "purpose": purpose
                ]
            )
        }

        print("[EL-Twilio] Timeout: Gespräch nach 5 Minuten nicht beendet")
        return nil
    }
}

#elseif os(Linux)
import Foundation

public struct TwilioVoiceCallTool: Tool {
    public let name = "phone_call"
    public let description = "Telefonanruf über Twilio (deaktiviert auf Linux)"
    public let riskLevel: RiskLevel = .critical
    public var schema: ToolSchema { ToolSchema(properties: ["action": ToolSchemaProperty(type: "string", description: "Aktion", required: true)], required: ["action"]) }
    public init() {}
    public func validate(arguments: [String: String]) throws {}
    public func execute(arguments: [String: String]) async throws -> String { "Twilio Voice ist auf Linux deaktiviert." }
}
#endif
