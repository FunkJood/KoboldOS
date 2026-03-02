import Foundation

// MARK: - TwilioVoiceHandler
// Verarbeitet Twilio-Sprachanrufe und Media-Streams (WebSocket).
// Zuständig für μ-law Codec (G.711), Resampling und Call-Management.

// MARK: - Datenmodelle

/// Richtung eines Anrufs
public enum CallDirection: String, Sendable {
    case inbound
    case outbound
}

/// Repräsentiert eine aktive Sprachsitzung mit Twilio
public struct VoiceCallSession: Sendable {
    /// Eindeutige Twilio Call-SID
    public let callSid: String
    /// Eingehend oder ausgehend
    public let direction: CallDirection
    /// Zweck des Anrufs (z.B. "support", "notification", "scheduled")
    public let purpose: String
    /// Telefonnummer der Gegenseite
    public let counterpartyNumber: String
    /// Gesprächsverlauf als Text-Nachrichten
    public var conversationHistory: [(role: String, content: String)]
    /// Akkumulierter Audio-Puffer (PCM Int16, 16kHz nach Resampling)
    public var audioBuffer: [Float]
    /// Zeitpunkt des Anrufbeginns
    public let startTime: Date

    public init(
        callSid: String,
        direction: CallDirection,
        purpose: String,
        counterpartyNumber: String,
        conversationHistory: [(role: String, content: String)] = [],
        audioBuffer: [Float] = [],
        startTime: Date = Date()
    ) {
        self.callSid = callSid
        self.direction = direction
        self.purpose = purpose
        self.counterpartyNumber = counterpartyNumber
        self.conversationHistory = conversationHistory
        self.audioBuffer = audioBuffer
        self.startTime = startTime
    }
}

// MARK: - TwilioVoiceHandler Actor

