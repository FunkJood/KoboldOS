import Foundation
import AVFoundation

// MARK: - ELConversationState

enum ELConversationState: Equatable, Sendable {
    case disconnected
    case connecting
    case listening       // Connected + mic active, waiting for speech
    case userSpeaking    // User is talking (server-side VAD)
    case agentSpeaking   // Agent is responding with audio
    case error(String)
}

// MARK: - AudioCaptureProcessor (Thread-Safe, nonisolated)
// Gleicher Pattern wie AudioRecordingManager.AudioTapProcessor:
// installTap-Closure MUSS in nonisolated-Kontext erstellt werden,
// sonst @MainActor-Isolation → EXC_BREAKPOINT auf Audio-Realtime-Thread.

private final class AudioCaptureProcessor: @unchecked Sendable {
    let inputSampleRate: Double
    let channelCount: UInt32
    let onChunk: @Sendable (_ samples: [Float], _ level: Float) -> Void

    init(inputSampleRate: Double, channelCount: UInt32,
         onChunk: @escaping @Sendable (_ samples: [Float], _ level: Float) -> Void) {
        self.inputSampleRate = inputSampleRate
        self.channelCount = channelCount
        self.onChunk = onChunk
    }

    func handleTap(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)

        // Mono-Downmix
        var monoSamples = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            for i in 0..<frameCount { monoSamples[i] = floatData[0][i] }
        } else {
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<Int(channelCount) { sum += floatData[ch][i] }
                monoSamples[i] = sum / Float(channelCount)
            }
        }

        // Resample → 16kHz (lineare Interpolation)
        let resampledSamples: [Float]
        if abs(inputSampleRate - 16000) < 100 {
            resampledSamples = monoSamples
        } else {
            let ratio = 16000.0 / inputSampleRate
            let outputCount = Int(Double(frameCount) * ratio)
            var output = [Float](repeating: 0, count: outputCount)
            for i in 0..<outputCount {
                let srcIndex = Double(i) / ratio
                let idx = Int(srcIndex)
                let frac = Float(srcIndex - Double(idx))
                if idx + 1 < frameCount {
                    output[i] = monoSamples[idx] * (1.0 - frac) + monoSamples[idx + 1] * frac
                } else if idx < frameCount {
                    output[i] = monoSamples[idx]
                }
            }
            resampledSamples = output
        }

        // RMS → Audio-Level
        var rms: Float = 0
        for s in resampledSamples { rms += s * s }
        rms = sqrt(rms / max(Float(resampledSamples.count), 1))
        let level = min(rms * 10, 1.0)

        onChunk(resampledSamples, level)
    }
}

// MARK: - ElevenLabsConversationManager
// WebSocket-basierter Manager für ElevenLabs Conversational AI.
// Nutzt URLSessionWebSocketTask (Foundation, zero Dependencies).
// Audio: eigener AVAudioEngine für Capture, AVAudioPlayerNode für Playback.

@MainActor
final class ElevenLabsConversationManager: ObservableObject {
    static let shared = ElevenLabsConversationManager()

    // MARK: - Published State

    @Published var state: ELConversationState = .disconnected
    @Published var userTranscript: String = ""
    @Published var agentResponse: String = ""
    @Published var audioLevel: Float = 0
    @Published var conversationId: String = ""

    // MARK: - WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    // MARK: - Audio Capture (eigener Engine, NICHT AudioRecordingManager teilen)

    private var captureEngine: AVAudioEngine?

    // MARK: - Audio Playback (AVAudioPlayerNode für Streaming-Chunks)

    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?

    // MARK: - Server-negotiated Audio Config

    private var outputSampleRate: Int = 16000
    private var outputEncoding: String = "pcm_16000"

    // MARK: - Settings

    var agentId: String { UserDefaults.standard.string(forKey: "kobold.elevenlabs.convai.agentId") ?? "" }
    var apiKey: String { UserDefaults.standard.string(forKey: "kobold.elevenlabs.apiKey") ?? "" }

    // MARK: - Callbacks

    var onUserTranscript: ((String) -> Void)?
    var onAgentResponse: ((String) -> Void)?
    var onConversationEnd: (() -> Void)?

    // MARK: - Init

    private init() {}

    // MARK: - Connect

    func connect() async {
        guard state == .disconnected || isErrorState else { return }
        guard !agentId.isEmpty else {
            state = .error("Keine Agent-ID")
            return
        }
        guard !apiKey.isEmpty else {
            state = .error("Kein API-Key")
            return
        }

        state = .connecting
        userTranscript = ""
        agentResponse = ""
        conversationId = ""

        // Signed-URL holen (zuverlässiger als Custom-Header bei WebSocket-Upgrade)
        guard let signedURL = await fetchSignedURL() else {
            state = .error("Signed URL fehlgeschlagen")
            return
        }

        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: signedURL)
        webSocket?.resume()

        // Receive-Loop starten
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }
    }

    // MARK: - Signed URL (REST API → WebSocket URL ohne Header)

    private func fetchSignedURL() async -> URL? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/conversation/get_signed_url?agent_id=\(agentId)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                print("[EL-ConvAI] Signed URL HTTP \(status): \(body)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let signedURLStr = json["signed_url"] as? String,
               let signedURL = URL(string: signedURLStr) {
                return signedURL
            }
            return nil
        } catch {
            print("[EL-ConvAI] Signed URL Fehler: \(error)")
            return nil
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil

        stopAudioCapture()
        stopPlayback()

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        state = .disconnected
        audioLevel = 0
        conversationId = ""
        onConversationEnd?()
    }

    // MARK: - Audio Capture Setup (NONISOLATED — crash-safe)

    private nonisolated static func configureCaptureEngine(
        onChunk: @escaping @Sendable (_ samples: [Float], _ level: Float) -> Void
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = inputFormat.sampleRate
        let channelCount = inputFormat.channelCount

        let processor = AudioCaptureProcessor(
            inputSampleRate: sampleRate,
            channelCount: channelCount,
            onChunk: onChunk
        )

        // Buffer = 1024 Samples → schnellere Chunks für niedrigere Latenz
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, time in
            processor.handleTap(buffer, time)
        }

        try engine.start()
        return engine
    }

    private var audioChunkCount = 0

    private func startAudioCapture() {
        guard captureEngine == nil else { return }
        audioChunkCount = 0

        weak let manager = self

        do {
            let engine = try Self.configureCaptureEngine { samples, level in
                Task { @MainActor in
                    guard let mgr = manager, mgr.state != .disconnected else { return }
                    mgr.audioLevel = level
                    mgr.sendAudioChunk(samples)
                    mgr.audioChunkCount += 1
                    // Alle 100 Chunks (~2s) Level loggen für Diagnose
                    if mgr.audioChunkCount % 100 == 1 {
                        print("[EL-ConvAI] Audio → Level: \(String(format: "%.3f", level)), Samples: \(samples.count), Chunk #\(mgr.audioChunkCount)")
                    }
                }
            }
            captureEngine = engine
            print("[EL-ConvAI] Audio Capture gestartet (Sensitivity: \(UserDefaults.standard.double(forKey: "kobold.voice.micSensitivity")))")
        } catch {
            print("[EL-ConvAI] Audio Capture Fehler: \(error)")
            state = .error("Mikrofon: \(error.localizedDescription)")
        }
    }

    private func stopAudioCapture() {
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil
        audioLevel = 0
    }

    // MARK: - Send Audio (Float → Int16 → Base64 → WebSocket)

    private func sendAudioChunk(_ samples: [Float]) {
        guard let ws = webSocket else { return }

        // Gain aus Mikrofon-Empfindlichkeit berechnen (1=1x, 5=3x, 7=5x, 10=10x)
        let sensitivity = UserDefaults.standard.double(forKey: "kobold.voice.micSensitivity")
        let sens = sensitivity > 0 ? sensitivity : 7.0
        let gain = Float(max(1.0, sens * 1.2 - 1.4))  // 1→0.6(→1), 5→4.6, 7→7, 10→10.6

        // Float32 → Int16 PCM (16-bit signed LE) mit Gain
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            let amplified = sample * gain
            let clamped = max(-1.0, min(1.0, amplified))
            let int16Val = Int16(clamped * 32767.0)
            pcmData.append(withUnsafeBytes(of: int16Val.littleEndian) { Data($0) })
        }

        let base64 = pcmData.base64EncodedString()
        let json = "{\"user_audio_chunk\":\"\(base64)\"}"

        ws.send(.string(json)) { error in
            if let error {
                print("[EL-ConvAI] Send-Fehler: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive Messages (WebSocket Loop)

    private func receiveMessages() async {
        guard let ws = webSocket else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    await handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        print("[EL-ConvAI] WebSocket-Fehler: \(error)")
                        self.state = .error("Verbindung verloren")
                        self.stopAudioCapture()
                        self.stopPlayback()
                    }
                }
                break
            }
        }
    }

    // MARK: - Message Dispatch

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        await MainActor.run {
            switch type {
            case "conversation_initiation_metadata":
                handleInitMetadata(json)

            case "audio":
                if let event = json["audio_event"] as? [String: Any],
                   let audioBase64 = event["audio_base_64"] as? String {
                    if state != .agentSpeaking { state = .agentSpeaking }
                    playAudioChunk(audioBase64)
                }

            case "user_transcript":
                if let event = json["user_transcription_event"] as? [String: Any],
                   let transcript = event["user_transcript"] as? String {
                    userTranscript = transcript
                    onUserTranscript?(transcript)
                    print("[EL-ConvAI] User: \(transcript)")
                }

            case "agent_response":
                if let event = json["agent_response_event"] as? [String: Any],
                   let response = event["agent_response"] as? String {
                    agentResponse = response
                    onAgentResponse?(response)
                    print("[EL-ConvAI] Agent: \(response)")
                }

            case "agent_response_correction":
                if let event = json["agent_response_correction_event"] as? [String: Any],
                   let response = event["agent_response"] as? String {
                    agentResponse = response
                }

            case "interruption":
                print("[EL-ConvAI] Interruption")
                stopPlayback()
                state = .listening

            case "user_started_speaking":
                state = .userSpeaking
                stopPlayback()

            case "agent_stopped_speaking":
                state = .listening

            case "ping":
                if let event = json["ping_event"] as? [String: Any],
                   let eventId = event["event_id"] as? Int {
                    let pong = "{\"type\":\"pong\",\"event_id\":\(eventId)}"
                    webSocket?.send(.string(pong)) { _ in }
                }

            case "client_tool_call":
                // Zukunft: Tool-Calls vom ElevenLabs-Agent
                print("[EL-ConvAI] Tool-Call empfangen (nicht implementiert)")

            default:
                print("[EL-ConvAI] Unbekannter Typ: \(type)")
            }
        }
    }

    // MARK: - Init Metadata (Connection handshake)

    private func handleInitMetadata(_ json: [String: Any]) {
        if let metadata = json["conversation_initiation_metadata_event"] as? [String: Any] {
            if let convId = metadata["conversation_id"] as? String {
                conversationId = convId
            }

            // Audio-Output-Format vom Server parsen
            if let agentOutput = metadata["agent_output_audio_format"] as? String {
                outputEncoding = agentOutput
                if agentOutput.contains("22050") {
                    outputSampleRate = 22050
                } else if agentOutput.contains("44100") {
                    outputSampleRate = 44100
                } else {
                    outputSampleRate = 16000
                }
            }
        }

        state = .listening
        startAudioCapture()
        setupPlaybackEngine()
        print("[EL-ConvAI] Verbunden (ID: \(conversationId.prefix(12))…, Output: \(outputEncoding))")
    }

    // MARK: - Audio Playback (AVAudioPlayerNode für Streaming)

    private func setupPlaybackEngine() {
        guard playbackEngine == nil else { return }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(outputSampleRate),
            channels: 1,
            interleaved: true
        ) else {
            print("[EL-ConvAI] Playback-Format ungültig")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            node.play()
            playbackEngine = engine
            playerNode = node
            playbackFormat = format
            print("[EL-ConvAI] Playback Engine gestartet (\(outputSampleRate)Hz)")
        } catch {
            print("[EL-ConvAI] Playback Engine Fehler: \(error)")
        }
    }

    private func playAudioChunk(_ base64: String) {
        guard let node = playerNode,
              let format = playbackFormat,
              let pcmData = Data(base64Encoded: base64) else { return }

        let sampleCount = pcmData.count / 2  // 16-bit = 2 bytes pro Sample
        guard sampleCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // PCM-Daten in Buffer kopieren
        pcmData.withUnsafeBytes { rawPtr in
            if let src = rawPtr.baseAddress {
                memcpy(buffer.int16ChannelData![0], src, pcmData.count)
            }
        }

        node.scheduleBuffer(buffer)
    }

    private func stopPlayback() {
        playerNode?.stop()
        playerNode?.play()  // Ready-State für nächste Chunks
    }

    private func teardownPlayback() {
        playerNode?.stop()
        playbackEngine?.stop()
        playbackEngine = nil
        playerNode = nil
        playbackFormat = nil
    }

    // MARK: - Helpers

    var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    var isActive: Bool {
        switch state {
        case .connecting, .listening, .userSpeaking, .agentSpeaking:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch state {
        case .disconnected: return "Getrennt"
        case .connecting: return "Verbinde…"
        case .listening: return "Höre zu…"
        case .userSpeaking: return "Du sprichst…"
        case .agentSpeaking: return "Kobold spricht…"
        case .error(let msg): return "Fehler: \(msg)"
        }
    }

    var statusColor: String {
        switch state {
        case .disconnected: return "secondary"
        case .connecting: return "orange"
        case .listening: return "green"
        case .userSpeaking: return "blue"
        case .agentSpeaking: return "purple"
        case .error: return "red"
        }
    }
}