public actor TwilioVoiceHandler {

    /// Singleton-Instanz — wird von DaemonListener und anderen Modulen verwendet
    public static let shared = TwilioVoiceHandler()

    /// Aktive Anrufe, indexiert nach Call-SID
    private var activeCalls: [String: VoiceCallSession] = [:]

    /// Ausstehende Anruf-Zwecke (gesetzt von TwilioVoiceCallTool VOR dem Webhook)
    /// Key = normalisierte Telefonnummer, Value = Zweck des Anrufs
    private var pendingPurposes: [String: String] = [:]

    private init() {}

    /// Speichert den Zweck eines ausgehenden Anrufs BEVOR der Webhook kommt.
    /// Wird von TwilioVoiceCallTool aufgerufen.
    public func setPendingPurpose(toNumber: String, purpose: String) {
        let normalized = toNumber.replacingOccurrences(of: " ", with: "")
        pendingPurposes[normalized] = purpose
        print("[TwilioVoice] Pending Purpose gesetzt für \(normalized): \(purpose)")
    }

    /// Holt und entfernt den gespeicherten Zweck für eine Nummer.
    public func consumePendingPurpose(forNumber number: String) -> String? {
        let normalized = number.replacingOccurrences(of: " ", with: "")
        return pendingPurposes.removeValue(forKey: normalized)
    }

    /// Gibt den Zweck eines aktiven Anrufs zurück.
    public func getCallPurpose(callSid: String) -> String? {
        return activeCalls[callSid]?.purpose
    }

    // MARK: - ITU-T G.711 μ-law Lookup-Tabelle
    // Standardkonforme Dekodierungstabelle (256 Einträge)
    // Jeder μ-law Byte-Wert wird auf einen linearen PCM Int16-Wert abgebildet.
    // Berechnung nach ITU-T G.711: Invertieren, Segment + Quantisierung extrahieren,
    // linearen Wert rekonstruieren und Vorzeichen anwenden.
    private static let mulawDecodingTable: [Int16] = {
        var table = [Int16](repeating: 0, count: 256)
        for i in 0..<256 {
            // μ-law Byte invertieren (Twilio/ITU-T Konvention)
            let mulaw = UInt8(i) ^ 0xFF

            // Vorzeichen-Bit (Bit 7)
            let sign: Int16 = (mulaw & 0x80) != 0 ? 1 : -1

            // Segment/Exponent (Bits 4-6)
            let exponent = Int((mulaw >> 4) & 0x07)

            // Mantisse (Bits 0-3)
            let mantissa = Int(mulaw & 0x0F)

            // Linearen Wert rekonstruieren
            // Formel: ((mantissa << 1) + 1 + 32) << (exponent + 2) - 132
            // Bias = 132 = 33 << 2 (Standard G.711 Bias)
            let magnitude: Int
            if exponent == 0 {
                magnitude = (mantissa << 1 | 1) << (exponent + 2)
            } else {
                magnitude = (mantissa << 1 | 1) << (exponent + 2)
            }
            // Bias von 0x84 (132) abziehen
            let value = magnitude - 132

            table[i] = Int16(clamping: Int(sign) * value)
        }
        return table
    }()

    // MARK: - μ-law Dekodierung

    /// Dekodiert μ-law kodierte Bytes (G.711) in lineare PCM-Samples (Int16).
    /// Verwendet die standardkonforme ITU-T G.711 Lookup-Tabelle.
    ///
    /// - Parameter encoded: Array von μ-law kodierten Bytes
    /// - Returns: Array von linearen PCM Int16-Werten
    public func mulawDecode(_ encoded: [UInt8]) -> [Int16] {
        return encoded.map { Self.mulawDecodingTable[Int($0)] }
    }

    // MARK: - μ-law Kodierung

    /// Kodiert lineare PCM-Samples (Int16) in μ-law Bytes (G.711).
    /// Verwendet Kompression mit Bias und Clipping gemäß ITU-T Standard.
    ///
    /// - Parameter pcm: Array von linearen PCM Int16-Werten
    /// - Returns: Array von μ-law kodierten Bytes
    public func mulawEncode(_ pcm: [Int16]) -> [UInt8] {
        // Konstanten für μ-law Kompression
        let bias: Int32 = 0x84       // 132 — Standard G.711 Bias
        let clipLevel: Int32 = 32635 // Maximaler Eingangswert (vor Clipping)

        return pcm.map { sample in
            // Vorzeichen bestimmen und Betrag berechnen
            let sampleInt = Int32(sample)
            let sign: UInt8
            var magnitude: Int32

            if sampleInt < 0 {
                sign = 0x80
                magnitude = -sampleInt
            } else {
                sign = 0x00
                magnitude = sampleInt
            }

            // Clipping auf maximalen Wert
            if magnitude > clipLevel {
                magnitude = clipLevel
            }

            // Bias addieren für korrekte Kompression
            magnitude += bias

            // Segment (Exponent) finden — höchstes gesetztes Bit
            var exponent: Int = 7
            let mask: Int32 = 0x4000 // Bit 14
            var testMask = mask
            while exponent > 0 {
                if (magnitude & testMask) != 0 {
                    break
                }
                exponent -= 1
                testMask >>= 1
            }

            // Mantisse extrahieren (4 Bits aus dem relevanten Segment)
            let mantissa = Int((magnitude >> (exponent + 3)) & 0x0F)

            // μ-law Byte zusammensetzen und invertieren
            let mulawByte = sign | UInt8(exponent << 4) | UInt8(mantissa)

            // Invertieren (ITU-T Konvention)
            return mulawByte ^ 0xFF
        }
    }

    // MARK: - Resampling

    /// Resampled Audio von 8kHz (Twilio) auf 16kHz mittels linearer Interpolation.
    /// Twilio sendet standardmäßig 8kHz μ-law Audio.
    ///
    /// - Parameter samples: PCM-Samples bei 8kHz
    /// - Returns: Normalisierte Float-Samples bei 16kHz (Wertebereich -1.0 bis 1.0)
    public func resample8to16kHz(_ samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let inputCount = samples.count
        let outputCount = inputCount * 2  // Verdopplung der Samplerate

        var output = [Float](repeating: 0.0, count: outputCount)
        let normFactor: Float = 1.0 / 32768.0  // Int16 auf Float normalisieren

        for i in 0..<outputCount {
            // Position im Eingangssignal (mit Interpolation)
            let srcPos = Float(i) * 0.5  // 16kHz → 8kHz Verhältnis
            let srcIndex = Int(srcPos)
            let fraction = srcPos - Float(srcIndex)

            if srcIndex + 1 < inputCount {
                // Lineare Interpolation zwischen zwei Nachbar-Samples
                let a = Float(samples[srcIndex]) * normFactor
                let b = Float(samples[srcIndex + 1]) * normFactor
                output[i] = a + fraction * (b - a)
            } else {
                // Letztes Sample ohne Interpolation
                output[i] = Float(samples[min(srcIndex, inputCount - 1)]) * normFactor
            }
        }

        return output
    }

    /// Resampled Audio von einer beliebigen Samplerate zurück auf 8kHz (für Twilio TTS-Ausgabe).
    /// Verwendet lineare Interpolation für die Ratenkonvertierung.
    ///
    /// - Parameters:
    ///   - samples: Normalisierte Float-Samples (Wertebereich -1.0 bis 1.0)
    ///   - fromRate: Quell-Samplerate in Hz (z.B. 16000, 22050, 24000)
    /// - Returns: PCM Int16-Samples bei 8kHz
    public func resampleTo8kHz(_ samples: [Float], fromRate: Int) -> [Int16] {
        guard !samples.isEmpty, fromRate > 0 else { return [] }

        // Wenn bereits 8kHz, nur Float→Int16 konvertieren
        if fromRate == 8000 {
            return samples.map { sample in
                let clamped = max(-1.0, min(1.0, sample))
                return Int16(clamped * 32767.0)
            }
        }

        let ratio = Double(fromRate) / 8000.0  // Verhältnis Quelle/Ziel
        let outputCount = Int(Double(samples.count) / ratio)

        guard outputCount > 0 else { return [] }

        var output = [Int16](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            // Position im Quellsignal
            let srcPos = Double(i) * ratio
            let srcIndex = Int(srcPos)
            let fraction = Float(srcPos - Double(srcIndex))

            let value: Float
            if srcIndex + 1 < samples.count {
                // Lineare Interpolation
                let a = samples[srcIndex]
                let b = samples[srcIndex + 1]
                value = a + fraction * (b - a)
            } else {
                value = samples[min(srcIndex, samples.count - 1)]
            }

            // Float auf Int16 skalieren mit Clipping
            let clamped = max(-1.0, min(1.0, value))
            output[i] = Int16(clamped * 32767.0)
        }

        return output
    }

    // MARK: - TwiML Generierung

    /// Erzeugt TwiML-XML für einen eingehenden Anruf.
    /// Verbindet den Anruf mit einem WebSocket Media Stream.
    ///
    /// - Parameters:
    ///   - callSid: Twilio Call-SID zur Identifikation
    ///   - publicUrl: Öffentliche URL/Domain des Servers (ohne Schema)
    /// - Returns: Vollständiger TwiML-XML-String
    public func generateTwiML(callSid: String, publicUrl: String) -> String {
        // Schema von publicUrl entfernen (enthält bereits https://) → wss:// verwenden
        let host = publicUrl
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // TwiML-Dokument: Verbindet den Anruf mit einem bidirektionalen WebSocket-Stream
        // Der Stream sendet μ-law Audio in Echtzeit an unseren WebSocket-Endpunkt
        let twiml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Response>
            <Connect>
                <Stream url="wss://\(host)/twilio/voice/ws">
                    <Parameter name="callSid" value="\(callSid)" />
                </Stream>
            </Connect>
        </Response>
        """
        return twiml
    }

    // MARK: - Call-Management

    /// Registriert einen neuen Anruf im System.
    /// Wird aufgerufen wenn Twilio einen eingehenden/ausgehenden Anruf meldet.
    ///
    /// - Parameters:
    ///   - callSid: Eindeutige Twilio Call-SID
    ///   - direction: Eingehend oder ausgehend
    ///   - purpose: Zweck des Anrufs
    ///   - number: Telefonnummer der Gegenseite
    public func registerCall(callSid: String, direction: CallDirection, purpose: String, number: String) {
        let session = VoiceCallSession(
            callSid: callSid,
            direction: direction,
            purpose: purpose,
            counterpartyNumber: number
        )
        activeCalls[callSid] = session
        print("[TwilioVoice] Anruf registriert: \(callSid) (\(direction.rawValue)) — \(number)")
    }

    /// Beendet einen Anruf und entfernt die Sitzung.
    /// Gibt die Gesprächsdauer aus und räumt den Audio-Puffer auf.
    ///
    /// - Parameter callSid: Call-SID des zu beendenden Anrufs
    /// - Returns: Die beendete Sitzung (falls vorhanden), für Logging/Archivierung
    @discardableResult
    public func endCall(callSid: String) -> VoiceCallSession? {
        guard let session = activeCalls.removeValue(forKey: callSid) else {
            print("[TwilioVoice] Unbekannter Anruf beim Beenden: \(callSid)")
            return nil
        }

        let duration = Date().timeIntervalSince(session.startTime)
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        print("[TwilioVoice] Anruf beendet: \(callSid) — Dauer: \(minutes)m \(seconds)s, \(session.conversationHistory.count) Nachrichten")

        return session
    }

    // MARK: - Media-Stream Verarbeitung

    /// Verarbeitet ein Media-Event von Twilio (WebSocket-Nachricht).
    /// Dekodiert Base64 → μ-law → PCM → Resampling auf 16kHz → Audio-Puffer.
    ///
    /// - Parameters:
    ///   - callSid: Call-SID des zugehörigen Anrufs
    ///   - payload: Base64-kodiertes μ-law Audio (8kHz, mono)
    /// - Returns: Resamplete Float-Samples (16kHz) für Spracherkennung, oder nil bei Fehler
    public func handleMediaEvent(callSid: String, payload: String) -> [Float]? {
        guard activeCalls[callSid] != nil else {
            print("[TwilioVoice] Media-Event für unbekannten Anruf: \(callSid)")
            return nil
        }

        // Base64 dekodieren
        guard let audioData = Data(base64Encoded: payload) else {
            print("[TwilioVoice] Ungültige Base64-Daten für Anruf: \(callSid)")
            return nil
        }

        // μ-law Bytes extrahieren
        let mulawBytes = [UInt8](audioData)

        guard !mulawBytes.isEmpty else { return nil }

        // μ-law → PCM Int16 dekodieren
        let pcmSamples = mulawDecode(mulawBytes)

        // 8kHz → 16kHz Resampling mit linearer Interpolation
        let resampledSamples = resample8to16kHz(pcmSamples)

        // Audio-Puffer der Sitzung erweitern
        activeCalls[callSid]?.audioBuffer.append(contentsOf: resampledSamples)

        return resampledSamples
    }

    // MARK: - Hilfsfunktionen

    /// Gibt die Anzahl aktiver Anrufe zurück.
    public func getActiveCallCount() -> Int {
        return activeCalls.count
    }

    /// Gibt eine bestimmte Anruf-Sitzung zurück (falls aktiv).
    public func getSession(callSid: String) -> VoiceCallSession? {
        return activeCalls[callSid]
    }

    /// Gibt den Gesprächsverlauf eines Anrufs als Array von Dictionaries zurück.
    /// Format: [["role": "user"|"assistant", "content": "..."]]
    public func getConversationHistory(callSid: String) -> [[String: String]] {
        return activeCalls[callSid]?.conversationHistory.map {
            ["role": $0.role, "content": $0.content]
        } ?? []
    }

    /// Fügt eine Nachricht zum Gesprächsverlauf eines Anrufs hinzu.
    ///
    /// - Parameters:
    ///   - callSid: Call-SID des Anrufs
    ///   - role: Rolle des Sprechers ("user" für Anrufer, "assistant" für KoboldOS)
    ///   - content: Textinhalt der Nachricht (z.B. transkribierter Text)
    public func appendToConversation(callSid: String, role: String, content: String) {
        activeCalls[callSid]?.conversationHistory.append((role: role, content: content))
    }

    /// Leert den Audio-Puffer eines Anrufs (z.B. nach erfolgreicher Transkription).
    /// Gibt die geleerten Samples zurück für eventuelle Weiterverarbeitung.
    ///
    /// - Parameter callSid: Call-SID des Anrufs
    /// - Returns: Die geleerten Audio-Samples
    @discardableResult
    public func flushAudioBuffer(callSid: String) -> [Float] {
        guard var session = activeCalls[callSid] else { return [] }
        let buffer = session.audioBuffer
        session.audioBuffer = []
        activeCalls[callSid] = session
        return buffer
    }
}
