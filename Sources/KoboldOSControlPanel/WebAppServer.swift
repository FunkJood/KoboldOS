import Foundation
import Network
import KoboldCore

// MARK: - WebAppServer — Local HTTP server serving a full mirror of the native UI

final class WebAppServer: @unchecked Sendable {
    static let shared = WebAppServer()

    /// WebGUI files are stored here so the agent can modify them via file tool
    static let webGUIDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KoboldOS").appendingPathComponent("webgui").path
        return base
    }()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _isRunning = false
    private var config: WebAppConfig?

    // Cloudflare Tunnel
    private var tunnelProcess: Process?
    private var _tunnelURL: String?
    private var _tunnelRunning = false

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var tunnelURL: String? {
        lock.lock(); defer { lock.unlock() }
        return _tunnelURL
    }

    var isTunnelRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _tunnelRunning
    }

    struct WebAppConfig: Sendable {
        let port: Int
        let daemonPort: Int
        let daemonToken: String
        let username: String
        let password: String

        var basicAuthExpected: String {
            let creds = "\(username):\(password)"
            return "Basic " + Data(creds.utf8).base64EncodedString()
        }
    }

    /// Current WebGUI version — bump when HTML changes to auto-update on-disk copy
    private static let webGUIVersion = "v0.3.76"

    /// Write default index.html to disk if not present or outdated (agent can then edit it)
    func ensureWebGUIFiles() {
        let fm = FileManager.default
        let dir = Self.webGUIDir
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let indexPath = (dir as NSString).appendingPathComponent("index.html")
        let html = Self.buildHTML()
        let versionTag = "<!-- KoboldOS WebGUI \(Self.webGUIVersion) -->"
        if let existing = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            if !existing.contains(versionTag) {
                try? html.write(toFile: indexPath, atomically: true, encoding: .utf8)
            }
        } else {
            try? html.write(toFile: indexPath, atomically: true, encoding: .utf8)
        }
    }

    func start(port: Int, daemonPort: Int, daemonToken: String, username: String, password: String) {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        let cfg = WebAppConfig(port: port, daemonPort: daemonPort, daemonToken: daemonToken, username: username, password: password)
        config = cfg
        lock.unlock()

        // Write default WebGUI files to disk on first start
        ensureWebGUIFiles()

        do {
            let params = NWParameters.tcp
            let newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

            newListener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global())
                self?.handleConnection(conn, config: cfg)
            }
            newListener.start(queue: .global())

            lock.lock()
            listener = newListener
            _isRunning = true
            lock.unlock()
        } catch { return }
    }

    func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        _isRunning = false
        lock.unlock()
        stopTunnel()
    }

    // MARK: - Cloudflare Tunnel

    /// Check if cloudflared is installed
    static func isCloudflaredInstalled() -> Bool {
        let paths = ["/usr/local/bin/cloudflared", "/opt/homebrew/bin/cloudflared", "/usr/bin/cloudflared"]
        for p in paths {
            if FileManager.default.fileExists(atPath: p) { return true }
        }
        // Check via which
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["cloudflared"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Install cloudflared via brew
    static func installCloudflared(completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global().async {
            // Find brew binary (not in PATH when launched from GUI app)
            let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            guard let brew = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                completion(false)
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: brew)
            task.arguments = ["install", "cloudflared"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                completion(task.terminationStatus == 0)
            } catch {
                completion(false)
            }
        }
    }

    /// Saved tunnel name for persistent tunnels (nil = quick tunnel)
    static var savedTunnelName: String? {
        get { UserDefaults.standard.string(forKey: "kobold.tunnel.name") }
        set { UserDefaults.standard.set(newValue, forKey: "kobold.tunnel.name") }
    }

    /// Check if user has logged in to Cloudflare (cert.pem exists)
    static var isCloudflareLoggedIn: Bool {
        let certPath = (NSHomeDirectory() as NSString).appendingPathComponent(".cloudflared/cert.pem")
        return FileManager.default.fileExists(atPath: certPath)
    }

    /// Setup a named tunnel for persistent URL (one-time)
    static func setupNamedTunnel(name: String, completion: @escaping @Sendable (Bool, String?) -> Void) {
        DispatchQueue.global().async {
            let paths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
            guard let binary = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                completion(false, "cloudflared nicht gefunden")
                return
            }

            // Create named tunnel
            let task = Process()
            task.executableURL = URL(fileURLWithPath: binary)
            task.arguments = ["tunnel", "create", name]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                completion(false, error.localizedDescription)
                return
            }

            if task.terminationStatus == 0 {
                savedTunnelName = name
                completion(true, nil)
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // Tunnel may already exist — check and save name
                if output.contains("already exists") {
                    savedTunnelName = name
                    completion(true, nil)
                } else {
                    completion(false, output)
                }
            }
        }
    }

    /// Start Cloudflare tunnel — named if configured, otherwise quick tunnel
    func startTunnel(localPort: Int) {
        lock.lock()
        guard !_tunnelRunning else { lock.unlock(); return }
        lock.unlock()

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }

            // Find cloudflared binary
            let paths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
            guard let binary = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)

            let tunnelName = Self.savedTunnelName
            let isNamed = tunnelName != nil && Self.isCloudflareLoggedIn

            if isNamed, let name = tunnelName {
                // Named tunnel — persistent URL via Cloudflare DNS
                // Write config.yml for this session
                let configDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/KoboldOS")
                let configPath = (configDir as NSString).appendingPathComponent("cloudflared-config.yml")
                let credDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cloudflared")
                // Find credentials file (tunnel-id.json)
                let fm = FileManager.default
                let credFiles = (try? fm.contentsOfDirectory(atPath: credDir))?.filter { $0.hasSuffix(".json") && $0 != "config.json" } ?? []
                let credFile = credFiles.first.map { (credDir as NSString).appendingPathComponent($0) } ?? ""

                let config = """
                tunnel: \(name)
                credentials-file: \(credFile)

                ingress:
                  - service: http://localhost:\(localPort)
                """
                try? config.write(toFile: configPath, atomically: true, encoding: .utf8)

                proc.arguments = ["tunnel", "--config", configPath, "run", name]
            } else {
                // Quick tunnel — random URL, no account needed
                proc.arguments = ["tunnel", "--url", "http://localhost:\(localPort)", "--no-autoupdate"]
            }

            let errPipe = Pipe()
            proc.standardError = errPipe  // cloudflared outputs URL to stderr
            let outPipe = Pipe()
            proc.standardOutput = outPipe

            do {
                try proc.run()
            } catch { return }

            self.lock.lock()
            self.tunnelProcess = proc
            self._tunnelRunning = true
            self.lock.unlock()

            // Read stderr to find the tunnel URL
            let errHandle = errPipe.fileHandleForReading
            DispatchQueue.global().async { [weak self] in
                while proc.isRunning {
                    let data = errHandle.availableData
                    if data.isEmpty { break }
                    let output = String(data: data, encoding: .utf8) ?? ""

                    // Quick tunnel URL pattern
                    if let range = output.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                        let url = String(output[range])
                        self?.lock.lock()
                        self?._tunnelURL = url
                        self?.lock.unlock()
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: Notification.Name("koboldTunnelURLReady"), object: url)
                        }
                    }
                    // Named tunnel: URL comes from DNS config — report tunnel name as "connected"
                    if isNamed, output.contains("Registered tunnel connection") {
                        let url = "https://\(tunnelName ?? "").cfargotunnel.com"
                        self?.lock.lock()
                        if self?._tunnelURL == nil {
                            self?._tunnelURL = url
                        }
                        self?.lock.unlock()
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: Notification.Name("koboldTunnelURLReady"), object: url)
                        }
                    }
                }
            }
        }
    }

    func stopTunnel() {
        lock.lock()
        tunnelProcess?.terminate()
        tunnelProcess = nil
        _tunnelRunning = false
        _tunnelURL = nil
        lock.unlock()
    }

    // MARK: - Connection Handling

    private func handleConnection(_ conn: NWConnection, config: WebAppConfig) {
        accumulateRequest(conn: conn, config: config, accumulated: Data())
    }

    /// Read data until we have the full HTTP body (Content-Length) before processing
    private func accumulateRequest(conn: NWConnection, config: WebAppConfig, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else {
                conn.cancel()
                return
            }

            var total = accumulated
            total.append(data)

            // Check if we have the full request
            guard let raw = String(data: total, encoding: .utf8),
                  let headerEnd = raw.range(of: "\r\n\r\n") else {
                if isComplete {
                    // Connection closed — process what we have
                    let raw = String(data: total, encoding: .utf8) ?? ""
                    self.processRequest(raw: raw, conn: conn, config: config)
                } else {
                    // Need more data for headers
                    self.accumulateRequest(conn: conn, config: config, accumulated: total)
                }
                return
            }

            // Parse Content-Length to know how much body to expect
            let headerStr = String(raw[..<headerEnd.lowerBound])
            let contentLength = headerStr.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0

            let bodyBytes = total.count - raw[..<headerEnd.upperBound].utf8.count
            if bodyBytes >= contentLength || isComplete || contentLength == 0 {
                self.processRequest(raw: raw, conn: conn, config: config)
            } else {
                // Need more body data
                self.accumulateRequest(conn: conn, config: config, accumulated: total)
            }
        }
    }

    private func processRequest(raw: String, conn: NWConnection, config: WebAppConfig) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    kv[1].trimmingCharacters(in: .whitespaces)
            }
        }

        // Public routes — no auth required (PWA, favicons, HTML shell)
        let cleanPath = path.components(separatedBy: "?").first ?? path
        if cleanPath == "/favicon.png" || cleanPath == "/favicon.ico" || cleanPath == "/apple-touch-icon.png" || cleanPath == "/apple-touch-icon-precomposed.png" {
            serveFavicon(conn: conn); return
        } else if path == "/manifest.json" {
            serveManifest(conn: conn); return
        } else if path == "/" || path == "/index.html" {
            serveHTML(conn: conn); return
        }

        // CORS preflight
        if method == "OPTIONS" {
            let resp = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Max-Age: 86400\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        // Twilio-Pfade direkt zum Daemon durchleiten (KEIN Auth — Twilio sendet keinen)
        if cleanPath.hasPrefix("/twilio/") {
            if (headers["upgrade"] ?? "").lowercased() == "websocket" {
                // WebSocket-Upgrade: Raw-TCP-Proxy zum Daemon (für Twilio Media Streams)
                proxyWebSocketToDaemon(raw: raw, conn: conn, config: config)
            } else {
                // HTTP-Request (Webhook): Normal proxyen
                proxyToDaemon(method: method, path: cleanPath, headers: headers, raw: raw, conn: conn, config: config)
            }
            return
        }

        // Basic Auth check (API routes only) — read credentials dynamically from UserDefaults
        let auth = headers["authorization"] ?? ""
        let currentUser = UserDefaults.standard.string(forKey: "kobold.webapp.username") ?? config.username
        let currentPass = UserDefaults.standard.string(forKey: "kobold.webapp.password") ?? config.password
        let expectedAuth = "Basic " + Data("\(currentUser):\(currentPass)".utf8).base64EncodedString()
        if auth != expectedAuth && auth != config.basicAuthExpected {
            let unauthBody = "{\"error\":\"Unauthorized\"}"
            let resp = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nContent-Length: \(unauthBody.utf8.count)\r\nConnection: close\r\n\r\n\(unauthBody)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        // Auth-Check-Endpoint — wer hier ankommt, hat Basic-Auth bestanden
        if path == "/api/auth/check" {
            let okBody = "{\"authenticated\":true}"
            let okResp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(okBody.utf8.count)\r\nConnection: close\r\n\r\n\(okBody)"
            conn.send(content: okResp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        if false {
            // placeholder — HTML served above
        } else if path == "/v1/chat/completions" && method == "POST" {
            // OpenAI-kompatibler Proxy → Daemon (für ElevenLabs Custom LLM und andere externe Dienste)
            proxyToDaemon(method: method, path: path, headers: headers, raw: raw, conn: conn, config: config)
        } else if path.hasPrefix("/api/") {
            let daemonPath = String(path.dropFirst(4))
            if daemonPath == "/agent/stream" {
                proxySSE(method: method, path: daemonPath, headers: headers, raw: raw, conn: conn, config: config)
            } else {
                proxyToDaemon(method: method, path: daemonPath, headers: headers, raw: raw, conn: conn, config: config)
            }
        } else {
            // Try serving static file from webgui directory
            serveStaticFile(path: path, conn: conn)
        }
    }

    // MARK: - Proxy to Daemon

    private func proxyToDaemon(method: String, path: String, headers: [String: String], raw: String, conn: NWConnection, config: WebAppConfig) {
        // Read token dynamically (may have been regenerated since WebApp start)
        let currentToken = UserDefaults.standard.string(forKey: "kobold.authToken") ?? config.daemonToken
        let currentPort = UserDefaults.standard.integer(forKey: "kobold.port")
        let port = currentPort > 0 ? currentPort : config.daemonPort

        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            conn.cancel(); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        // Originalen Content-Type weiterleiten (Twilio sendet form-urlencoded, API sendet JSON)
        let originalContentType = headers["content-type"] ?? "application/json"
        req.setValue(originalContentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty {
                req.httpBody = bodyStr.data(using: .utf8)
            }
        }

        URLSession.shared.dataTask(with: req) { data, response, _ in
            let httpResp = response as? HTTPURLResponse
            let status = httpResp?.statusCode ?? 500
            // Content-Type vom Daemon übernehmen (text/xml für Twilio, application/json für API)
            let contentType = httpResp?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            let body = data ?? Data()
            let resp = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var fullResp = resp.data(using: .utf8)!
            fullResp.append(body)
            conn.send(content: fullResp, completion: .contentProcessed { _ in conn.cancel() })
        }.resume()
    }

    // MARK: - SSE Streaming Proxy

    /// Delegate that forwards each received chunk immediately to the client NWConnection
    private final class SSEProxyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let conn: NWConnection
        private var headersSent = false

        init(conn: NWConnection) {
            self.conn = conn
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                         completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status >= 400 {
                // Forward error status to client so WebGUI can detect failures
                let errorBody = "{\"error\":\"Daemon returned \(status)\"}"
                let resp = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(errorBody.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(errorBody)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in self.conn.cancel() })
                completionHandler(.cancel)
                return
            }
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-store\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\nX-Accel-Buffering: no\r\n\r\n"
            conn.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })
            headersSent = true
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            conn.cancel()
        }
    }

    /// Keep strong references to SSE sessions so delegates are not deallocated
    private var _activeSessions: [ObjectIdentifier: URLSession] = [:]
    private let _sessionsLock = NSLock()

    private func proxySSE(method: String, path: String, headers: [String: String], raw: String, conn: NWConnection, config: WebAppConfig) {
        let currentToken = UserDefaults.standard.string(forKey: "kobold.authToken") ?? config.daemonToken
        let currentPort = UserDefaults.standard.integer(forKey: "kobold.port")
        let port = currentPort > 0 ? currentPort : config.daemonPort

        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            conn.cancel(); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty {
                req.httpBody = bodyStr.data(using: .utf8)
            }
        }

        let delegate = SSEProxyDelegate(conn: conn)
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        let key = ObjectIdentifier(session)

        _sessionsLock.lock()
        _activeSessions[key] = session
        _sessionsLock.unlock()

        let task = session.dataTask(with: req)
        // Cleanup when session completes: observe stateChanged on NWConnection
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                task.cancel()
                session.invalidateAndCancel()
                self?._sessionsLock.lock()
                self?._activeSessions.removeValue(forKey: key)
                self?._sessionsLock.unlock()
            }
        }
        task.resume()
    }

    // MARK: - Serve HTML (from disk, fallback to inline)

    private func serveHTML(conn: NWConnection) {
        let indexPath = (Self.webGUIDir as NSString).appendingPathComponent("index.html")
        let html: String
        if let diskHTML = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            html = diskHTML
        } else {
            html = Self.buildHTML()
        }
        let body = html.data(using: .utf8) ?? Data()
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var fullResp = resp.data(using: .utf8)!
        fullResp.append(body)
        conn.send(content: fullResp, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Base64-encoded KoboldOS logo PNG (64x64)
    private static let faviconBase64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAeGVYSWZNTQAqAAAACAAEARoABQAAAAEAAAA+ARsABQAAAAEAAABGASgAAwAAAAEAAgAAh2kABAAAAAEAAABOAAAAAAAAAJAAAAABAAAAkAAAAAEAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAQKADAAQAAAABAAAAQAAAAACU3PoRAAAACXBIWXMAABYlAAAWJQFJUiTwAAABzWlUWHRYTUw6Y29tLmFkb2JlLnhtcAAAAAAAPHg6eG1wbWV0YSB4bWxuczp4PSJhZG9iZTpuczptZXRhLyIgeDp4bXB0az0iWE1QIENvcmUgNi4wLjAiPgogICA8cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIvMjItcmRmLXN5bnRheC1ucyMiPgogICAgICA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIgogICAgICAgICAgICB4bWxuczpleGlmPSJodHRwOi8vbnMuYWRvYmUuY29tL2V4aWYvMS4wLyI+CiAgICAgICAgIDxleGlmOkNvbG9yU3BhY2U+MTwvZXhpZjpDb2xvclNwYWNlPgogICAgICAgICA8ZXhpZjpQaXhlbFhEaW1lbnNpb24+MTAyNDwvZXhpZjpQaXhlbFhEaW1lbnNpb24+CiAgICAgICAgIDxleGlmOlBpeGVsWURpbWVuc2lvbj4xMDI0PC9leGlmOlBpeGVsWURpbWVuc2lvbj4KICAgICAgPC9yZGY6RGVzY3JpcHRpb24+CiAgIDwvcmRmOlJERj4KPC94OnhtcG1ldGE+CsHtO6kAACE1SURBVGgF3Xp5dGRndef9vre/WiRVqbRvvS/qfXO7u8G4bQMxNrbxRmgDwWEZk8Cc5DAzyWQIBE44OMPiZAgDE0LAYIw9MVvs4IW2AYPb7m73onZvUqsltZaSSipJpdre/s3vK8ltGzDkZP6Yc+ad6upXVU/v3eV37/19937EcND/1cFo6Qavd6fLF7zeY/7dAvy7//D1JPl/8P3v1kFTlfaU2p1Wm5MsYZKpk6aRoXPGSVU5MaaqTNG4/F9TmKIzJuAKrhlEAgcRrmTy/ygiEeGbKPSjICARiigK/CAMozAQgR+FoQgj5gVioULZORqZCYdnPM8Pf7tVfpsC6YS2d6W+uV10psM6O9KUyDTJtphpkB1TVZVMW1E1w7RUzTQVVVd0TTXjqq4zRWGqSVKHmtwAKTQQAQUQthq6ldBzROiHnhdAwDBwStVKyXeqUbUqPJ/8QDguL1TU8Vnl8BB75qw7veC9nhq/WQGF8zetta5dEzXYnqpGhsFsk+S7zQ2daTozLU3XFdPWFc3QbQtacE1XjDg3YrA9U1Q4BH6B9aEBkcIItoedPchde/civyJ8R0RB6HteueyWytWKWy5CI+E6olIVDnQMyXVYvmw9fpY/eaoE9X9dDfXXv4qb6jt3mptbHcZDYMO2OExu6iIe47G4ouncMDXARbdNzTA021YNC0Kr0MGwmZFgikEcTlBJUYhpgA0xnBCLPAohcSRgfr/EfZVCE/IrkU+CmAi5CiP41UqgaXiugOE8/AWJpKjctkXtabDvP+SUnOBXBP5VBWxDuXuPvrqxyjVhGVxTCba3TIpZzI6RYTHDMkzbVHXTiMU5vGDYcAQwI6W3U0wxSdVJsaT59SRxE8JJ8CBioioFVRa6wp0XjiDdEEGVIxD8qhY4TPhcBSA1RfMNy9dKgcIDzxMcugtWroQ7uysx3fryT0XZfU1UKK9WiHP+7j12b1MVj4vFmG1RzKS4zXAO28dimmFbpm0Zlo4TPWapML8N2JiKpalJwMvkXPAwIKckyrNUzTFvmLxJUcqKSp55JS4qTAm4GnFF1MIi5PAS4l8ECBOOjADsKlw6hAnEkcIEMMiRBRQCfNKxoDFhHbsU1HLDkuCv8cBVa+2t7S5+gdXx0nWyEK82XkzVuAq0J+KaoSFYgRzFULnOtQQud+fzXv/RiYsXS9VSaCpeKlHsbgtaO5REZzfxWGVsZGJ0fjyr5AqW48OBVteyhrUrk6lWnRDrVcGEBREVQ1e8QNEAM8gdIbkhTxCXWQrBEIVUCsUVPd6FmdhTp4qX7f6KAklLffOaiLFA17iuyXSJhBOLcdNk0MSMaXZdHPGKJANNuMaVeBwe6Htp9kc/mRiYmCt7JdP2TYsAogzxhcAQaqKVm1w1Z+LKoBGe8osj+dkS4OOQf1ixlcSqlsabb+jecuWyyIuJhSkWWAy/cW6EPrDEqxUiFgQIe2RbZF/kYVZ1gt9brx4eVAuVpWB4BUJXr7N2dHmIN8tkQI7ED1Btc9PmVgy2N02Y34oppqGaOo8nWTJ18PGX/uqfTmcXZoZyzkg+Gp9nExU2FzBHEdwOYg1MN7SKXxmezZ2bLp2ZjPqzdGGSjeZYNh/NlZ2Z4uzDj19KsvL6K7ZxPUawM0e+koUDB5IW0lAkzS8A6cVyHwlma1HRN/uzS4l1SQFg786deoPlQnNDk9InEmTZSJcS4QC9FY9pZozrtmLFlUSd0rqhMj2VGz9xoeBduCgGp1hFIWEyNSH0GNMR1QbTjAjRX/HcgVxxaDqcKtBcheartFARC2WayhGqX1uX2NU135FqMruuEsJBtgVYAQ+ogbBGJKCAIChkccS3QqbkIIhMTf/5+aVIWIJQU53WWh8y1CbUWkMGrqkzCzXL4ipKsQ7MIK9zWAjZhpJtItZrxEd62itWjCPWQk+QCdORBrBZSFZIocwLyQsjJ3DnyoETylyK1GoYOGHIpTxAIafWbtbRgC+RptpZbB4CCjGnmCEFHkJCDQMD2EfRDkKgSNWYoQvfZ12poLlem5iV4QrfyKOjgVtagLxp1KBvWkwH9A3gB5FrqKpS4wIhEoX0MGJMMM/Vc3MUamy+SFzIHKIZAuGesCluySpcYw+wn6SLCpP1O2bDq6jfUhmNMWRJoSmTBc3zY0QxwZA3kgxY0vDgmHQ10rSmIX+gSEJ6hQtdgX1Z3Ix6GqWjcCx5oLkOJkfgI3bZYvpXFVRc1CuuGCAIBnKQIvGkwW6CqyQU1eoaHGRNrbxYDmWlxb1UQvTHLEpZQuXgPBGPfF1BgUJiiOqRb2JsYYGAESiFK12P2tv4bNaz6lYLSpOSJt1jkUPegkAQgKyYBu4ibxSifIeeARyJAC7RotZ6ialXFIgDsopQFckXdB3SIYXJeEJ6xvNUZEzwB9gZyEBtI+AdxlpZmVbbtuMKgjWqoGfI1kLEQuoNMoYVX56pX926FYncco+PsqnAcQ6K2ZyBzCnlUHRCGHa2CHUs0lObItyFWUJWQFwBuCL/E3Id7CYCHjiSQSIlAoSIASDW0uDgVykAHgnBcBF4IzwOTeBxTY3gOF0qpyExEFQC/QTMgRVCnsmYlLBiJTNB7jSZDrXP0M56a1nQuylW3LBu7tKQ7kT1LGKJgn/9Rv1sJT17vtGaGWK5oFBi4EZWipIICUqRtYxEGaUNjyeGUDSFESe/xHx8IcMCXtcNBdQVgiGn+xqQ+VoFwHghpEz5GjSR74oikH9UJWQUSjLEdEJ+UWEenYwEId5ZfaY1/cT3imtN00i5liC1Qs5YdDE3uqGHnu9r/MY3zjQ2nIe1p/P03vfvspXiyRM51ODOMqu3qUrkK+Zzj4Tv2NZK1EQ0TFSiaBYKCM1iPh5nU+AztQo+FvoAYgj27vsRCjNsfXkVthQDKN86PAAQw77IFbrQmFBRz5HCRASmRSYWAQkyGpiVBlerBY/WypX18c3PFfqPXHTCCrOIWiy3MTV1w9X1s5GaK5EDLiqoUKFcJewg5+zgfKlMqBULJGCKlV3quroNqahM4GyEOLZJScC3Ug0F+VSVSU83uQ9uB4YXhKjUXojcKDyJ9sVjSYFFbIPxI2FaJrcsmSv0hM6T9SzZhCBgZpLsRrI6uNFRe1iaqNURCaFmx8YXShWZRXFI6mzqzkilvrvSu2ZZd3MDQuNCNp9yi6WRadXWVMfHZXB/0aXp+WKisVQVNlEzZ0npVWqIlElZdf05YgmuG8y1mTbHeYRUDToBlyAFw8q/6gHcU9q+hiILNK5OA19hTT2wNByAaGKJVrJaqVyYGvxFNlvi3Eo1bprIBy+cmkfEm1x0maKnnq1ZSVqmZ2Zy/Jad2X1/3mW3v0cIvTL9j9R37nvPB/u2NgaFyYFhOp9ngyUBxJ48XYqt9IePfXomN8K5n2lq7FixhidaSLgR+B8PuJVUMiu04iwfeZGmZ0Dm4QTEKkjg4rHkAXgE30IHZDfUJrNnfc5VTzx1cqZQLpdKTpl5VRMc/pd98zl4MkEtzdTRSLpgUzGmWMLgNFmhiZCer5KV6d/cy06c0dYUhnes+hSy0NGz5QsTYT+PXngx6+TBtgR3UYYpUmgknIiH0ZEH//rCJGUnaG6aOjR60456NQEseIYVJU21HqbavrGzZ2tYfVarekA1hP9VD4RysQrSjkLOUMx4Zu3Rx45+v29kdpLWruRXbIt3Nlvj4+GUrpz8QTj2gkykVj1r7aANa+nWu1BD+OgIm/VEqlUs66bmJmpvpEyd1hCr0xS+qyvsnK92j4v1e9jYKCvmeZMlli+Xiej46ejBpyk7RuU5GQjtnbT27cam/XZbuzIxVfzlkYVzpzy7+dJ8Obrr/Xcy45iiFJFJa9TotVlIqrVImFBkiUcLY2++5a2D2dyzkzOfvzdKp4vXXxf+yT0tN34y9cG7Ln327ysPPSiqeTE8T7kxevLHIhGPetexXVvZqhV6QwrVk8eZqLO0pB2ihBEzK4VwRTzsXM5LmfDCYHDoSPTok6KwILDsgehRgOUN3XYX/9gHYxtXL+8f8u77n6OPPVGZno6uu5HW1affceA/iDJc6EA6gAc6oBS+BkKSO9X6C8j3URAF2XN6svn3b7/Ni76ZrmNnBivPPFd+7MmLn/yzhgO3qp/4U+5b4rtfifbdwm54KwOQZnLUf1o88qNodi5qaeE7tqpbNmrLu9XGBo64mp1XLw5FJ88ER49Fo2Nhso42b2Hv+yBrbiWXsUcfp58/HL3tAP/Yh9T2RvsbD0188jN5LRa1r2bXvllZ1s3ed/sBO+6EF06hdQGxwTtlvVqS/2UqARoLDwBF4N8+FtxuoEydzay9+or1m7q6h3tWUldH+VsP0B99bHZ4WH/Pe/Vy1QXb2bqd9WTk0md3L6u7kQW+cmGQnn1eHD4cPX0QsYPaVEvDqFkW6+7me3ez/Vfpa1bDRX6xKqbmCLR081Zx6Ec0XxTVgH3uS/Nf+B/uG65ht91BeNDONWpaX9fR2xldepLKeWQhyI1VtaRii/T6MhdCbsILfgD5k9QD5bo4yyZO77rqiu8/MLJ/dyN6IDffFBx+gX32Pi801EtDorObaQGNXxI9HaylQ3Q224LWr+nkV195MTvD5hdU0B7fUZETFSNsqFfr67y2RvC8FVxF3jw7kRu/NE5joySqrHsZZUfpn/8l+OIXw/pGdtttrKOZbVqWyvd7e++4KSoMUGEcMIP84AmwNQpTLWNLEL1cyBAXjLkuSJRsMEV+GLkOLYwb7TvbmtYXcmfXbog5QQFRW3Ho618L062UStOPHo+GjmDxILp76Jbr/dtvcnrXttVpdaXKVLGU7GwzAUs8A0vbMHRTCTcZW05qy8CFye8+UnjkX8TFi1R1adUuam+lbI6+/fUQTLSrh63sEstb46MXS82pq8yGtWH2ReJGxPwgckKhYo0j8S4bNvJYSqdburTN3egLgFDIX8DkatkqAEtuWrnhe99+fvkGzTScsWmwMD4+JnIT1LuerdtFJw7RXW9vZ1H8a9+a/84/T/WdHvJZcSDnPvVs1RZ2OqPAHBf6KycG8w7zzvcX7v38wH/++NBjTwQbV9W9+Y0tL/QVbnwn8Qod+oUIIlq/je/ZQVduE5apvvAof8u7P65p41QZFV4QOj56RqBD6BqhvD93Tjk8IBdlSx5AIQt98rgsBVhzgLsGKvogVZa/YPeu3b9/zwP/9Ow7DthX7atYCTbUT6BZG7eyzuX040axbeeej1130zNvfm8xH/ad2/zg/z6WbketDU9syt5xRxKw/NEPFk72IVxpYsjDDxs2rl+127r3L+8423c+/eOvb1zOZiz+kydDbrDde8iqsp//dHs4dvbWm++IpVvCyjEikGoFCMeyAr1HsFHU5ZdD4LIHeozN3QHgBfvLJCX9DtqEbIXOEnVdsefkc+NP/Gyyrh1sV1waprjJfu8W1ttFdTH69oNzH3r/2xtaGscK/VqSveeOXVODc4Vides2imuBX/E91ztzWrTGmw4c2LWgzorYwi3XX33N7u0f/o//69ZbFnZtI4fT4FlSYrR9N8uPigNXr96Y2tiz4xpe51PxhGzSVEt+qeg7nu+4UAB58oXz/PCAZCVLENrWo2/uChDb4AXgRZIagZCiCIEBCp80c/dbrjtycOSHj06LOrQ3SHFp805a0cL2bmcLxeIX/+6n63q6e5et7c40Dg5kczMjD/yD8pG7Wq7evX3fzu7r3xC+cV/5h49XDS2+d/uWneu2YM34mXu/vGf32AfeC6PSpRlx8Ry5dXKFMDMk5p4Y2XFTU664ommZF+VPocUkFSiXAhfAQIcCrbDwcD8/MvgqBbZ26xvafNkEVGrLCRSL2lqMq2gSGiwog2hdc/M19oL1r9+9eHogaoixrjXUkqJUkl29V922pTI0fHxm9lS5elpRJt55J1vTozSlWiNlnRAJzubn5nPreml+PivovOuetI2T731X+Ya3qkEoJufppWEaOkMvnRaxPDXr9Zs2xvyomFi+raXhQpQfispz3sJCUHXQX/EcD0GFGHjhPDs6KDsrLwdxt76+VSqAA5iRKKqtZWVTFmsXfHAXRDC/+bot77zhBmvw7MHjheUblTknaqpH9PCFgvKGPea+K2Nbe82r9sZLfvQXn/Js3Vm1PB8GIw//YPxzX/WvvZbf9jZum+zcQOaeu10SGrAwg/A9KyYm2annxO3dxpUr63Z1uEok/OT+/e+op+xhMT/lF4uB46IFjwJVa2Kjn01HBvjRi6/ywOYuY20LPiMDSRVkucY6HH1CxITsk+EHUNwq86fNnj3bN9d9+2svaHE2De/n6cHvRn/zxSDTJtasRDVUg0jJNCjbd/BLU4EZq+QXyvPl4P1/oPW0Ucnxn/jpru6ejx479+jffiV69KCoWHRyiNxJmj5GDz/07us+8se8sadj56ZrbsFi+ZCYGQkB/Yobur7v+NWS5zgRXuhQHBtWXqwpsJSFIgQG2koQvTZlCAJkXdIjFqExxkOvWkWh06IQzZVo4ai1quuPb0r/6QP5uz6gvDQgJn2x+zr2jX8M+vqi37/dX9kjuxg9HXxFj+JW9anJsFyg++4Lx7M0k9f+08fe195qg+E0NInuneyF06zNoB/+MPqL/Vb9tg0inNi8JUfeXDgxHc5OyQmIG4ae71YCp4q2OyosUCM7YAIrxdqx9N+BK+1btztIVDG0oNFZQUPORCNELuUNG11jpqGXjn4oeuZo1zS1OyXtPbf//PHx4OZ38DktmizSqgx5WdZ/VqRSrKNN/jkqcW6aYRHY1ipWruD19UqphI5TZzbLj/YNpNbDJEIpsJ8/LnZY/OEfXJFa1RbOjJMHC4cRYFP1osBzKy7s7VRwJjD4cIGiKiGt3P8L42tPYyl3uQ4wjgCAZmjJy4aHC8ygnRFqHtCDhRHqhBypsCCUlHtqKt7ecO9fp8fuyX37/nD7NpZZSVNlSnXRdZt4VGQLc7L5vGod3/8Wau3gmB4NjYRjYxFa9mpyIB6n9Rl2aYimjlPfCbGlnv39F+pT6Tnv9CjoWhjJBS8M7jvS9r4vxxxAP5IVSjAIBfTxXTnFWfTAEoQQ2r4nMFUBkKCirgIycrCFeHBKwB8aEQgJBQkYZAkdS2V0oqFV+9In9bv/m/viMaGfolUbWdsbxUQxQkMy1crQ2zLVsMAoPyYbgljzqnVy+OUW0dSiYz+jlw4LGGtDA/vKJ/TudHX++FAkFEQqDKSYGkTHGE12dmF1B5MOTNTId5mLauuR70tlFo+lLLSuVe+ul3UAMtcaGbV8VOvNgz/B/lDPrYpKKQRfAkuq+mziErq44a5eduocTZZpOkuFSbZpLcukMReSYyL0rfAk2A/AxbumEFKW4tBTj9DJo9Ku6+vYXx3gTbEQyzxc6bmRW4VxJK10HXQT8VA0mqBGjSP7VMFQyiMH5nfF6Qn11NirshAU6IECCAJApvaCGiAXkqJirYZGoi+qjrQZXATSgueVykh/winR6hY2PEF5jwrzdOYkxRS+fqVMlxgdYSCGhgZyQ9LkWJudPETf+aa4NCpt11vH/mAveh24LXpn0tuS5EguCSQDSmjFMSiDqRqehXkZ3gEn4Bz8DxY5P6ktKnA5C0ldpalqS4IQxBUrf9wUdwEEynAYvEmenKTIVb70Iz4yVnGpWKG9y5k/QCMVDOfo0Uej4y/ya6/WQSXsuogpKKPqmRPBUwejwWHpePCU5XG2ZwWVPHiSMroc/BWLMBTTZQTCiBK8QRBiCQ8dXOhQcyZcgYfCAxF6E0sh8HIQ4w9cH5ZHsxVLAtmAC2QbTsjeGON2DDlEM+LmbK40PeOVq5ihKFV0nj3QRKrCV5ZobhblecqXJVrGs9E3v+M8/Ajr6VbQ3RkccjB1hOhy+KBQV4ytTYt0inq6+Po19vINLc5sZW7GDUUVcxq3EmnoiypCtwEiUS5HEkgh5sfAGAEI0AFevXwsxcDqJq09DmjI9mGNTcjH4ZkADNrL8Tp93a33NG5+6/nnfxHEM/vv/nA80dB/fCBXDqcWxExJaPG6j/7lB5G+Tl0Yj0ywd1RvibSZmSiXi9Zu7PnC5z9Qdoqj07nGJCCn/9mnP7xl+/L6mL/zfX8e33Rr3YY3Nm96U6J9ZX76Ys/eO7vfcGbjxqszG69nenpu8HjVRSsFZpV8G04AEACngWn1zISMgSUIyRQL8i9kUxWYwYHWIqIXLdtZJ/AvqBv+MDmaLX7vl9p//dv35cvz//2rT0deItFcF9iYteQbY6lrb7qi78zYihXNeb8wnXe6UqlUfQzTlexsftuOtgPvuvZfDz6TatFWdKQa6pLbr9978PvP6K1v4cnWE489MD01u2rHjs41GyuxN6U37zv7/NHJsXE01PP9p+YmmQksYEhDMg6hADKSnBksFbCXFQBlkPHKEDdAWC2OfYmNqYoYLKLRq2jR4dz47N1/smFy/Jd3f/SZlas7v/KlW7Lj8+mm+sGxyrceOkKVgf374rfd8q5j53L3P3zsy5+59dLF6fau9OFzub6XLkWVc+NT+W/d985lbfHC7Lypvnj0ZN/bblw+ee6hz933yFiBPnS32dw6k5sdZtUfD/WduzgqJ/cjw2N1jGVMkTRk5xOGR3Bg70EIovByJV7yAIyOETKm0rV5BGGKjkRbDNmMx8bzWO96fecPuZGayVh/9+X8qdHwrnfroXP0tg89+9n/sm3Ziub2TDgzevLGP3z0S5/orYvHb31jnV8+e8cfPXL/547PWHZHsjw99pzOo2u2uvd8/CcXx/wn7t8xmJ1qTtLZ01OHS2j0skxzrjA++OUHxjJ1Exs3WruutDOZ+q/+Q/EnB/O8AcwYYQCR4ASpBpK9NHfteCULyZ/l6gVZRv4GIBWx78KhuTnRsSw8MjF39MdKx2rq3aesOK4vVId++MwlL6aWaPDJp89j5XPwuREWI64OHjkWre82L5wc2b5WyRjHf3HUb1CDs8++lDLcbN9Tw3OVZZ3a1PPPFWYc78TE4EBUtpVGncXHzxzqC05MBh/8m4s2p51rtI/cpA2+VClUWdmubaBABkX0Iq2g3w45l+R/GUJ+iIsExs/IcehOQ8sQUYg0WsLgmnWuUTA1vTBCh4+Jj34quvPdan7aW7Us+OSHMYcpP/Oz6A07VVsR992j2J574VzQprgr1/JPH+ApkbWKlElSvMS7NZF9yblnq4H8ePrFytikGJvgu1rYd25U9DBUC84jv+T33qRtaovKLgYCwdDp4NwAdgsA2+T4iAT0N6TYWFoi0SFDLXpgKRb2LLe2NXngauiiI4VBDSRVTBSnS8JVKb0aUyFx5kQ0PBZdtU/L1LNzp8P6OtxdoAdgxpVMSq+LqZalJGJKY6ORVJMN9Uq6JRVv3sKNYHrg0PTowmQxqJS8QjksVCJkiEm/bBSDNIvKGAdH0USJzs3Q9nZ1fiZAqYJYoOb1CcVxvHqTpW2mA0WBtLKHMhTynw7pz5zHX77sgUJVDg5QxwMuiwWcgJSMKU5SQyWgS8/7M/MYFYnt3bTBUqdzXjoRQo1um7paiNtU10iBGjSnGLpDiXrbSMTUtjUU20K0g2ihuy3RXTjuTV2ay7qFuahYEfli0LIQjgfR8IJAIi6XMIsgrNzQ0wBfQufG0lhHo7CNKI7pICTBTKtG5tCch3hYqqDgLB5LMTBdRhlX0ZHzA9miQ7ZCwxkjwbgug8FIs84GijQWj7Fi2QXlbkXX3qAI2zowCQZBcqrY1mEGrlqslJLcsvU0lgJNc2SfEWFVzI9602Pl2bzgRmblCntqVHXLMZvzJCbLYZvFSkV0v7HbCZWeIzrBlg0ohJFPFGLoiNQC0IPYIUoRnijM2GExVaytDC57IF8Oir4dZy6uAH5wQAfACS/UNSiNgorZEsaT6LtgZiDHnYxhkiB8gZjTVWapLK2rpqK4CwFzvfJYTpSqTBvEvhu/tID1FIeC5bA80F9dcKOFwOZKR4Jh1ih3acWxr0DmdnQaKy62TpCkApJb1uAOnlerYqAV+AZ9xVlHzWOmUjuWPADw9M9Eu1oVB0OoWmdlcbpvojehCgxX5dSstgMI6MKB2EKDVSeB0RjUkOM/bDvxEVuQA8N1bH0oukUHzWcwJ5B88BE8GlFSnClUSyDl5HgIZoHtGFAAf8ZMOTbGljbsZcO1oA+GInkARslySge2gvwjKwB0UPqn5ZrnNQrgQ9+Et6EZsKhgXSCjXXJpVA1Z3RDWcthfW/PjFoYmmWYA3l27CUpHpKD1RJVyCOVxMRYcCiacFQzGQUwkC5QsH0xzPvCwTJGTXzmOwOoEKw258kZmlJs6wHxBwCQJBeIDAKZ2f7ADwAbKwDigpR7TT04sbZSA2EtcCGdegEG33pVEzpK+ggoIBkxsZe6CT+WmK/mC5tAJneyl7TDoIIDlRkAal0iNJNHHX2BDANYP2Hwit5ihoSDpvsACHaQfRAAfI8iEVSL4uUQ2Vp7AjIQ4bgVXwNjQAcsXvBDT+Ci94UMs5UhWGczJTQaLxysK4PNkMWxtsGPwlVwFwPQyoGG8RZmWEi+uQ5wwzIuldcGdwLBrDIrB0ng8qLyMtiU1pD41ieUSJ3BlaGFtBDdC4sWXNG0gp/bAkWQ7oaQJuKErGwuyt4CfamxUgmmsaj3djw7DK7K8RgH4dbQQLMvYOsSotSeQEyRCIBYEggNkbpDQwglcAd0ktqGnHKBDVuloSI8TbO6QoktDSOsC6PgI6eUF0j/yxPHgdpwgu0syD+lxDYTGQ6tYPWLxBT7mMifAQlcuqmaD2KOnHQBkyfi1/5YK2au/wqa/t66z00oVi3EgBxEMPyB2Zb8R2y2QiAxILkGFHYxy5wQ8wCWiJMKwBUEur7BZAefy5hAXUQEr4BzfSwTiewlyKCYlxgFZQXJgJlxc0wGK1ehDzScyByrKpGM9drpaxArotcdvUAAXoCO6q8vqbUSiR2Qhh8gkI9cJeK8pA+qP1IlRD2SCbtgqijMIKTckqNIDOMGtgWDoChPgI77EN7gGUuKGeIddF4VGEwQ6wLd44QQS43swfCwAwLLcSD8xxQ9drF7OPK9W4TcrsHhFQ0zb2o7FPsVVH8GMh0r5cEvZtYalBTwAuWUzmMtuEpSBaFJ0HPJc5j65R6a2M2DxSVJiALCGYQnLmhqADeTG9UBULSUg5WH7HCsF2uAsOzbqzRRfSTuvlh7nv02BxUuxya8lqTUneQKbmVSAAQrIGaGUG4LA6hJCUhN5jpiSS3PcFp/xT4JNbsyQz5H/QMhqy2qJL1l0aykbWsEbtcwBq7OqRwsumyyEkwUUwNcgflGk/8/ef7cPXkfhy394+eR1Lvy3fv3r9/md3zD2fwD5n8frstJnEgAAAABJRU5ErkJggg=="

    private func serveFavicon(conn: NWConnection) {
        guard let data = Data(base64Encoded: Self.faviconBase64) else { send404(conn: conn); return }
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(data.count)\r\nCache-Control: public, max-age=604800\r\nConnection: close\r\n\r\n"
        var full = resp.data(using: .utf8)!
        full.append(data)
        conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveManifest(conn: NWConnection) {
        let json = """
        {"name":"KoboldOS","short_name":"KoboldOS","id":"/","start_url":"/","scope":"/","display":"standalone","background_color":"#111316","theme_color":"#111316","icons":[{"src":"/favicon.png","sizes":"64x64","type":"image/png"},{"src":"/apple-touch-icon.png","sizes":"180x180","type":"image/png"}]}
        """
        let body = json.data(using: .utf8) ?? Data()
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/manifest+json\r\nContent-Length: \(body.count)\r\nCache-Control: public, max-age=86400\r\nConnection: close\r\n\r\n"
        var full = resp.data(using: .utf8)!
        full.append(body)
        conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - WebSocket Proxy (für Twilio Media Streams)

    /// Raw-TCP-Proxy: Leitet WebSocket-Upgrades vom Client (Twilio via Cloudflare) zum Daemon durch.
    /// Verwendet NWConnection für bidirektionalen Byte-Tunnel (kein HTTP-Parsing nach dem Upgrade).
    private func proxyWebSocketToDaemon(raw: String, conn: NWConnection, config: WebAppConfig) {
        let currentPort = UserDefaults.standard.integer(forKey: "kobold.port")
        let port = currentPort > 0 ? currentPort : config.daemonPort
        let host = NWEndpoint.Host("127.0.0.1")
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))

        let daemonConn = NWConnection(host: host, port: nwPort, using: .tcp)

        // Sende den originalen HTTP-Upgrade-Request an den Daemon
        daemonConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Original-Request weiterleiten (inkl. WebSocket-Upgrade-Headers)
                if let data = raw.data(using: .utf8) {
                    daemonConn.send(content: data, completion: .contentProcessed { _ in })
                }
                // Bidirektionaler Tunnel: Daemon → Client
                self.pipeData(from: daemonConn, to: conn)
                // Bidirektionaler Tunnel: Client → Daemon
                self.pipeData(from: conn, to: daemonConn)
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }

        // Cleanup: Wenn Client disconnected → Daemon auch schließen
        conn.stateUpdateHandler = { state in
            if case .cancelled = state { daemonConn.cancel() }
            if case .failed = state { daemonConn.cancel() }
        }

        daemonConn.start(queue: .global(qos: .userInitiated))
    }

    /// Pipe: Liest Daten von einer Connection und schreibt sie in die andere (rekursiv)
    private func pipeData(from source: NWConnection, to dest: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                dest.send(content: data, completion: .contentProcessed { _ in
                    // Nächsten Chunk lesen (rekursive Weiterleitung)
                    if error == nil && !isComplete {
                        self.pipeData(from: source, to: dest)
                    }
                })
            } else if isComplete || error != nil {
                dest.cancel()
            } else {
                // Weiter lesen auch wenn kein Daten kamen
                self.pipeData(from: source, to: dest)
            }
        }
    }

    // MARK: - Serve Static Files from webgui/

    private func serveStaticFile(path: String, conn: NWConnection) {
        // Sanitize path to prevent directory traversal
        let cleaned = path.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else {
            send404(conn: conn)
            return
        }

        let filePath = (Self.webGUIDir as NSString).appendingPathComponent(cleaned)

        // Ensure resolved path stays within webgui dir
        let resolved = (filePath as NSString).standardizingPath
        guard resolved.hasPrefix(Self.webGUIDir) else {
            send404(conn: conn)
            return
        }

        guard let data = FileManager.default.contents(atPath: filePath) else {
            send404(conn: conn)
            return
        }

        let mime = Self.mimeType(for: filePath)
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var fullResp = resp.data(using: .utf8)!
        fullResp.append(data)
        conn.send(content: fullResp, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send404(conn: NWConnection) {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "js":          return "application/javascript; charset=utf-8"
        case "json":        return "application/json"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "svg":         return "image/svg+xml"
        case "ico":         return "image/x-icon"
        case "woff2":       return "font/woff2"
        case "woff":        return "font/woff"
        case "ttf":         return "font/ttf"
        default:            return "application/octet-stream"
        }
    }

    // MARK: - Full HTML Template (Apple-inspired redesign)

    private static func buildHTML() -> String {
        return """
        <!-- KoboldOS WebGUI v0.3.76 -->
        <!DOCTYPE html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <title>KoboldOS</title>
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="apple-mobile-web-app-title" content="KoboldOS">
        <meta name="theme-color" content="#111316">
        <meta name="mobile-web-app-capable" content="yes">
        <link rel="icon" type="image/png" href="/favicon.png?v=2">
        <link rel="shortcut icon" type="image/png" href="/favicon.png?v=2">
        <link rel="apple-touch-icon" href="/apple-touch-icon.png">
        <link rel="manifest" href="/manifest.json" crossorigin="use-credentials">
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
        <script src="https://unpkg.com/lucide@latest"></script>
        <style>
        :root {
          --bg: #111316;
          --bg-primary: #171a1c;
          --bg-secondary: #212429;
          --bg-tertiary: #2a2d33;
          --bg-elevated: rgba(23,26,28,0.85);
          --fill: rgba(120,120,128,0.2);
          --fill-secondary: rgba(120,120,128,0.16);
          --separator: rgba(255,255,255,0.08);
          --text: #ffffff;
          --text-secondary: rgba(235,235,245,0.6);
          --text-tertiary: rgba(235,235,245,0.3);
          --accent: #009433;
          --accent-secondary: #FFC738;
          --green: #009433;
          --orange: #FFC738;
          --red: #F24040;
          --teal: #33BFE6;
          --pink: #ff375f;
          --purple: #bf5af2;
          --radius: 12px;
          --radius-lg: 16px;
          --shadow: 0 2px 20px rgba(0,0,0,0.3);
          --transition: all 0.2s cubic-bezier(0.25,0.1,0.25,1);
        }
        * { margin:0; padding:0; box-sizing:border-box; }
        html { background: var(--bg); }
        body {
          font-family: 'Inter',-apple-system,BlinkMacSystemFont,'SF Pro Display',system-ui,sans-serif;
          font-size: 13px;
          background: var(--bg);
          color: var(--text);
          height: 100vh; height: 100dvh;
          display: flex;
          overflow: hidden;
          -webkit-font-smoothing: antialiased;
          padding-top: env(safe-area-inset-top);
          padding-bottom: env(safe-area-inset-bottom);
          padding-left: env(safe-area-inset-left);
          padding-right: env(safe-area-inset-right);
        }

        /* ─── Sidebar ─── */
        .sidebar {
          width: 220px; flex-shrink: 0;
          background: var(--bg-primary);
          display: flex; flex-direction: column;
          border-right: 0.5px solid var(--separator);
          transition: width 0.2s ease;
        }
        .sidebar.collapsed { width: 64px; }
        .sidebar.collapsed .sidebar-brand h1, .sidebar.collapsed .sidebar-brand .status,
        .sidebar.collapsed .nav-section, .sidebar.collapsed .sidebar-footer,
        .sidebar.collapsed .nav-item span { display: none; }
        .sidebar.collapsed .sidebar-brand { justify-content: center; padding: 16px 0; }
        .sidebar.collapsed .nav-item { justify-content: center; padding: 12px; }
        .sidebar.collapsed .nav-item i { margin: 0; }
        .sidebar-brand {
          padding: 14px 14px 12px; margin: 8px 12px 4px;
          display: flex; align-items: center; gap: 10px;
          background: linear-gradient(135deg, rgba(0,148,51,0.12), rgba(0,148,51,0.04));
          border: 0.5px solid rgba(0,148,51,0.1);
          border-radius: 12px; cursor: pointer;
        }
        .sidebar-brand:hover { opacity: 0.85; }
        .sidebar-brand .logo {
          width: 42px; height: 42px;
          border-radius: 11px;
          overflow: hidden;
          flex-shrink: 0;
          box-shadow: 0 0 6px rgba(0,148,51,0.25);
        }
        .sidebar-brand .logo img { width: 100%; height: 100%; object-fit: cover; }
        .sidebar-brand h1 { font-size: 15px; font-weight: 700; letter-spacing: -0.3px; }
        .sidebar-brand .status {
          margin-left: auto;
          width: 8px; height: 8px; border-radius: 50%;
          background: var(--green);
          box-shadow: 0 0 6px var(--green);
        }
        .sidebar-brand .status.offline { background: var(--red); box-shadow: 0 0 6px var(--red); }
        .nav { flex: 1; padding: 0 12px; overflow-y: auto; }
        .nav-section { font-size: 10px; font-weight: 600; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: 0.5px; padding: 16px 8px 6px; }
        .nav-item {
          display: flex; align-items: center; gap: 10px;
          padding: 9px 12px; border-radius: 8px;
          color: var(--text-secondary); font-size: 14px; font-weight: 500;
          cursor: pointer; transition: var(--transition);
          margin-bottom: 2px;
        }
        .nav-item:hover { background: var(--fill); color: var(--text); }
        .nav-item.active { background: var(--accent-secondary); color: #1a1a1a; }
        .nav-item.active i { color: #1a1a1a; }
        .nav-item i { width: 18px; height: 18px; stroke-width: 1.8; color: var(--text-tertiary); }
        .nav-item.active:hover { background: var(--accent-secondary); }
        .sidebar-footer {
          padding: 12px 16px;
          border-top: 0.5px solid var(--separator);
          font-size: 11px; color: var(--text-tertiary);
          text-align: center;
        }

        /* ─── Main Content ─── */
        .main { flex: 1; display: flex; flex-direction: column; overflow: hidden; background: var(--bg); }
        .page-header {
          padding: 18px 24px 14px;
          background: rgba(28,28,30,0.8);
          backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
          border-bottom: 0.5px solid var(--separator);
          display: flex; align-items: center; gap: 12px;
          position: sticky; top: 0; z-index: 10;
        }
        .page-header h2 { font-size: 17px; font-weight: 700; letter-spacing: -0.4px; }
        .page-header .subtitle { font-size: 11px; color: var(--text-secondary); }
        .page-body { flex: 1; overflow-y: auto; padding: 20px 24px 24px; font-size: 15px; }
        .tab { display: none; flex: 1; min-height: 0; flex-direction: column; }
        .tab.active { display: flex; }

        /* ─── Glass Card ─── */
        .glass {
          background: var(--bg-elevated);
          backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
          border: 0.5px solid var(--separator);
          border-radius: var(--radius-lg);
          padding: 16px;
          transition: var(--transition);
        }
        .glass:hover { border-color: rgba(120,120,128,0.4); }
        .glass-title { font-size: 15px; font-weight: 600; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
        .glass-title i { width: 16px; height: 16px; color: var(--accent); }

        /* ─── FuturisticBox (native match) ─── */
        .fbox {
          padding: 14px; border-radius: 12px;
          background: var(--bg-primary);
          border: 0.8px solid rgba(255,255,255,0.06);
          position: relative; overflow: hidden;
          transition: var(--transition); margin-bottom: 16px;
        }
        .fbox::before {
          content: ''; position: absolute; inset: 0;
          border-radius: 12px; pointer-events: none;
        }
        .fbox:hover { border-color: rgba(255,255,255,0.12); }
        .fbox.emerald { border-color: rgba(33,209,137,0.2); box-shadow: 0 1px 6px rgba(33,209,137,0.06); }
        .fbox.emerald::before { background: linear-gradient(135deg, rgba(33,209,137,0.04), transparent 50%); }
        .fbox.gold { border-color: rgba(255,199,56,0.2); box-shadow: 0 1px 6px rgba(255,199,56,0.06); }
        .fbox.gold::before { background: linear-gradient(135deg, rgba(255,199,56,0.04), transparent 50%); }
        .fbox.cyan { border-color: rgba(51,191,234,0.2); box-shadow: 0 1px 6px rgba(51,191,234,0.06); }
        .fbox.cyan::before { background: linear-gradient(135deg, rgba(51,191,234,0.04), transparent 50%); }
        .fbox.redbox { border-color: rgba(242,64,64,0.2); box-shadow: 0 1px 6px rgba(242,64,64,0.06); }
        .fbox.redbox::before { background: linear-gradient(135deg, rgba(242,64,64,0.04), transparent 50%); }
        .fbox-header {
          display: flex; align-items: center; gap: 8px;
          font-size: 15px; font-weight: 700;
          padding-bottom: 10px; margin-bottom: 12px;
          position: relative;
        }
        .fbox-header::after {
          content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 1px;
          background: linear-gradient(to right, rgba(255,255,255,0.1), transparent);
        }
        .fbox.emerald .fbox-header::after { background: linear-gradient(to right, rgba(33,209,137,0.6), rgba(33,209,137,0.1), transparent); }
        .fbox.gold .fbox-header::after { background: linear-gradient(to right, rgba(255,199,56,0.6), rgba(255,199,56,0.1), transparent); }
        .fbox.cyan .fbox-header::after { background: linear-gradient(to right, rgba(51,191,234,0.6), rgba(51,191,234,0.1), transparent); }
        .fbox.redbox .fbox-header::after { background: linear-gradient(to right, rgba(242,64,64,0.6), rgba(242,64,64,0.1), transparent); }
        .fbox-header i { width: 16px; height: 16px; }
        .fbox.emerald .fbox-header i { color: #20d189; filter: drop-shadow(0 0 4px rgba(33,209,137,0.5)); }
        .fbox.gold .fbox-header i { color: #ffc738; filter: drop-shadow(0 0 4px rgba(255,199,56,0.5)); }
        .fbox.cyan .fbox-header i { color: #33bfea; filter: drop-shadow(0 0 4px rgba(51,191,234,0.5)); }
        .fbox.redbox .fbox-header i { color: #f24040; filter: drop-shadow(0 0 4px rgba(242,64,64,0.5)); }
        .fbox .inner-block {
          padding: 12px 0; border-bottom: 0.5px solid var(--separator);
        }
        .fbox .inner-block:last-child { border-bottom: none; }
        .fbox .inner-label {
          font-size: 13px; font-weight: 600; margin-bottom: 8px;
          display: flex; align-items: center; gap: 6px;
        }

        /* ─── Login Overlay ─── */
        .login-overlay {
          position: fixed; inset: 0; z-index: 9999;
          background: var(--bg); display: flex;
          align-items: center; justify-content: center;
        }
        .login-box {
          width: 320px; padding: 32px; text-align: center;
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: 20px; box-shadow: 0 16px 48px rgba(0,0,0,0.5);
        }
        .login-box h2 { font-size: 18px; font-weight: 700; margin-bottom: 4px; }
        .login-box p { font-size: 12px; color: var(--text-secondary); margin-bottom: 20px; }
        .login-box input {
          width: 100%; padding: 10px 14px; margin-bottom: 10px;
          background: var(--bg); border: 0.5px solid var(--separator);
          border-radius: 10px; color: var(--text); font-size: 13px;
          outline: none; box-sizing: border-box;
        }
        .login-box input:focus { border-color: var(--accent); }
        .login-box button {
          width: 100%; padding: 10px; margin-top: 6px;
          background: var(--accent); border: none; border-radius: 10px;
          color: #1a1a1a; font-size: 13px; font-weight: 600; cursor: pointer;
        }
        .login-box button:hover { opacity: 0.9; }
        .login-error { color: var(--red); font-size: 11px; margin-top: 8px; display: none; }

        /* ─── Chat ─── */
        .chat-container { flex: 1; display: flex; flex-direction: column; height: 100%; position: relative; }
        .chat-messages {
          flex: 1; overflow-y: auto; padding: 16px 24px;
          display: flex; flex-direction: column; gap: 12px;
          scroll-behavior: smooth;
        }
        .chat-messages::-webkit-scrollbar { width: 6px; }
        .chat-messages::-webkit-scrollbar-thumb { background: var(--fill); border-radius: 3px; }
        .chat-welcome {
          flex: 1; display: flex; flex-direction: column;
          align-items: center; justify-content: flex-start; gap: 12px;
          color: var(--text-tertiary); padding-top: 15vh;
        }
        .chat-welcome .welcome-logo { width: 64px; height: 64px; border-radius: 16px; }
        .chat-welcome h3 { font-size: 17px; font-weight: 600; color: var(--text); margin: 4px 0 0; }
        .chat-welcome p { font-size: 12px; max-width: 300px; text-align: center; line-height: 1.5; }
        .welcome-suggestions { display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; max-width: 340px; margin-top: 8px; }
        .welcome-chip { padding: 8px 14px; background: var(--bg-secondary); border: 0.5px solid var(--separator); border-radius: 16px; font-size: 12px; color: var(--text-secondary); cursor: pointer; transition: var(--transition); }
        .welcome-chip:hover { background: var(--fill); color: var(--text); }
        .bubble {
          max-width: clamp(280px, 75%, 900px); padding: 12px 16px;
          border-radius: 18px; font-size: 15px; line-height: 1.35;
          word-break: break-word; white-space: normal;
          animation: fadeIn 0.25s ease;
        }
        .bubble table { display: block; overflow-x: auto; white-space: nowrap; max-width: 100%; font-size: 12px; border-collapse: collapse; margin: 4px 0; }
        .bubble table td, .bubble table th { padding: 4px 8px; border: 0.5px solid var(--separator); }
        .bubble p { margin: 0.1em 0; }
        @keyframes fadeIn { from { opacity:0; transform:translateY(6px); } to { opacity:1; transform:translateY(0); } }
        .bubble.user {
          background: var(--accent); color: #fff;
          align-self: flex-end;
          border-bottom-right-radius: 6px;
          box-shadow: 0 2px 12px rgba(0,148,51,0.25);
        }
        .bubble.bot {
          background: var(--bg-secondary);
          border: 0.5px solid var(--separator);
          align-self: flex-start;
          border-bottom-left-radius: 6px;
          box-shadow: 0 2px 10px rgba(0,148,51,0.08);
        }
        .bubble.bot pre { background: var(--bg-primary); padding: 10px 12px; border-radius: 8px; margin: 8px 0 4px; overflow-x: auto; font-size: 12px; font-family: 'SF Mono',monospace; }
        .bubble.bot code { background: var(--bg-primary); padding: 2px 5px; border-radius: 4px; font-size: 12px; font-family: 'SF Mono',monospace; }
        .bubble.thinking {
          background: transparent; border: 0.5px dashed var(--separator);
          color: var(--text-secondary); font-size: 13px;
          align-self: flex-start;
          display: flex; align-items: center; gap: 8px;
        }
        .bubble.error { border-color: var(--red); color: var(--red); }
        .bubble-wrap { position: relative; display: flex; flex-direction: column; }
        .bubble-wrap.user-wrap { align-items: flex-end; }
        .bubble-wrap.bot-wrap { align-items: flex-start; }
        .bubble-actions { display: flex; gap: 4px; margin-top: 4px; }
        .bubble-actions button { background: var(--fill); border: none; color: var(--text-secondary); padding: 3px 8px; border-radius: 6px; font-size: 11px; cursor: pointer; display: flex; align-items: center; gap: 4px; transition: var(--transition); }
        .bubble-actions button:hover { background: var(--accent-secondary); color: #1a1a1a; }
        .collapsible-wrap { position: relative; }
        .collapse-fade {
          position: absolute; bottom: 0; left: 0; right: 0; height: 50px;
          background: linear-gradient(transparent, rgba(28,28,30,0.5));
          pointer-events: none; border-radius: 0 0 18px 18px;
        }
        .collapse-toggle {
          background: none; border: none; cursor: pointer; padding: 2px 0; margin-top: 4px;
          font-size: 11px; font-weight: 500; color: rgba(255,255,255,0.6);
          display: flex; align-items: center; gap: 4px; transition: var(--transition);
        }
        .collapse-toggle:hover { color: var(--text); }
        .collapse-toggle i { width: 11px; height: 11px; }
        .tool-tag {
          display: inline-flex; align-items: center; gap: 4px;
          font-size: 11px; padding: 3px 8px; border-radius: 6px;
          background: var(--fill); color: var(--text-secondary);
          margin: 2px 2px 0 0;
        }
        .tool-tag.ok { color: var(--green); }
        .tool-tag.fail { color: var(--red); }
        .chat-composer {
          padding: 6px 20px 6px;
          background: rgba(28,28,30,0.9);
          backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
          border-top: 0.5px solid var(--separator);
          flex-shrink: 0;
        }
        .composer-row { display: flex; gap: 10px; align-items: flex-end; }
        .composer-input {
          flex: 1; background: var(--bg-secondary);
          border: 0.5px solid var(--separator);
          color: var(--text); padding: 10px 14px;
          border-radius: 22px; font-size: 15px; font-family: inherit;
          outline: none; resize: none; min-height: 40px; max-height: 120px;
          transition: var(--transition);
        }
        .composer-input:focus { border-color: var(--accent); box-shadow: 0 0 8px rgba(0,148,51,0.3), 0 0 0 2px rgba(0,148,51,0.15); }
        .composer-input::placeholder { color: var(--text-tertiary); }
        .send-btn {
          width: 40px; height: 40px; border-radius: 50%;
          background: var(--accent); border: none;
          display: flex; align-items: center; justify-content: center;
          cursor: pointer; transition: var(--transition);
          flex-shrink: 0; position: relative; top: -3px;
        }
        .send-btn svg { color: #1a1a1a; }
        .send-btn:hover { filter: brightness(1.1); transform: scale(1.05); }
        .send-btn:disabled { opacity: 0.3; transform: none; cursor: default; }
        .send-btn i { width: 18px; height: 18px; color: #fff; }
        .stt-btn {
          width: 40px; height: 40px; border-radius: 50%;
          background: var(--fill); border: none;
          display: flex; align-items: center; justify-content: center;
          cursor: pointer; transition: var(--transition);
          flex-shrink: 0; position: relative; top: -3px;
        }
        .stt-btn i { width: 18px; height: 18px; color: var(--text-secondary); }
        .stt-btn:hover { filter: brightness(1.2); }
        .stt-btn.recording { background: rgba(242,64,64,0.5); animation: sttPulse 1s ease-in-out infinite; }
        .stt-btn.recording i { color: #fff; }
        @keyframes sttPulse { 0%,100% { box-shadow: 0 0 0 0 rgba(242,64,64,0.4); } 50% { box-shadow: 0 0 0 8px rgba(242,64,64,0); } }
        .clear-btn {
          width: 34px; height: 34px; border-radius: 50%;
          background: var(--fill); border: none;
          display: flex; align-items: center; justify-content: center;
          cursor: pointer; transition: var(--transition);
          flex-shrink: 0; position: relative; top: -3px;
        }
        .composer-row { gap: 3px !important; }
        .clear-btn:hover { filter: brightness(1.2); }
        .clear-btn i { width: 16px; height: 16px; }
        #attachBtn { background: rgba(51,191,230,0.35); }
        #attachBtn i { color: #1a1a1a; }
        #attachBtn:hover { background: rgba(51,191,230,0.5); }
        #trashBtn { background: rgba(242,64,64,0.3); }
        #trashBtn i { color: #1a1a1a; }
        #trashBtn:hover { background: rgba(242,64,64,0.45); }
        #thinkToggle { background: rgba(255,199,56,0.35); }
        #thinkToggle i { color: #1a1a1a; }
        #thinkToggle.active { background: rgba(255,199,56,0.5); }
        #thinkToggle.active i { color: #1a1a1a; }
        #thinkToggle:hover { filter: brightness(1.1); }
        .font-size-stack { display: flex; flex-direction: column; gap: 1px; flex-shrink: 0; position: relative; top: -3px; }
        .font-btn {
          width: 26px; height: 18px; border-radius: 5px;
          background: var(--fill); border: none;
          display: flex; align-items: center; justify-content: center;
          cursor: pointer; transition: var(--transition);
        }
        .font-btn i { width: 11px; height: 11px; color: var(--text-secondary); }
        .font-btn:hover { background: rgba(255,255,255,0.15); filter: brightness(1.2); }
        .typing-dots { display: flex; gap: 4px; padding: 4px 0; }
        .typing-dots span {
          width: 7px; height: 7px; border-radius: 50%; background: #ffffff;
          animation: blink 1.4s infinite both;
        }
        .typing-dots span:nth-child(2) { animation-delay: 0.2s; }
        .typing-dots span:nth-child(3) { animation-delay: 0.4s; }
        @keyframes blink { 0%,80%,100%{opacity:.3} 40%{opacity:1} }

        /* ─── Stats Grid ─── */
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px,1fr)); gap: 12px; margin-bottom: 20px; }
        .stat-card {
          background: var(--bg-elevated);
          backdrop-filter: blur(20px);
          border: 0.5px solid var(--separator);
          border-radius: var(--radius);
          padding: 16px;
          transition: var(--transition);
        }
        .stat-card:hover { border-color: rgba(120,120,128,0.4); }
        .stat-card .label { font-size: 13px; color: var(--text-tertiary); font-weight: 500; text-transform: uppercase; letter-spacing: 0.3px; }
        .stat-card .value { font-size: 28px; font-weight: 700; margin-top: 4px; letter-spacing: -0.5px; }
        .stat-card .value.accent { color: var(--accent); }
        .stat-card .value.green { color: var(--green); }
        .stat-card .value.orange { color: var(--orange); }
        .stat-card .value.red { color: var(--red); }

        /* ─── Memory ─── */
        .search-bar {
          display: flex; gap: 10px; margin-bottom: 16px; width: 100%;
        }
        .search-field {
          width: 100%; background: var(--bg-secondary);
          border: 0.5px solid var(--separator);
          color: var(--text); padding: 10px 14px 10px 36px;
          border-radius: 10px; font-size: 15px; font-family: inherit;
          box-sizing: border-box;
          outline: none; transition: var(--transition);
        }
        .search-field:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(255,199,56,0.15); }
        .search-wrapper { position: relative; flex: 1; }
        .search-wrapper i { position: absolute; left: 12px; top: 50%; transform: translateY(-50%); width: 16px; height: 16px; color: var(--text-tertiary); pointer-events: none; }
        .filter-row { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 14px; }
        .pill {
          font-size: 12px; font-weight: 500; padding: 5px 12px;
          border-radius: 20px; border: 0.5px solid var(--separator);
          cursor: pointer; color: var(--text-secondary); background: transparent;
          transition: var(--transition);
        }
        .pill:hover { background: var(--fill); color: var(--text); }
        .pill.active { background: var(--accent-secondary); color: #1a1a1a; border-color: var(--accent-secondary); }
        .pill.active:hover { background: var(--accent-secondary); }
        .tag-row { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 14px; }
        .tag-pill {
          font-size: 11px; padding: 3px 10px; border-radius: 20px;
          background: var(--fill); color: var(--text-secondary);
          cursor: pointer; transition: var(--transition);
        }
        .tag-pill:hover { background: var(--fill-secondary); color: var(--text); }
        .tag-pill.active { background: rgba(255,199,56,0.2); color: var(--accent); }
        .mem-card {
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 14px; margin-bottom: 10px;
          transition: var(--transition);
        }
        .mem-card:hover { border-color: rgba(120,120,128,0.4); }
        .mem-card .mem-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; }
        .mem-badge {
          font-size: 10px; font-weight: 600; padding: 3px 10px;
          border-radius: 20px; letter-spacing: 0.2px;
        }
        .mem-badge.kurzzeit { background: rgba(100,210,255,0.12); color: var(--teal); }
        .mem-badge.langzeit { background: rgba(255,199,56,0.15); color: var(--accent); }
        .mem-badge.wissen { background: rgba(255,159,10,0.12); color: var(--orange); }
        .mem-badge.lösungen { background: rgba(77,166,255,0.15); color: #4da6ff; }
        .mem-badge.fehler { background: rgba(239,68,68,0.15); color: #ef4444; }
        .mem-valence { font-size:9px; font-weight:700; padding:2px 6px; border-radius:8px; margin-left:4px; }
        .mem-card .mem-text { font-size: 14px; line-height: 1.55; color: var(--text); opacity: 0.78; }
        .mem-card .mem-date { font-size: 10px; color: var(--text-tertiary); margin-top: 8px; }
        .mem-card .mem-tag { font-size: 10px; padding: 2px 7px; border-radius: 6px; background: var(--fill); color: var(--text-tertiary); }
        .mem-card .mem-delete {
          margin-left: auto; background: none; border: none;
          color: var(--text-tertiary); cursor: pointer; padding: 4px;
          border-radius: 6px; transition: var(--transition);
        }
        .mem-card .mem-delete:hover { color: var(--red); background: rgba(255,69,58,0.1); }
        .mem-card .mem-edit {
          margin-left: auto; background: none; border: none; color: var(--text-tertiary);
          padding: 4px; border-radius: 6px; cursor: pointer; transition: var(--transition);
        }
        .mem-card .mem-edit:hover { color: var(--accent); background: rgba(0,148,51,0.1); }
        .mem-stats { display: flex; gap: 12px; margin-bottom: 16px; }
        .mem-stat {
          flex: 1; text-align: center; padding: 12px;
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius);
        }
        .mem-stat .num { font-size: 22px; font-weight: 700; }
        .mem-stat .lbl { font-size: 10px; color: var(--text-tertiary); text-transform: uppercase; margin-top: 2px; }
        .add-mem-form {
          display: none; background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 14px; margin-bottom: 14px;
        }
        .add-mem-form.show { display: block; }
        .add-mem-form textarea {
          width: 100%; background: var(--bg-primary); border: 0.5px solid var(--separator);
          color: var(--text); padding: 10px; border-radius: 8px;
          font-size: 13px; font-family: inherit; resize: vertical; min-height: 60px;
          outline: none; margin-bottom: 10px;
        }
        .add-mem-form textarea:focus { border-color: var(--accent); }
        .form-row { display: flex; gap: 8px; align-items: center; }

        /* ─── Tasks ─── */
        .task-item {
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 14px; margin-bottom: 10px;
          transition: var(--transition);
        }
        .task-item:hover { border-color: rgba(120,120,128,0.4); }
        .task-row { display: flex; align-items: center; gap: 10px; }
        .task-name { font-size: 15px; font-weight: 600; flex: 1; }
        .task-cron { font-size: 11px; font-family: 'SF Mono',monospace; color: var(--orange); background: rgba(255,159,10,0.1); padding: 2px 8px; border-radius: 6px; }
        .task-status {
          font-size: 10px; font-weight: 600; padding: 3px 10px;
          border-radius: 20px;
        }
        .task-status.on { background: rgba(48,209,88,0.12); color: var(--green); }
        .task-status.off { background: rgba(255,69,58,0.1); color: var(--red); }
        .task-prompt { font-size: 14px; color: var(--text); opacity: 0.78; margin-top: 8px; line-height: 1.5; }
        .task-actions { display: flex; gap: 6px; margin-top: 10px; }
        .add-task-form {
          display: none; background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 14px; margin-bottom: 14px;
        }
        .add-task-form.show { display: block; }
        .schedule-presets { display: flex; flex-wrap: wrap; gap: 6px; }
        .sched-pill { background: var(--fill); border: 0.5px solid var(--separator); color: var(--text-secondary); padding: 5px 12px; border-radius: 20px; font-size: 12px; cursor: pointer; transition: var(--transition); font-family: inherit; }
        .sched-pill:hover { border-color: var(--accent-secondary); color: var(--accent-secondary); }
        .sched-pill.active { background: var(--accent-secondary); color: #1a1a1a; border-color: var(--accent-secondary); }
        .form-input {
          width: 100%; background: var(--bg-primary); border: 0.5px solid var(--separator);
          color: var(--text); padding: 9px 12px; border-radius: 8px;
          font-size: 13px; font-family: inherit; outline: none; margin-bottom: 8px;
        }
        .form-input:focus { border-color: var(--accent); }
        .form-select {
          background: var(--bg-primary); border: 0.5px solid var(--separator);
          color: var(--text); padding: 9px 12px; border-radius: 8px;
          font-size: 13px; font-family: inherit; outline: none;
        }

        /* ─── Settings ─── */
        .settings-section { margin-bottom: 20px; }
        .settings-section h3 { font-size: 13px; font-weight: 600; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 10px; }
        .settings-row {
          display: flex; align-items: center; justify-content: space-between;
          padding: 12px 0;
          border-bottom: 0.5px solid var(--separator);
        }
        .settings-row:last-child { border-bottom: none; }
        .settings-label { font-size: 15px; }
        .settings-value { font-size: 13px; color: var(--text-secondary); }
        .model-card {
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 12px 14px;
          margin-bottom: 6px; cursor: pointer; transition: var(--transition);
          display: flex; align-items: center; gap: 10px;
        }
        .model-card:hover { border-color: rgba(120,120,128,0.4); }
        .model-card.selected { border-color: var(--accent); background: rgba(255,199,56,0.1); }
        .model-card .model-name { font-size: 13px; font-weight: 600; flex: 1; }
        .model-card .model-size { font-size: 11px; color: var(--text-tertiary); }
        .model-radio { width: 18px; height: 18px; border-radius: 50%; border: 2px solid var(--separator); flex-shrink: 0; transition: var(--transition); }
        .model-card.selected .model-radio { border-color: var(--accent); background: var(--accent); box-shadow: inset 0 0 0 3px var(--bg-secondary); }

        /* ─── Buttons ─── */
        .btn {
          font-size: 12px; font-weight: 600; font-family: inherit;
          padding: 7px 14px; border-radius: 8px; border: none;
          cursor: pointer; transition: var(--transition);
          display: inline-flex; align-items: center; gap: 6px;
        }
        .btn i { width: 14px; height: 14px; }
        .btn-primary { background: var(--accent); color: #1a1a1a; }
        .btn-primary:hover { filter: brightness(1.1); }
        .btn-secondary { background: var(--fill); color: var(--text); }
        .btn-secondary:hover { background: var(--fill-secondary); }
        .btn-danger { background: rgba(255,69,58,0.1); color: var(--red); }
        .btn-danger:hover { background: rgba(255,69,58,0.2); }
        .btn-sm { padding: 5px 10px; font-size: 11px; }

        /* ─── Empty State ─── */
        .empty-state {
          text-align: center; padding: 48px 20px;
          color: var(--text-tertiary);
        }
        .empty-state i { width: 40px; height: 40px; margin-bottom: 12px; stroke-width: 1.2; }
        .empty-state p { font-size: 13px; margin-top: 4px; }

        /* ─── Spinner ─── */
        .spinner {
          width: 18px; height: 18px;
          border: 2px solid var(--fill);
          border-top-color: var(--accent);
          border-radius: 50%;
          animation: spin 0.7s linear infinite;
          display: inline-block;
        }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* ─── Global Header ─── */
        .global-header {
          display: flex; align-items: center; justify-content: center;
          padding: 10px 20px; height: 40px;
          background: rgba(30,34,40,0.75);
          backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
          border: 0.5px solid var(--separator);
          border-radius: 14px;
          margin: 8px 16px 4px;
          box-shadow: 0 2px 12px rgba(0,0,0,0.25);
          font-size: 14px; color: var(--text-secondary);
          flex-shrink: 0; justify-content: space-between;
        }
        .gh-left { display: flex; align-items: center; gap: 8px; }
        .gh-right { display: flex; align-items: center; gap: 10px; }
        .gh-center { display: none; }
        .gh-date { font-weight: 500; }
        .gh-badge {
          display: inline-flex; align-items: center; gap: 5px;
          font-size: 11px; font-weight: 500; padding: 3px 10px;
          border-radius: 20px; background: var(--fill);
        }
        .gh-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
        .gh-dot.green { background: var(--green); box-shadow: 0 0 4px var(--green); }
        .gh-dot.red { background: var(--red); box-shadow: 0 0 4px var(--red); }
        .gh-dot.orange { background: var(--orange); box-shadow: 0 0 4px var(--orange); }
        .gh-bell {
          background: none; border: none; color: var(--text-secondary);
          cursor: pointer; position: relative; padding: 4px; border-radius: 6px;
          transition: var(--transition);
        }
        .gh-bell:hover { background: var(--fill); color: var(--text); }
        .gh-bell-count {
          position: absolute; top: -2px; right: -4px;
          background: var(--red); color: #fff; font-size: 9px; font-weight: 700;
          min-width: 16px; height: 16px; border-radius: 8px;
          display: flex; align-items: center; justify-content: center;
          padding: 0 4px;
        }

        /* ─── Notification Panel ─── */
        .notif-panel {
          position: absolute; top: 34px; right: 16px; z-index: 100;
          width: 280px; background: var(--bg-secondary);
          border: 0.5px solid var(--separator); border-radius: 12px;
          box-shadow: 0 8px 32px rgba(0,0,0,0.4);
          display: none; overflow: hidden;
        }
        .notif-panel.open { display: block; }
        .notif-header {
          padding: 10px 14px; font-size: 12px; font-weight: 700;
          border-bottom: 0.5px solid var(--separator); color: var(--text);
        }
        .notif-list { max-height: 240px; overflow-y: auto; }
        .notif-empty { padding: 20px 14px; text-align: center; font-size: 11px; color: var(--text-tertiary); }
        .notif-item {
          padding: 10px 14px; border-bottom: 0.5px solid var(--separator);
          font-size: 11px; color: var(--text-secondary); cursor: pointer;
          transition: var(--transition);
        }
        .notif-item:hover { background: var(--fill); }
        .notif-item .notif-title { font-weight: 600; color: var(--text); margin-bottom: 2px; }
        .notif-item .notif-time { font-size: 10px; color: var(--text-tertiary); }

        /* ─── Weather Badge ─── */
        #ghWeather { gap: 4px; }
        #weatherIcon { font-size: 12px; }

        /* ─── Version Badge ─── */
        .version-badge {
          display: inline-flex; align-items: center; gap: 4px;
          font-size: 10px; font-weight: 600; padding: 2px 8px;
          border-radius: 10px;
          background: rgba(255,199,56,0.12); color: var(--orange);
        }

        /* ─── Topic Folder ─── */
        .topic-folder {
          margin-bottom: 2px;
        }
        .topic-header {
          display: flex; align-items: center; gap: 6px;
          padding: 6px 12px; border-radius: 6px;
          cursor: pointer; font-size: 11px; font-weight: 600;
          color: var(--text-secondary); transition: var(--transition);
        }
        .topic-header:hover { background: var(--fill); }
        .topic-header .topic-dot {
          width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0;
        }
        .topic-header .topic-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .topic-header .topic-count {
          font-size: 9px; font-weight: 600; padding: 1px 5px;
          border-radius: 8px; background: var(--fill); color: var(--text-tertiary);
        }
        .topic-header .topic-chevron { width: 10px; height: 10px; color: var(--text-tertiary); transition: transform 0.2s; }
        .topic-header.collapsed .topic-chevron { transform: rotate(-90deg); }
        .topic-sessions { padding-left: 8px; }
        .topic-sessions.hidden { display: none; }
        .topic-actions {
          display: none; gap: 2px; margin-left: auto;
        }
        .topic-header:hover .topic-actions { display: flex; }
        .topic-actions button {
          background: none; border: none; cursor: pointer; padding: 2px;
          color: var(--text-tertiary); border-radius: 4px; transition: var(--transition);
        }
        .topic-actions button:hover { color: var(--text); background: var(--fill); }
        .new-topic-btn {
          display: flex; align-items: center; gap: 6px;
          padding: 6px 12px; font-size: 10px; font-weight: 600;
          color: var(--orange); cursor: pointer; transition: var(--transition);
          text-transform: uppercase; letter-spacing: 0.3px;
        }
        .new-topic-btn:hover { color: var(--text); }
        .topic-form {
          padding: 8px 12px; background: var(--bg-tertiary); border-radius: 8px;
          margin: 4px 12px 8px; display: none;
        }
        .topic-form.open { display: block; }
        .topic-colors { display: flex; gap: 4px; margin: 6px 0; flex-wrap: wrap; }
        .topic-colors .color-dot {
          width: 18px; height: 18px; border-radius: 50%; cursor: pointer;
          border: 2px solid transparent; transition: var(--transition);
        }
        .topic-colors .color-dot:hover { transform: scale(1.2); }
        .topic-colors .color-dot.selected { border-color: var(--text); }

        /* ─── Chat Topic Badge ─── */
        .chat-topic-badge {
          display: inline-flex; align-items: center; gap: 4px;
          font-size: 10px; font-weight: 600; padding: 2px 8px;
          border-radius: 10px; margin: 0 20px 4px; flex-shrink: 0;
        }
        .chat-topic-badge .topic-dot { width: 6px; height: 6px; border-radius: 50%; }

        /* ─── Session List ─── */
        .session-item {
          display: flex; align-items: center; gap: 8px;
          padding: 7px 12px; border-radius: 8px;
          font-size: 11px; color: var(--text-secondary);
          cursor: pointer; transition: var(--transition);
          margin-bottom: 1px; overflow: hidden;
        }
        .session-item:hover { background: var(--fill); color: var(--text); }
        .session-item.active { background: rgba(0,148,51,0.15); color: var(--accent); }
        .session-item .session-name {
          flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }
        .session-item .session-delete {
          opacity: 0; background: none; border: none; color: var(--text-tertiary);
          cursor: pointer; padding: 2px; border-radius: 4px; flex-shrink: 0;
          transition: var(--transition);
        }
        .session-item:hover .session-delete { opacity: 1; }
        .session-item .session-delete:hover { color: var(--red); }
        .session-date-group {
          font-size: 10px; color: var(--text-tertiary); font-weight: 600;
          text-transform: uppercase; letter-spacing: 0.3px;
          padding: 10px 12px 4px;
        }

        /* ─── Settings Tabs ─── */
        .settings-tabs {
          display: flex; gap: 4px; flex-wrap: wrap; margin-bottom: 16px;
          padding-bottom: 12px; border-bottom: 0.5px solid var(--separator);
        }
        .settings-tab {
          font-size: 12px; font-weight: 500; padding: 6px 14px;
          border-radius: 8px; cursor: pointer;
          color: var(--text-secondary); background: transparent;
          border: 0.5px solid transparent;
          transition: var(--transition);
        }
        .settings-tab:hover { background: var(--fill); color: var(--text); }
        .settings-tab.active { background: var(--accent-secondary); color: #1a1a1a; }
        .settings-panel { display: none; }
        .settings-panel.active { display: block; }

        /* ─── Settings: Toggle ─── */
        .s-toggle { position: relative; display: inline-block; width: 44px; height: 24px; flex-shrink: 0; }
        .s-toggle input { opacity: 0; width: 0; height: 0; position: absolute; }
        .s-toggle .slider { position: absolute; top: 0; left: 0; right: 0; bottom: 0; background: var(--fill-secondary); border-radius: 12px; cursor: pointer; transition: 0.25s; }
        .s-toggle .slider:before { content: ''; position: absolute; width: 20px; height: 20px; left: 2px; top: 2px; background: #fff; border-radius: 50%; transition: 0.25s; }
        .s-toggle input:checked + .slider { background: var(--green); }
        .s-toggle input:checked + .slider:before { transform: translateX(20px); }

        /* ─── Settings: Select ─── */
        .s-select {
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          color: var(--text); padding: 6px 10px; border-radius: 8px;
          font-size: 13px; font-family: inherit; outline: none;
          cursor: pointer; min-width: 100px;
        }
        .s-select option { background: var(--bg); color: var(--text); }

        /* ─── Settings: Slider ─── */
        .s-slider-wrap { display: flex; align-items: center; gap: 8px; }
        .s-slider { width: 120px; accent-color: var(--accent); cursor: pointer; }
        .s-slider-val { font-size: 12px; color: var(--text-secondary); min-width: 36px; text-align: right; font-weight: 600; }

        /* ─── Settings: Textarea ─── */
        .s-textarea {
          width: 100%; min-height: 80px; resize: vertical;
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          color: var(--text); padding: 10px; border-radius: 8px;
          font-size: 13px; font-family: 'SF Mono', ui-monospace, monospace; outline: none;
          line-height: 1.5;
        }
        .s-textarea:focus { border-color: var(--accent); }

        /* ─── Settings: Description ─── */
        .s-desc { font-size: 11px; color: var(--text-tertiary); margin-top: 2px; }
        .settings-row .s-desc { margin-top: 0; }
        .settings-row .s-left { display: flex; flex-direction: column; gap: 1px; flex: 1; }

        /* ─── Idle Task Priority Badge ─── */
        .priority-badge {
          font-size: 10px; font-weight: 600; padding: 2px 8px;
          border-radius: 12px; letter-spacing: 0.2px;
        }
        .priority-badge.high { background: rgba(242,64,64,0.12); color: var(--red); }
        .priority-badge.medium { background: rgba(255,199,56,0.12); color: var(--orange); }
        .priority-badge.low { background: rgba(100,210,255,0.12); color: var(--teal); }
        .idle-cooldown { font-size: 10px; color: var(--text-tertiary); font-family: 'SF Mono',monospace; background: var(--fill); padding: 2px 6px; border-radius: 4px; }
        .section-divider { font-size: 13px; font-weight: 700; color: var(--text-secondary); margin: 24px 0 12px; display: flex; align-items: center; gap: 8px; }
        .section-divider i { width: 16px; height: 16px; color: var(--accent); }
        .section-divider::after { content: ''; flex: 1; height: 0.5px; background: var(--separator); }
        .edit-form { background: var(--bg-primary); border: 0.5px solid var(--accent); border-radius: 8px; padding: 10px; margin-top: 8px; }
        .edit-form .form-input { margin-bottom: 6px; }

        /* ─── Markdown ─── */
        .bubble.bot h1,.bubble.bot h2,.bubble.bot h3,.bubble.bot h4,.bubble.bot h5,.bubble.bot h6 { margin: 2px 0 6px; font-weight: 700; line-height: 1.2; }
        .bubble.bot h1 { font-size: 1.2em; }
        .bubble.bot h2 { font-size: 1.12em; }
        .bubble.bot h3 { font-size: 1.06em; }
        .bubble.bot h4 { font-size: 1.02em; }
        .bubble.bot h5,.bubble.bot h6 { font-size: 1.0em; font-weight: 600; }
        .bubble.bot h1+*,.bubble.bot h2+*,.bubble.bot h3+*,.bubble.bot h4+*,.bubble.bot h5+*,.bubble.bot h6+* { margin-top: 0 !important; }
        .bubble.bot ul,.bubble.bot ol { padding-left: 20px; margin: 6px 0; }
        .bubble.bot li { margin-bottom: 3px; }
        .bubble.bot a { color: var(--accent); text-decoration: underline; }
        .bubble.bot table { border-collapse: collapse; margin: 4px 0; font-size: 12px; width: 100%; }
        .bubble.bot th,.bubble.bot td { border: 0.5px solid var(--separator); padding: 6px 10px; text-align: left; }
        .bubble.bot th { background: var(--bg-primary); font-weight: 600; }
        .bubble.bot blockquote { border-left: 3px solid var(--accent); padding-left: 12px; color: var(--text-secondary); margin: 8px 0; }
        .bubble.bot hr { border: none; border-top: 0.5px solid var(--separator); margin: 10px 0; }

        /* ─── Context Bar ─── */
        .context-bar {
          display: flex; align-items: center; gap: 8px;
          padding: 4px 20px; background: var(--bg-primary);
          border-top: 0.5px solid var(--separator); font-size: 10px; color: var(--text-tertiary);
          flex-shrink: 0;
        }
        .context-bar .ctx-fill { flex: 1; height: 4px; background: var(--fill); border-radius: 2px; overflow: hidden; }
        .context-bar .ctx-used { height: 100%; background: var(--accent); border-radius: 2px; transition: width 0.3s; }

        /* ─── Tool Call Collapsible ─── */
        .tool-block {
          background: var(--bg-primary); border: 0.5px solid var(--separator);
          border-radius: 8px; margin: 6px 0; overflow: hidden; font-size: 12px;
        }
        .tool-block-header {
          display: flex; align-items: center; gap: 6px;
          padding: 8px 10px; cursor: pointer; transition: var(--transition);
        }
        .tool-block-header:hover { background: var(--fill); }
        .tool-block-header .tool-icon { width: 14px; height: 14px; }
        .tool-block-header .tool-name { font-weight: 600; flex: 1; }
        .tool-block-header .tool-status { font-size: 10px; padding: 2px 6px; border-radius: 4px; }
        .tool-block-header .tool-status.ok { color: var(--green); background: rgba(48,209,88,0.1); }
        .tool-block-header .tool-status.fail { color: var(--red); background: rgba(255,69,58,0.1); }
        .tool-block-body {
          display: none; padding: 8px 10px; border-top: 0.5px solid var(--separator);
          font-family: 'SF Mono',monospace; white-space: pre-wrap; color: var(--text-secondary);
          max-height: 200px; overflow-y: auto;
        }
        .tool-block.open .tool-block-body { display: block; }

        /* ─── Thinking Panel ─── */
        .thinking-panel {
          background: rgba(255,199,56,0.06); border: 0.5px dashed rgba(255,199,56,0.25);
          border-radius: 10px; padding: 10px 14px; margin: 4px 0;
          font-size: 12px; color: var(--text-secondary); align-self: flex-start;
          max-width: clamp(280px, 75%, 900px); animation: fadeIn 0.25s ease;
        }
        .thinking-panel.live { border-style: solid; border-color: rgba(255,199,56,0.5); border-width: 1.5px; }
        .thinking-toggle {
          display: flex; align-items: center; gap: 6px; cursor: pointer;
          font-weight: 600; color: var(--orange); font-size: 12px;
        }
        .thinking-toggle .think-chevron { transition: transform 0.15s ease; font-size: 10px; }
        .thinking-panel.open .think-chevron { transform: rotate(90deg); }
        .thinking-content { margin-top: 8px; display: none; max-height: 220px; overflow-y: auto; }
        .thinking-panel.open .thinking-content { display: block; }
        .think-step {
          padding: 3px 4px; border-radius: 4px; margin-bottom: 1px;
          display: flex; flex-direction: column;
        }
        .think-step-header {
          display: flex; align-items: center; gap: 5px; cursor: pointer;
          font-size: 12px; font-weight: 600; font-family: 'SF Mono',ui-monospace,monospace;
        }
        .think-step-header .step-chevron { font-size: 9px; color: rgba(255,255,255,0.3); transition: transform 0.15s ease; }
        .think-step.open .step-chevron { transform: rotate(90deg); }
        .think-step-body {
          display: none; padding: 2px 0 2px 20px; font-size: 12px;
          color: var(--text-secondary); white-space: pre-wrap; line-height: 1.4;
          max-height: 150px; overflow-y: auto;
        }
        .think-step.open .think-step-body { display: block; }
        .think-step .step-icon { width: 12px; height: 12px; flex-shrink: 0; }
        .think-step.type-think .step-icon { color: var(--orange); }
        .think-step.type-toolCall .step-icon { color: #5ac8fa; }
        .think-step.type-toolResult.ok .step-icon { color: var(--green); }
        .think-step.type-toolResult.fail .step-icon { color: var(--red); }
        .think-step-spinner { display: inline-block; width: 10px; height: 10px; border: 1.5px solid rgba(255,199,56,0.3); border-top-color: var(--orange); border-radius: 50%; animation: spin 0.8s linear infinite; margin-left: auto; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .think-live-verb { display: flex; align-items: center; gap: 6px; padding-top: 6px; border-top: 0.5px solid rgba(255,199,56,0.15); margin-top: 4px; font-weight: 600; color: var(--orange); font-size: 12px; }

        /* ─── Toast ─── */
        .toast-container { position: fixed; top: 20px; right: 20px; z-index: 1000; display: flex; flex-direction: column; gap: 8px; }
        .toast {
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: 10px; padding: 10px 16px; font-size: 13px;
          box-shadow: 0 4px 20px rgba(0,0,0,0.4);
          animation: slideDown 0.3s ease; min-width: 200px;
        }
        .toast.success { border-color: rgba(48,209,88,0.3); }
        .toast.error { border-color: rgba(255,69,58,0.3); }
        @keyframes slideDown { from { opacity: 0; transform: translateY(-20px); } to { opacity: 1; transform: translateY(0); } }

        /* ─── Voice Dots Animation ─── */
        .voice-dots { display:inline-flex; gap:4px; align-items:center; }
        .voice-dots span {
          width:8px; height:8px; border-radius:50%; background:var(--orange);
          animation: voicePulse 0.6s ease-in-out infinite alternate;
        }
        .voice-dots span:nth-child(2) { animation-delay: 0.2s; }
        .voice-dots span:nth-child(3) { animation-delay: 0.4s; }
        @keyframes voicePulse { from { transform:scale(0.4); opacity:0.3; } to { transform:scale(1); opacity:1; } }
        .voice-bar { width:3px; border-radius:1.5px; background:var(--green); transition:height 0.1s; min-height:4px; }

        /* ─── Scroll to Bottom ─── */
        .scroll-btn {
          position: absolute; bottom: 80px; right: 24px;
          width: 36px; height: 36px; border-radius: 50%;
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          color: var(--text-secondary); cursor: pointer;
          display: none; align-items: center; justify-content: center;
          box-shadow: var(--shadow); transition: var(--transition); z-index: 5;
        }
        .scroll-btn:hover { background: var(--fill); color: var(--text); }
        .scroll-btn i { width: 18px; height: 18px; }

        /* ─── Historie Popup ─── */
        .historie-backdrop { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.5); z-index: 200; }
        .historie-backdrop.open { display: block; }
        .historie-popup {
          display: none; position: fixed; top: 50%; left: 50%; transform: translate(-50%,-50%);
          width: 380px; max-width: 90vw; max-height: 70vh;
          background: var(--bg-primary); border: 0.5px solid var(--separator);
          border-radius: 16px; box-shadow: 0 16px 48px rgba(0,0,0,0.6);
          z-index: 201; flex-direction: column; overflow: hidden;
        }
        .historie-popup.open { display: flex; }
        .historie-header { display: flex; justify-content: space-between; align-items: center; padding: 16px 18px 12px; border-bottom: 0.5px solid var(--separator); }
        .historie-header h3 { color: var(--text); font-size: 15px; font-weight: 600; margin: 0; }
        .historie-close { background: none; border: none; color: var(--text-secondary); font-size: 22px; cursor: pointer; padding: 2px 6px; border-radius: 6px; }
        .historie-close:hover { background: var(--fill); }
        .historie-new-chat { display: flex; align-items: center; justify-content: center; gap: 6px; margin: 10px 14px 6px; padding: 10px; background: rgba(0,148,51,0.1); color: var(--accent); border: none; border-radius: 10px; font-size: 13px; font-weight: 600; cursor: pointer; }
        .historie-new-chat:hover { background: rgba(0,148,51,0.18); }
        .historie-list { flex: 1; overflow-y: auto; padding: 4px 14px 14px; }
        .historie-item { padding: 10px 12px; background: var(--bg-secondary); border-radius: 10px; margin-bottom: 6px; cursor: pointer; color: var(--text); font-size: 13px; transition: background 0.15s; }
        .historie-item:hover { background: var(--bg-tertiary); }
        .historie-item.active { border-left: 3px solid var(--accent); }
        .historie-item .historie-date { font-size: 10px; color: var(--text-secondary); margin-top: 3px; }
        .historie-item .historie-actions { float: right; opacity: 0; transition: opacity 0.15s; }
        .historie-item:hover .historie-actions { opacity: 1; }
        .historie-del { background: none; border: none; color: var(--red, #ff453a); cursor: pointer; font-size: 11px; padding: 2px 6px; border-radius: 4px; }
        .historie-del:hover { background: rgba(255,69,58,0.15); }

        /* ─── Responsive ─── */
        @media (max-width: 768px) {
          .sidebar { width: 64px; }
          .sidebar-brand h1, .sidebar-brand .status, .nav-section, .sidebar-footer, .nav-item span { display: none; }
          .sidebar-brand { justify-content: center; padding: 16px 0; }
          .nav-item { justify-content: center; padding: 12px; }
          .nav-item i { margin: 0; }
          .bubble { max-width: 90%; }
          .page-body { padding: 14px; }
          .stats-grid { grid-template-columns: repeat(2, 1fr); }
        }
        @media (max-width: 480px) {
          body { padding-bottom: 0; }
          .sidebar {
            position: fixed; bottom: 0; left: 0; right: 0;
            width: 100%; height: auto; flex-direction: row;
            border-right: none; border-top: 0.5px solid var(--separator);
            z-index: 100;
            background: rgba(28,28,30,0.95);
            backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
            padding: 0; padding-bottom: env(safe-area-inset-bottom, 0px);
          }
          .sidebar-brand, .nav-section, .sidebar-footer { display: none !important; }
          .nav { display: flex; flex-direction: row; padding: 0; overflow-x: hidden; width: 100%; }
          .nav-item { flex: 1; justify-content: center; padding: 8px 4px 5px !important; border-radius: 0; flex-direction: column; gap: 2px; margin: 0 !important; min-width: 0; }
          .nav-item span { display: block !important; font-size: 9px !important; text-align: center; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .nav-item i { width: 22px !important; height: 22px !important; }
          .main { margin-bottom: calc(52px + env(safe-area-inset-bottom, 0px)); margin-left: 0 !important; }
          .chat-composer { padding: 6px 8px 4px; }
          .clear-btn { width: 30px !important; height: 30px !important; }
          .clear-btn i { width: 14px !important; height: 14px !important; }
          #attachBtn { background: rgba(51,191,230,0.35) !important; }
          #attachBtn i { color: #1a1a1a !important; }
          #trashBtn { background: rgba(242,64,64,0.3) !important; }
          #trashBtn i { color: #1a1a1a !important; }
          #thinkToggle { background: rgba(255,199,56,0.35) !important; }
          #thinkToggle i { color: #1a1a1a !important; }
          .send-btn { width: 34px !important; height: 34px !important; }
          .font-size-stack { display: none !important; }
          .composer-input { min-height: 34px !important; font-size: 15px !important; padding: 8px 12px !important; }
          .bubble { max-width: 95%; font-size: 15px !important; line-height: 1.4 !important; }
          .global-header { padding: 6px 12px !important; margin: 6px 8px 2px !important; border-radius: 10px !important; }
          .gh-badge { font-size: 9px !important; padding: 2px 6px !important; }
          .historie-popup { width: 90vw; max-height: 60vh; top: auto; bottom: 60px; left: 5vw; transform: none; }
        }
        </style>
        </head>
        <body>
        <div class="login-overlay" id="loginOverlay">
          <div class="login-box">
            <h2>KoboldOS</h2>
            <p>Bitte anmelden um fortzufahren</p>
            <input type="text" id="loginUser" placeholder="Benutzername" autocomplete="username" autocapitalize="off">
            <input type="password" id="loginPass" placeholder="Passwort" autocomplete="current-password">
            <button onclick="doLogin()">Anmelden</button>
            <div class="login-error" id="loginError">Falsche Zugangsdaten</div>
          </div>
        </div>
        <div class="sidebar">
          <div class="sidebar-brand" onclick="toggleSidebar()">
            <div class="logo"><img src="data:image/png;base64,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" alt="KoboldOS"></div>
            <h1>KoboldOS</h1>
            <div class="status" id="statusDot"></div>
          </div>
          <div class="nav">
            <div class="nav-item active" onclick="if(currentTab==='chat'){toggleHistorie()}else{switchTab('chat',this)}" id="chatNavBtn"><i data-lucide="message-square"></i><span>Chat</span></div>
            <div class="nav-item" onclick="if(currentTab==='tasks'){toggleTaskHistorie()}else{switchTab('tasks',this)}" id="tasksNavBtn"><i data-lucide="check-square"></i><span>Aufgaben</span></div>
            <div class="nav-item" onclick="switchTab('voice',this)"><i data-lucide="mic"></i><span>Sprechen</span></div>
            <div class="nav-item" onclick="switchTab('memory',this)"><i data-lucide="brain"></i><span>Gedächtnis</span></div>
            <div class="nav-item" onclick="switchTab('settings',this)"><i data-lucide="settings"></i><span>Einstellungen</span></div>
          </div>
          <div class="sidebar-footer" id="versionFooter">KoboldOS <span class="version-badge">v0.3.71</span></div>
        </div>

        <div class="main">
          <div class="historie-backdrop" id="historieBackdrop" onclick="toggleHistorie()"></div>
          <div class="historie-popup" id="historiePopup">
            <div class="historie-header">
              <h3>Chat-Historie</h3>
              <button class="historie-close" onclick="toggleHistorie()">&times;</button>
            </div>
            <button class="historie-new-chat" onclick="newSession();toggleHistorie()"><i data-lucide="plus" style="width:14px;height:14px"></i> Neuer Chat</button>
            <div class="historie-list" id="historieList"></div>
          </div>
          <div class="historie-backdrop" id="taskHistorieBackdrop" onclick="toggleTaskHistorie()"></div>
          <div class="historie-popup" id="taskHistoriePopup">
            <div class="historie-header">
              <h3 style="color:var(--orange)">Aufgaben-Chats</h3>
              <button class="historie-close" onclick="toggleTaskHistorie()">&times;</button>
            </div>
            <div class="historie-list" id="taskHistorieList"></div>
          </div>
          <!-- Global Header -->
          <div class="global-header" id="globalHeader">
            <div class="gh-left"><i data-lucide="calendar" style="width:13px;height:13px;color:var(--accent)"></i><span class="gh-date" id="ghDate"></span></div>
            <div class="gh-center"><span class="gh-time" id="ghTime"></span></div>
            <div class="gh-right">
              <span class="gh-badge" id="ghWeather"><span id="weatherIcon"></span><span id="weatherTemp">--°</span></span>
              <span class="gh-badge" id="ghOllama"><span class="gh-dot green"></span>Ollama</span>
              <button class="gh-bell" id="ghBell" onclick="toggleNotifPanel()"><i data-lucide="bell" style="width:14px;height:14px"></i><span class="gh-bell-count" id="ghBellCount" style="display:none">0</span></button>
            </div>
            <div class="notif-panel" id="notifPanel">
              <div class="notif-header">Benachrichtigungen</div>
              <div class="notif-list" id="notifList"><div class="notif-empty">Keine neuen Benachrichtigungen</div></div>
            </div>
          </div>
          <!-- Chat -->
          <div class="tab active" id="tab-chat">
            <div class="chat-container">
              <div class="chat-topic-badge" id="chatTopicBadge" style="display:none"></div>
              <div class="chat-messages" id="chatArea">
                <div class="chat-welcome" id="chatWelcome">
                  <img class="welcome-logo" src="/favicon.png" alt="KoboldOS">
                  <h3>Hallo!</h3>
                  <p>Stelle eine Frage oder gib einen Auftrag — dein KoboldOS Agent antwortet in Echtzeit.</p>
                  <div class="welcome-suggestions">
                    <div class="welcome-chip" onclick="document.getElementById('msgInput').value='Was kannst du alles?';sendMsg()">Was kannst du?</div>
                    <div class="welcome-chip" onclick="document.getElementById('msgInput').value='Fasse die neuesten Nachrichten zusammen';sendMsg()">Nachrichten</div>
                    <div class="welcome-chip" onclick="document.getElementById('msgInput').value='Schreib mir eine kreative Geschichte';sendMsg()">Geschichte</div>
                    <div class="welcome-chip" onclick="document.getElementById('msgInput').value='Hilf mir beim Programmieren';sendMsg()">Code-Hilfe</div>
                  </div>
                </div>
              </div>
              <div class="context-bar" id="contextBar">
                <span>Kontext:</span>
                <div class="ctx-fill"><div class="ctx-used" id="ctxUsed" style="width:0%"></div></div>
                <span id="ctxLabel">0%</span>
              </div>
              <div class="chat-composer">
                <div class="composer-row">
                  <button class="clear-btn" id="attachBtn" onclick="attachFile()" title="Datei anhängen"><i data-lucide="paperclip"></i></button>
                  <button class="clear-btn" id="trashBtn" onclick="clearChat()" title="Chat leeren"><i data-lucide="trash-2"></i></button>
                  <button class="clear-btn" id="thinkToggle" onclick="toggleThinking()" title="Gedanken ein/aus"><i data-lucide="brain"></i></button>
                  <div class="font-size-stack">
                    <button class="font-btn" id="fontUp" onclick="adjustFontSize(1)" title="Schrift größer"><i data-lucide="plus"></i></button>
                    <button class="font-btn" id="fontDown" onclick="adjustFontSize(-1)" title="Schrift kleiner"><i data-lucide="minus"></i></button>
                  </div>
                  <textarea class="composer-input" id="msgInput" placeholder="Nachricht eingeben..." rows="1"
                    onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();sendMsg()}"
                    oninput="this.style.height='auto';this.style.height=Math.min(this.scrollHeight,120)+'px'"></textarea>
                  <button class="stt-btn" id="sttBtn" onclick="toggleSTT()" title="Spracheingabe"><i data-lucide="mic"></i></button>
                  <button class="send-btn" id="sendBtn" onclick="sendMsg()"><i data-lucide="send"></i></button>
                </div>
              </div>
            </div>
          </div>

          <!-- Tasks -->
          <div class="tab" id="tab-tasks">
            <div class="page-header">
              <h2>Aufgaben</h2>
              <div style="flex:1"></div>
              <button class="btn btn-secondary btn-sm" onclick="toggleIdleForm()" style="margin-right:6px"><i data-lucide="coffee"></i>Neue Idle-Aufgabe</button>
              <button class="btn btn-primary btn-sm" onclick="toggleTaskForm()"><i data-lucide="plus"></i>Neue Aufgabe</button>
            </div>
            <div class="page-body">
              <div class="add-task-form" id="taskForm">
                <input class="form-input" id="taskName" placeholder="Aufgabenname">
                <textarea class="form-input" id="taskPrompt" placeholder="Prompt / Anweisung" style="resize:vertical;min-height:60px"></textarea>
                <div style="margin:8px 0">
                  <div style="font-size:12px;color:var(--text-secondary);margin-bottom:6px">Zeitplan</div>
                  <div class="schedule-presets" id="schedPresets">
                    <button class="sched-pill active" onclick="pickSched(this,'')">Manuell</button>
                    <button class="sched-pill" onclick="pickSched(this,'*/5 * * * *')">Alle 5 Min</button>
                    <button class="sched-pill" onclick="pickSched(this,'0 * * * *')">Stündlich</button>
                    <button class="sched-pill" onclick="pickSched(this,'0 */4 * * *')">Alle 4h</button>
                    <button class="sched-pill" onclick="pickSched(this,'0 8 * * *')">Täglich 08:00</button>
                    <button class="sched-pill" onclick="pickSched(this,'0 9 * * 1-5')">Werktags 09:00</button>
                    <button class="sched-pill" onclick="pickSched(this,'0 0 * * 0')">Wöchentlich</button>
                    <button class="sched-pill" onclick="pickSched(this,'custom')">Eigener Cron</button>
                  </div>
                  <input class="form-input" id="taskSchedule" placeholder="Cron-Ausdruck (z.B. */5 * * * *)" style="display:none;margin-top:6px">
                </div>
                <div class="form-row">
                  <button class="btn btn-primary" onclick="createTask()">Erstellen</button>
                  <button class="btn btn-secondary" onclick="toggleTaskForm()">Abbrechen</button>
                </div>
              </div>
              <div class="add-task-form" id="idleForm">
                <input class="form-input" id="idleName" placeholder="Name der Idle-Aufgabe">
                <textarea class="form-input" id="idlePrompt" placeholder="Prompt / Anweisung" style="resize:vertical;min-height:60px"></textarea>
                <div class="form-row" style="margin-bottom:8px">
                  <div style="flex:1">
                    <div style="font-size:12px;color:var(--text-secondary);margin-bottom:4px">Priorität</div>
                    <select class="form-select" id="idlePriority"><option value="high">Hoch</option><option value="medium" selected>Mittel</option><option value="low">Niedrig</option></select>
                  </div>
                  <div style="flex:1">
                    <div style="font-size:12px;color:var(--text-secondary);margin-bottom:4px">Cooldown (Min)</div>
                    <input class="form-input" id="idleCooldown" type="number" value="30" min="1" style="margin:0">
                  </div>
                </div>
                <div class="form-row">
                  <button class="btn btn-primary" onclick="createIdleTask()">Erstellen</button>
                  <button class="btn btn-secondary" onclick="toggleIdleForm()">Abbrechen</button>
                </div>
              </div>
              <div class="section-divider"><i data-lucide="clock"></i>Geplante Aufgaben</div>
              <div id="tasksArea"></div>
              <div class="section-divider"><i data-lucide="coffee"></i>Idle-Aufgaben</div>
              <div id="idleTasksArea"></div>
            </div>
          </div>

          <!-- Sprechen -->
          <div class="tab" id="tab-voice">
            <div class="page-header">
              <h2>Sprechen</h2>
              <div style="flex:1"></div>
              <div style="display:flex;align-items:center;gap:8px">
                <select id="voiceInputSelect" class="form-input" style="width:140px;font-size:11px;padding:4px 8px" onchange="voiceInputChanged(this.value)">
                  <option value="vad">VAD (LIVE)</option>
                  <option value="ptt">Push to Talk</option>
                </select>
                <button id="voiceStopBtn" class="btn" style="display:none;font-size:11px;padding:4px 12px;background:#f24040;color:#fff;border:none;border-radius:6px;cursor:pointer" onclick="voiceForceStop()">
                  <i data-lucide="square" style="width:10px;height:10px;margin-right:4px"></i>Stop
                </button>
              </div>
            </div>
            <div class="page-body" style="display:flex;flex-direction:column;height:100%">
              <!-- Transkript -->
              <div id="voiceTranscript" style="flex:1;overflow-y:auto;padding:16px"></div>
              <!-- Processing-Indicator -->
              <div id="voiceProcessing" style="display:none;text-align:center;padding:12px">
                <div style="display:inline-flex;align-items:center;gap:10px;padding:10px 24px;border-radius:20px;background:var(--glass-bg);border:1px solid var(--glass-border)">
                  <span class="voice-dots"><span></span><span></span><span></span></span>
                  <span id="voiceProcessLabel" style="font-size:13px;color:var(--orange)">Verarbeite...</span>
                </div>
              </div>
              <!-- Voice Controls -->
              <div style="padding:12px 16px;border-top:1px solid var(--glass-border);display:flex;align-items:center;gap:12px">
                <button id="voiceTTSToggle" style="width:36px;height:36px;min-width:36px;border-radius:50%;display:flex;align-items:center;justify-content:center;padding:0;background:var(--glass-bg);border:1px solid var(--glass-border);color:var(--orange);cursor:pointer;transition:all 0.15s" title="Sprachausgabe ein/aus" onclick="toggleVoiceTTS()">
                  <i data-lucide="volume-2" style="width:16px;height:16px"></i>
                </button>
                <div id="voiceWaveform" style="flex:1;height:36px;display:flex;align-items:center;gap:2px;overflow:hidden"></div>
                <div style="display:flex;flex-direction:column;align-items:center;gap:4px">
                  <div id="voiceStatus" style="display:flex;align-items:center;gap:4px">
                    <div id="voiceStatusDot" style="width:6px;height:6px;border-radius:50%;background:var(--green)"></div>
                    <span id="voiceStatusText" style="font-size:10px;color:var(--text-tertiary)">Bereit</span>
                  </div>
                  <button id="voiceBtn" class="btn btn-primary" style="width:52px;height:52px;border-radius:50%;display:flex;align-items:center;justify-content:center;padding:0;font-size:18px" onclick="voiceBtnClick()">
                    <i data-lucide="mic" style="width:22px;height:22px"></i>
                  </button>
                </div>
              </div>
            </div>
          </div>

          <!-- Memory -->
          <div class="tab" id="tab-memory">
            <div class="page-header">
              <h2>Gedächtnis</h2>
              <div style="flex:1"></div>
              <button class="btn btn-primary btn-sm" onclick="toggleMemForm()"><i data-lucide="plus"></i>Hinzufügen</button>
            </div>
            <div class="page-body">
              <div class="mem-stats" id="memStats"></div>
              <div class="add-mem-form" id="memForm">
                <textarea id="memText" placeholder="Neue Erinnerung..."></textarea>
                <div class="form-row">
                  <select class="form-select" id="memType"><option value="kurzzeit">Kurzzeit</option><option value="langzeit">Langzeit</option><option value="wissen">Wissen</option><option value="lösungen">Lösungen</option><option value="fehler">Fehler</option></select>
                  <input class="form-input" id="memTags" placeholder="Tags (kommagetrennt)" style="flex:1;margin:0">
                  <button class="btn btn-primary" onclick="createMemory()">Speichern</button>
                  <button class="btn btn-secondary" onclick="toggleMemForm()">Abbrechen</button>
                </div>
              </div>
              <div class="search-bar">
                <div class="search-wrapper">
                  <i data-lucide="search"></i>
                  <input class="search-field" id="memSearch" placeholder="Erinnerungen durchsuchen..." oninput="filterMemory()">
                </div>
              </div>
              <div class="filter-row" id="memTypeFilter">
                <span class="pill active" onclick="setMemType(null,this)">Alle</span>
                <span class="pill" onclick="setMemType('kurzzeit',this)">Kurzzeit</span>
                <span class="pill" onclick="setMemType('langzeit',this)">Langzeit</span>
                <span class="pill" onclick="setMemType('wissen',this)">Wissen</span>
                <span class="pill" onclick="setMemType('lösungen',this)">Lösungen</span>
                <span class="pill" onclick="setMemType('fehler',this)">Fehler</span>
              </div>
              <div class="tag-row" id="memTagBar"></div>
              <div id="memEntries"></div>
            </div>
          </div>

          <!-- Settings -->
          <div class="tab" id="tab-settings">
            <div class="page-header"><h2>Einstellungen</h2></div>
            <div class="page-body">
              <div class="settings-tabs">
                <span class="settings-tab active" onclick="switchSettingsTab('system',this)">Allgemein</span>
                <span class="settings-tab" onclick="switchSettingsTab('agents',this)">Agenten</span>
                <span class="settings-tab" onclick="switchSettingsTab('notifications',this)">Benachrichtigungen</span>
                <span class="settings-tab" onclick="switchSettingsTab('permissions',this)">Berechtigungen</span>
                <span class="settings-tab" onclick="switchSettingsTab('privacy',this)">Datenschutz</span>
                <span class="settings-tab" onclick="switchSettingsTab('skills',this)">Fähigkeiten</span>
                <span class="settings-tab" onclick="switchSettingsTab('memory-settings',this)">Gedächtnis</span>
                <span class="settings-tab" onclick="switchSettingsTab('personality',this)">Persönlichkeit</span>
                <span class="settings-tab" onclick="switchSettingsTab('speech',this)">Sprache & Audio</span>
                <span class="settings-tab" onclick="switchSettingsTab('security',this)">Sicherheit</span>
                <span class="settings-tab" onclick="switchSettingsTab('connections',this)">Integrationen</span>
                <span class="settings-tab" onclick="switchSettingsTab('about',this)">Über</span>
              </div>

              <!-- 1. System -->
              <div class="settings-panel active" id="sp-system">
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="activity"></i>Metriken</div>
                  <div class="stats-grid" id="settingsMetrics"></div>
                  <div style="margin-top:10px;display:flex;gap:8px">
                    <button class="btn btn-secondary btn-sm" onclick="resetMetrics()"><i data-lucide="rotate-ccw"></i>Zurücksetzen</button>
                  </div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="cpu"></i>Modell</div>
                  <div id="modelList"></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="settings"></i>Allgemein</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Arbeitsverzeichnis</span><span class="s-desc">Standard-Pfad für Dateien</span></div><input class="form-input" style="width:200px;font-size:12px" data-key="kobold.defaultWorkDir"></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Updates prüfen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.autoCheckUpdates"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Erweiterte Statistiken</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.showAdvancedStats"><span class="slider"></span></label></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="user"></i>Profil</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Name</span></div><input class="form-input" style="width:180px;font-size:13px" data-key="kobold.profile.name" placeholder="Dein Name"></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">E-Mail</span></div><input class="form-input" style="width:200px;font-size:13px" data-key="kobold.profile.email" placeholder="deine@email.de"></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Benutzername</span></div><input class="form-input" style="width:180px;font-size:13px" data-key="kobold.userName" placeholder="Kobold-User"></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Kobold-Name</span><span class="s-desc">Name deines Agenten</span></div><input class="form-input" style="width:180px;font-size:13px" data-key="kobold.koboldName" placeholder="KoboldOS"></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Avatar</span><span class="s-desc">SF Symbol Name</span></div><input class="form-input" style="width:200px;font-size:12px" data-key="kobold.profile.avatar" placeholder="person.crop.circle.fill"></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="server"></i>Daemon</div>
                  <div id="daemonInfo" style="font-size:13px;color:var(--text-secondary)">Lade...</div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="scroll-text"></i>Aktivitäts-Log</div>
                  <div id="activityLog" style="max-height:300px;overflow-y:auto;font-size:13px;color:var(--text-secondary)">Lade...</div>
                </div>
              </div>

              <!-- 2. Agenten -->
              <div class="settings-panel" id="sp-agents">
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="bot"></i>Agent-Modelle</div>
                  <div id="agentModelsArea" style="font-size:13px;color:var(--text-secondary)">Lade...</div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="footprints"></i>Agent-Schritte</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">General-Agent</span><span class="s-desc">Max Schritte pro Anfrage</span></div><select class="s-select" data-key="kobold.agent.generalSteps"><option value="10">10</option><option value="25">25</option><option value="40">40</option><option value="60">60</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Coder-Agent</span><span class="s-desc">Max Schritte pro Anfrage</span></div><select class="s-select" data-key="kobold.agent.coderSteps"><option value="15">15</option><option value="40">40</option><option value="60">60</option><option value="80">80</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Web-Agent</span><span class="s-desc">Max Schritte pro Anfrage</span></div><select class="s-select" data-key="kobold.agent.webSteps"><option value="20">20</option><option value="50">50</option><option value="80">80</option><option value="100">100</option></select></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="timer"></i>Timeouts & Limits</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Shell-Timeout</span><span class="s-desc">Sekunden bis Abbruch</span></div><select class="s-select" data-key="kobold.shell.timeout"><option value="60">60s</option><option value="120">120s</option><option value="300">300s</option><option value="600">600s</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Sub-Agent Timeout</span><span class="s-desc">Sekunden bis Abbruch</span></div><select class="s-select" data-key="kobold.subagent.timeout"><option value="120">120s</option><option value="300">300s</option><option value="600">600s</option><option value="900">900s</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Max Sub-Agenten</span><span class="s-desc">Parallele Sub-Agenten</span></div><select class="s-select" data-key="kobold.subagent.maxConcurrent"><option value="3">3</option><option value="5">5</option><option value="10">10</option><option value="20">20</option><option value="50">50</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Worker Pool</span><span class="s-desc">Anzahl Worker-Threads</span></div><select class="s-select" data-key="kobold.workerPool.size"><option value="1">1</option><option value="2">2</option><option value="3">3</option><option value="5">5</option></select></div>
                </div>
              </div>

              <!-- 3. Persönlichkeit -->
              <div class="settings-panel" id="sp-personality">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="smile"></i>Grundeinstellungen</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Tonfall</span></div><select class="s-select" data-key="kobold.agent.tone"><option value="freundlich">Freundlich</option><option value="professionell">Professionell</option><option value="locker">Locker</option><option value="direkt">Direkt</option><option value="humorvoll">Humorvoll</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Sprache</span></div><select class="s-select" data-key="kobold.agent.language"><option value="deutsch">Deutsch</option><option value="englisch">Englisch</option><option value="auto">Auto</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Ausführlichkeit</span></div><div class="s-slider-wrap"><input type="range" class="s-slider" data-key="kobold.agent.verbosity" min="0" max="100" step="5"><span class="s-slider-val">50%</span></div></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Gedächtnis-Richtlinie</span><span class="s-desc">Wann neue Infos merken</span></div><select class="s-select" data-key="kobold.agent.memoryPolicy"><option value="auto">Automatisch</option><option value="ask">Nachfragen</option><option value="manual">Manuell</option><option value="disabled">Deaktiviert</option></select></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="heart"></i>Soul.md — Kernidentität</div>
                  <textarea class="s-textarea" data-key="kobold.agent.soul" rows="5" placeholder="Wer bin ich? Meine Kernwerte und Identität..."></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-primary btn-sm" onclick="saveTextarea('kobold.agent.soul')"><i data-lucide="save"></i>Speichern</button></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="user"></i>Personality.md — Verhaltensstil</div>
                  <textarea class="s-textarea" data-key="kobold.agent.personality" rows="5" placeholder="Wie verhalte ich mich? Mein Kommunikationsstil..."></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-primary btn-sm" onclick="saveTextarea('kobold.agent.personality')"><i data-lucide="save"></i>Speichern</button></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="list-checks"></i>Verhaltensregeln</div>
                  <textarea class="s-textarea" data-key="kobold.agent.behaviorRules" rows="4" placeholder="Eine Regel pro Zeile..."></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-primary btn-sm" onclick="saveTextarea('kobold.agent.behaviorRules')"><i data-lucide="save"></i>Speichern</button></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="book-open"></i>Gedächtnis-Regeln</div>
                  <textarea class="s-textarea" data-key="kobold.agent.memoryRules" rows="4" placeholder="Regeln für das Langzeitgedächtnis..."></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-primary btn-sm" onclick="saveTextarea('kobold.agent.memoryRules')"><i data-lucide="save"></i>Speichern</button></div>
                </div>
              </div>

              <!-- 4. Berechtigungen -->
              <div class="settings-panel" id="sp-permissions">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="gauge"></i>Autonomie-Level</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Autonomie</span><span class="s-desc">1=Immer fragen, 2=Smart, 3=Vollautomatisch</span></div><select class="s-select" data-key="kobold.autonomyLevel"><option value="1">1 — Immer fragen</option><option value="2">2 — Smart (Standard)</option><option value="3">3 — Vollautomatisch</option></select></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="shield"></i>Berechtigungen</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Shell-Ausführung</span><span class="s-desc">Terminal-Befehle ausführen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.shell"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Dateien schreiben</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.fileWrite"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Dateien erstellen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.createFiles"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Dateien löschen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.deleteFiles"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Netzwerk</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.network"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Pakete installieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.installPkgs"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Gedächtnis ändern</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.modifyMemory"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Self-Check</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.selfCheck"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Benachrichtigungen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.notifications"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Kalender</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.calendar"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Kontakte</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.contacts"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">E-Mail</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.mail"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Admin bestätigen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.confirmAdmin"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Playwright</span><span class="s-desc">Browser-Automatisierung</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.playwright"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Bildschirmsteuerung</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.screenControl"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Secrets</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.secrets"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">System-Schlüsselbund</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.systemKeychain"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Einstellungen ändern</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.perm.settings"><span class="slider"></span></label></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="terminal"></i>Shell-Tiers</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Safe-Tier</span><span class="s-desc">Ungefährliche Befehle (ls, cat, echo...)</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.shell.safeTier"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Normal-Tier</span><span class="s-desc">Standard-Befehle (git, npm, python...)</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.shell.normalTier"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Power-Tier</span><span class="s-desc">Mächtige Befehle (sudo, rm, docker...)</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.shell.powerTier"><span class="slider"></span></label></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="list-x"></i>Benutzerdefinierte Listen</div>
                  <div style="margin-bottom:12px"><span class="settings-label">Blacklist</span><span class="s-desc" style="display:block">Befehle die NIEMALS ausgeführt werden (ein Befehl pro Zeile)</span></div>
                  <textarea class="s-textarea" data-key="kobold.shell.customBlacklist" rows="3" placeholder="rm -rf /\nformat\n..."></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-danger btn-sm" onclick="saveTextarea('kobold.shell.customBlacklist')"><i data-lucide="save"></i>Speichern</button></div>
                  <div style="margin-top:16px;margin-bottom:12px"><span class="settings-label">Whitelist</span><span class="s-desc" style="display:block">Befehle die IMMER erlaubt sind (ein Befehl pro Zeile)</span></div>
                  <textarea class="s-textarea" data-key="kobold.shell.customAllowlist" rows="3" placeholder="brew install\npip install\n..."></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-primary btn-sm" onclick="saveTextarea('kobold.shell.customAllowlist')"><i data-lucide="save"></i>Speichern</button></div>
                </div>
              </div>

              <!-- 5. Gedächtnis -->
              <div class="settings-panel" id="sp-memory-settings">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="layers"></i>Kontextfenster</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Fenstergröße</span><span class="s-desc">LLM-Kontextlänge in Tokens</span></div><select class="s-select" data-key="kobold.context.windowSize"><option value="4096">4K</option><option value="8192">8K</option><option value="16384">16K</option><option value="32768">32K</option><option value="65536">64K</option><option value="131072">128K</option><option value="262144">256K</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Komprimierung</span><span class="s-desc">Alten Kontext automatisch zusammenfassen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.context.autoCompress"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Kompressions-Schwelle</span></div><div class="s-slider-wrap"><input type="range" class="s-slider" data-key="kobold.context.threshold" min="50" max="95" step="5"><span class="s-slider-val">80%</span></div></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Embedding-Modell</span></div><input class="form-input" style="width:180px;font-size:12px" data-key="kobold.embedding.model"></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="database"></i>Memory-Limits</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Persona-Limit</span><span class="s-desc">Max Zeichen für Persona-Block</span></div><select class="s-select" data-key="kobold.memory.personaLimit"><option value="1000">1.000</option><option value="2000">2.000</option><option value="4000">4.000</option><option value="8000">8.000</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Human-Limit</span><span class="s-desc">Max Zeichen für Human-Block</span></div><select class="s-select" data-key="kobold.memory.humanLimit"><option value="1000">1.000</option><option value="2000">2.000</option><option value="4000">4.000</option><option value="8000">8.000</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Knowledge-Limit</span><span class="s-desc">Max Zeichen für Wissens-Block</span></div><select class="s-select" data-key="kobold.memory.knowledgeLimit"><option value="2000">2.000</option><option value="3000">3.000</option><option value="5000">5.000</option><option value="10000">10.000</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Speichern</span><span class="s-desc">Sessions automatisch sichern</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.memory.autosave"><span class="slider"></span></label></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="search"></i>Memory Recall</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Recall aktivieren</span><span class="s-desc">Automatisch relevante Erinnerungen abrufen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.memory.recallEnabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Abruf-Intervall</span><span class="s-desc">Alle X Nachrichten</span></div><select class="s-select" data-key="kobold.memory.recallInterval"><option value="1">Jede</option><option value="2">Alle 2</option><option value="3">Alle 3</option><option value="5">Alle 5</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Max Suchergebnisse</span></div><select class="s-select" data-key="kobold.memory.maxSearch"><option value="5">5</option><option value="8">8</option><option value="12">12</option><option value="20">20</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Max Ergebnisse</span></div><select class="s-select" data-key="kobold.memory.maxResults"><option value="3">3</option><option value="5">5</option><option value="8">8</option><option value="10">10</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Ähnlichkeits-Schwelle</span></div><div class="s-slider-wrap"><input type="range" class="s-slider" data-key="kobold.memory.similarityThreshold" min="30" max="95" step="5"><span class="s-slider-val">70%</span></div></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="sparkles"></i>Auto-Merken</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Merken aktivieren</span><span class="s-desc">Automatisch wichtige Infos speichern</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.memory.memorizeEnabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Fakten extrahieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.memory.autoFragments"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Lösungen merken</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.memory.autoSolutions"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Konsolidierung</span><span class="s-desc">Duplikate zusammenführen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.memory.consolidation"><span class="slider"></span></label></div>
                </div>
              </div>

              <!-- 6. Benachrichtigungen -->
              <div class="settings-panel" id="sp-notifications">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="bell"></i>Benachrichtigungen</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Chat-Schritte bis Benachrichtigung</span><span class="s-desc">Nach X Agent-Schritten benachrichtigen</span></div><select class="s-select" data-key="kobold.notify.chatStepThreshold"><option value="1">1</option><option value="2">2</option><option value="3">3</option><option value="5">5</option><option value="10">10</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Tasks immer bei Abschluss</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.notify.taskAlways"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Benachrichtigungssound</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.notify.sound"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">System-Benachrichtigungen</span><span class="s-desc">macOS Banner oben rechts</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.notify.systemNotifications"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Kanal</span><span class="s-desc">Wohin benachrichtigen</span></div><select class="s-select" data-key="kobold.notify.channel"><option value="system">System</option><option value="telegram">Telegram</option></select></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="volume-2"></i>Sounds</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Sounds aktivieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.sounds.enabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Lautstärke</span></div><div class="s-slider-wrap"><input type="range" class="s-slider" data-key="kobold.sounds.volume" min="10" max="100" step="5"><span class="s-slider-val">50%</span></div></div>
                </div>
              </div>

              <!-- 7. Sprache & Audio -->
              <div class="settings-panel" id="sp-speech">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="volume-2"></i>Text-to-Speech</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Vorlesen</span><span class="s-desc">Antworten automatisch vorlesen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.tts.autoSpeak"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">TTS-Stimme</span><span class="s-desc">Browser-Stimme für Vorlesen</span></div><select class="s-select" id="ttsVoiceSelect"><option value="">Lade Stimmen...</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Satzzeichen entfernen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.tts.stripPunctuation"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Geschwindigkeit</span></div><div class="s-slider-wrap"><input type="range" class="s-slider" data-key="kobold.tts.rate" min="10" max="100" step="5"><span class="s-slider-val">50%</span></div></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Lautstärke</span></div><div class="s-slider-wrap"><input type="range" class="s-slider" data-key="kobold.tts.volume" min="0" max="100" step="5"><span class="s-slider-val">80%</span></div></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="audio-waveform"></i>ElevenLabs — KI-Stimmen</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">ElevenLabs aktivieren</span><span class="s-desc">Extrem realistische KI-Stimmen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.elevenlabs.enabled" id="elToggle" onchange="toggleElevenLabs()"><span class="slider"></span></label></div>
                  <div id="elSettings" style="display:none">
                    <div class="settings-row"><div class="s-left"><span class="settings-label">API-Key</span><span class="s-desc">Von elevenlabs.io/developers</span></div><input class="s-input" type="password" id="elApiKey" placeholder="xi-..." style="width:220px" onchange="saveElevenLabsKey()"></div>
                    <div class="settings-row"><div class="s-left"><span class="settings-label">Stimme</span></div><select class="s-select" id="elVoiceSelect" onchange="saveSetting('kobold.elevenlabs.voiceId',this.value)"><option value="">Stimmen laden...</option></select></div>
                    <div class="settings-row"><div class="s-left"><span class="settings-label">Modell</span></div><select class="s-select" data-key="kobold.elevenlabs.model"><option value="eleven_multilingual_v2">Multilingual v2 (beste Qualität)</option><option value="eleven_turbo_v2_5">Turbo v2.5 (schnell)</option><option value="eleven_flash_v2_5">Flash v2.5 (am schnellsten)</option></select></div>
                    <div class="settings-row"><div class="s-left"><span class="settings-label">Geschwindigkeit</span><span class="s-desc"><span id="elSpeedVal">1.0</span>x</span></div><input type="range" class="s-slider" min="0.5" max="1.5" step="0.05" value="1.0" data-key="kobold.elevenlabs.speed" id="elSpeed" oninput="document.getElementById('elSpeedVal').textContent=this.value"></div>
                    <div class="settings-row"><div class="s-left"><span class="settings-label">Stabilität</span><span class="s-desc"><span id="elStabVal">0.5</span></span></div><input type="range" class="s-slider" min="0" max="1" step="0.05" value="0.5" data-key="kobold.elevenlabs.stability" id="elStab" oninput="document.getElementById('elStabVal').textContent=this.value"></div>
                    <div class="settings-row"><div class="s-left"><span class="settings-label">Ähnlichkeit</span><span class="s-desc"><span id="elSimVal">0.75</span></span></div><input type="range" class="s-slider" min="0" max="1" step="0.05" value="0.75" data-key="kobold.elevenlabs.similarity" id="elSim" oninput="document.getElementById('elSimVal').textContent=this.value"></div>
                    <div class="settings-row" style="opacity:0.7"><i data-lucide="info" style="width:14px;height:14px;margin-right:6px"></i><span style="font-size:12px">Free: ~10.000 Zeichen/Monat (~20 Min). API-Key unter elevenlabs.io</span></div>
                  </div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="mic"></i>Speech-to-Text</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Transkribieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.stt.autoTranscribe"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">STT-Modell</span></div><select class="s-select" data-key="kobold.stt.model"><option value="tiny">Tiny (75 MB)</option><option value="base">Base (142 MB)</option><option value="small">Small (466 MB)</option><option value="large-v3-turbo-q5_0">Turbo Q5 (574 MB)</option><option value="large-v3-turbo-q8_0">Turbo Q8 (874 MB)</option><option value="medium">Medium (1.5 GB)</option><option value="large-v3-turbo">Turbo (1.6 GB)</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">STT-Sprache</span></div><select class="s-select" data-key="kobold.stt.language"><option value="auto">Auto</option><option value="de">Deutsch</option><option value="en">Englisch</option><option value="fr">Französisch</option><option value="es">Spanisch</option></select></div>
                </div>
              </div>

              <!-- 8. Fähigkeiten -->
              <div class="settings-panel" id="sp-skills">
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="puzzle"></i>Skills</div>
                  <div id="skillsArea" style="font-size:13px;color:var(--text-secondary)">Lade...</div>
                  <div style="margin-top:10px"><button class="btn btn-secondary btn-sm" onclick="loadSkills()"><i data-lucide="refresh-cw"></i>Skills neu laden</button></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="eye"></i>Anzeige</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Agent-Schritte anzeigen</span><span class="s-desc">Denkschritte im Chat sichtbar</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.showAgentSteps"><span class="slider"></span></label></div>
                </div>
              </div>

              <!-- 9. Datenschutz -->
              <div class="settings-panel" id="sp-privacy">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="lock"></i>Datenschutz</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Daemon Port</span><span class="s-desc">Nur lokal (readonly)</span></div><span class="settings-value" id="daemonPortInfo">—</span></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Daten-Persistenz</span><span class="s-desc">Daten nach Löschen behalten</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.data.persistAfterDelete"><span class="slider"></span></label></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="radio"></i>Proaktive Engine</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Proaktiv aktivieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.enabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Prüf-Intervall</span><span class="s-desc">Minuten zwischen Checks</span></div><select class="s-select" data-key="kobold.proactive.interval"><option value="5">5 min</option><option value="10">10 min</option><option value="15">15 min</option><option value="30">30 min</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Morgen-Briefing</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.morningBriefing"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Abend-Zusammenfassung</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.eveningSummary"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Fehler-Alerts</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.errorAlerts"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">System-Health</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.systemHealth"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Idle-Tasks</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idleTasks"><span class="slider"></span></label></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="heart-pulse"></i>Heartbeat</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Heartbeat aktivieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.heartbeat.enabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Intervall (Sekunden)</span></div><select class="s-select" data-key="kobold.proactive.heartbeat.intervalSec"><option value="30">30s</option><option value="60">60s</option><option value="120">120s</option><option value="300">300s</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Im Dashboard zeigen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.heartbeat.showInDashboard"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Log-Aufbewahrung</span></div><select class="s-select" data-key="kobold.proactive.heartbeat.logRetention"><option value="25">25</option><option value="50">50</option><option value="100">100</option><option value="200">200</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Benachrichtigen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.heartbeat.notify"><span class="slider"></span></label></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="coffee"></i>Idle-Task-Einstellungen</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Min Idle-Minuten</span><span class="s-desc">Warten bis Idle-Task startet</span></div><select class="s-select" data-key="kobold.proactive.idle.minIdleMinutes"><option value="1">1</option><option value="3">3</option><option value="5">5</option><option value="10">10</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Max pro Stunde</span></div><select class="s-select" data-key="kobold.proactive.idle.maxPerHour"><option value="2">2</option><option value="5">5</option><option value="10">10</option><option value="20">20</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Shell erlauben</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.allowShell"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Netzwerk erlauben</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.allowNetwork"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Dateien schreiben erlauben</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.allowFileWrite"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Nur hohe Priorität</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.onlyHighPriority"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Ruhezeiten</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.quietHoursEnabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Ruhezeit Start</span></div><select class="s-select" data-key="kobold.proactive.idle.quietHoursStart"><option value="20">20:00</option><option value="21">21:00</option><option value="22">22:00</option><option value="23">23:00</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Ruhezeit Ende</span></div><select class="s-select" data-key="kobold.proactive.idle.quietHoursEnd"><option value="6">06:00</option><option value="7">07:00</option><option value="8">08:00</option><option value="9">09:00</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Bei Ausführung benachrichtigen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.notifyOnExecution"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Bei Nutzeraktivität pausieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.proactive.idle.pauseOnUserActivity"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Telegram Min-Priorität</span></div><select class="s-select" data-key="kobold.proactive.idle.telegramMinPriority"><option value="off">Aus</option><option value="low">Niedrig</option><option value="medium">Mittel</option><option value="high">Hoch</option></select></div>
                </div>
              </div>

              <!-- 10. Sicherheit -->
              <div class="settings-panel" id="sp-security">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="file-text"></i>Logging</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Log-Level</span><span class="s-desc">0=Debug, 1=Info, 2=Warn, 3=Error</span></div><select class="s-select" data-key="kobold.log.level"><option value="0">0 — Debug</option><option value="1">1 — Info</option><option value="2">2 — Warn</option><option value="3">3 — Error</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Verbose Logging</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.log.verbose"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Raw Prompts anzeigen</span><span class="s-desc">Rohe LLM-Prompts im Log</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.dev.showRawPrompts"><span class="slider"></span></label></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="refresh-cw"></i>Recovery</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Restart</span><span class="s-desc">Daemon bei Absturz neu starten</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.recovery.autoRestart"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Session-Recovery</span><span class="s-desc">Sessions beim Start wiederherstellen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.recovery.sessionRecovery"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Max Retries</span></div><select class="s-select" data-key="kobold.recovery.maxRetries"><option value="1">1</option><option value="2">2</option><option value="3">3</option><option value="5">5</option></select></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Health-Check Intervall</span><span class="s-desc">Sekunden zwischen Checks</span></div><select class="s-select" data-key="kobold.recovery.healthInterval"><option value="30">30s</option><option value="60">60s</option><option value="120">120s</option><option value="300">300s</option></select></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="shield-check"></i>Sicherheit</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Tool-Sandboxing</span><span class="s-desc">Tools in isolierter Umgebung</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.security.sandboxTools"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Netzwerk-Einschränkungen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.security.networkRestrict"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Gefährliche Aktionen bestätigen</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.security.confirmDangerous"><span class="slider"></span></label></div>
                </div>
              </div>

              <!-- 11. Integrationen -->
              <div class="settings-panel" id="sp-connections">
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="monitor"></i>WebApp-Server</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">WebApp aktivieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.webapp.enabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Auto-Start</span><span class="s-desc">WebApp beim App-Start starten</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.webapp.autostart"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">Port</span></div><select class="s-select" data-key="kobold.webapp.port"><option value="8090">8090</option><option value="8091">8091</option><option value="9090">9090</option><option value="3000">3000</option></select></div>
                </div>
                <div class="fbox cyan">
                  <div class="fbox-header"><i data-lucide="plug"></i>Integrationen</div>
                  <p style="font-size:12px;color:var(--text-tertiary);margin-bottom:12px">OAuth-Integrationen müssen in der Desktop-App eingerichtet werden.</p>
                  <div id="connectionsArea" style="font-size:13px;color:var(--text-secondary)"></div>
                </div>
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="globe"></i>A2A (Agent-to-Agent)</div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">A2A aktivieren</span></div><label class="s-toggle"><input type="checkbox" data-key="kobold.a2a.enabled"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left"><span class="settings-label">A2A Port</span></div><select class="s-select" data-key="kobold.a2a.port"><option value="8081">8081</option><option value="8082">8082</option><option value="8083">8083</option><option value="9090">9090</option></select></div>
                  <div style="margin-top:8px;margin-bottom:4px">
                    <span class="settings-label" style="font-weight:600">Berechtigungen</span>
                    <div style="display:flex;gap:4px;margin-top:6px;padding:0 4px">
                      <span style="flex:1;font-size:11px;color:var(--text-tertiary);font-weight:600">Ressource</span>
                      <span style="width:60px;text-align:center;font-size:11px;color:#4ade80;font-weight:600">Lesen</span>
                      <span style="width:60px;text-align:center;font-size:11px;color:#fb923c;font-weight:600">Schreiben</span>
                    </div>
                  </div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">🧠 Gedächtnis</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.memory.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.memory.write"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">🔧 Tools</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.tools.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.tools.write"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">📁 Dateien</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.files.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.files.write"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">💻 Shell</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.shell.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.shell.write"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">✅ Aufgaben</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.tasks.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.tasks.write"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">⚙️ Einstellungen</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.settings.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.settings.write"><span class="slider"></span></label></div>
                  <div class="settings-row"><div class="s-left" style="flex:1"><span class="settings-label">🤖 Agent</span></div><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.agent.read"><span class="slider"></span></label><label class="s-toggle" style="width:60px;justify-content:center"><input type="checkbox" data-key="kobold.a2a.perm.agent.write"><span class="slider"></span></label></div>
                  <div style="margin-top:12px"><span class="settings-label">Vertrauenswürdige Agenten</span><span class="s-desc" style="display:block">Agent-IDs kommagetrennt</span></div>
                  <textarea class="s-textarea" data-key="kobold.a2a.trustedAgents" rows="2" placeholder="agent-id-1, agent-id-2"></textarea>
                  <div style="margin-top:8px;text-align:right"><button class="btn btn-primary btn-sm" onclick="saveTextarea('kobold.a2a.trustedAgents')"><i data-lucide="save"></i>Speichern</button></div>
                </div>
              </div>

              <!-- 12. Über -->
              <div class="settings-panel" id="sp-about">
                <div class="fbox gold">
                  <div class="fbox-header"><i data-lucide="info"></i>Über KoboldOS</div>
                  <div class="settings-row"><span class="settings-label">Version</span><span class="settings-value" id="aboutVersion" style="color:var(--orange)">—</span></div>
                  <div class="settings-row"><span class="settings-label">Backend</span><span class="settings-value">Ollama (lokal)</span></div>
                  <div class="settings-row"><span class="settings-label">Plattform</span><span class="settings-value">macOS 14+ (Sonoma)</span></div>
                  <div class="settings-row"><span class="settings-label">Engine</span><span class="settings-value">Swift 6 · SwiftUI</span></div>
                </div>
                <div class="fbox emerald">
                  <div class="fbox-header"><i data-lucide="users"></i>Kobold Team</div>
                  <div class="settings-row">
                    <span class="settings-label">Entwickelt von</span>
                    <a href="https://on.soundcloud.com/I3XRNMhkOAtnNQitGJ" target="_blank" style="color:var(--accent);text-decoration:underline;font-size:13px">FunkJood</a>
                  </div>
                  <div class="settings-row"><span class="settings-label" style="color:var(--text-tertiary);font-size:12px">Powered by Ollama · Swift 6 · SwiftUI</span></div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <script>
        const API='/api';
        let currentTab='chat', memoryEntries=[], memoryTags={}, filterType=null, filterTag=null, isSending=false;
        let sessions=[], activeSessionId=null, contextUsage=0;
        const STORAGE_KEY='koboldos_sessions';

        // ─── Auth ───
        function getAuthHeader(){
          var c=localStorage.getItem('koboldos_auth');
          return c?'Basic '+c:'';
        }
        function doLogin(){
          var u=document.getElementById('loginUser').value.trim();
          var p=document.getElementById('loginPass').value;
          var err=document.getElementById('loginError');
          if(!u){if(err){err.textContent='Benutzername eingeben';err.style.display='block';}return;}
          var token=btoa(u+':'+p);
          var h={'Authorization':'Basic '+token};
          fetch('/api/auth/check',{method:'GET',headers:{'Authorization':'Basic '+token}}).then(function(r){
            if(r.ok){
              localStorage.setItem('koboldos_auth',token);
              document.getElementById('loginOverlay').style.display='none';
              initApp();
            } else {
              if(err){err.textContent='Falsche Zugangsdaten';err.style.display='block';}
            }
          }).catch(function(e){
            if(err){err.textContent='Verbindungsfehler';err.style.display='block';}
          });
        }
        function checkAuth(){
          var token=getAuthHeader();
          if(token){
            fetch('/api/auth/check',{method:'GET',headers:{'Authorization':token}}).then(function(r){
              if(r.ok){document.getElementById('loginOverlay').style.display='none';initApp();}
              else{localStorage.removeItem('koboldos_auth');document.getElementById('loginOverlay').style.display='flex';}
            }).catch(function(){document.getElementById('loginOverlay').style.display='flex';});
          } else {
            document.getElementById('loginOverlay').style.display='flex';
          }
        }

        // ─── Init ───
        function initApp(){
          loadSessions();
          loadTopics();
          checkHealth();
          setInterval(checkHealth, 6000);
          updateClock();
          setInterval(updateClock, 30000);
          initThinkToggle();
          applyChatFontSize();
          fetchWeather();
          setInterval(fetchWeather, 1800000);
          initSettingsListeners();
          loadAllSettings(); // Pre-load settings so TTS/ElevenLabs work immediately
          document.addEventListener('click', e => {
            const panel=document.getElementById('notifPanel');
            const bell=document.getElementById('ghBell');
            if(panel&&panel.classList.contains('open')&&!panel.contains(e.target)&&!bell.contains(e.target)) panel.classList.remove('open');
          });
        }
        document.addEventListener('DOMContentLoaded', function(){
          try{lucide.createIcons();}catch(e){}
          var lp=document.getElementById('loginPass');
          if(lp) lp.addEventListener('keydown',function(e){if(e.key==='Enter')doLogin();});
          checkAuth();
        });

        function updateClock(){
          const now=new Date();
          const days=['So','Mo','Di','Mi','Do','Fr','Sa'];
          const months=['Jan','Feb','Mär','Apr','Mai','Jun','Jul','Aug','Sep','Okt','Nov','Dez'];
          const de=document.getElementById('ghDate');
          const te=document.getElementById('ghTime');
          if(de) de.textContent=days[now.getDay()]+', '+now.getDate()+'. '+months[now.getMonth()]+' '+now.getFullYear();
          if(te) te.textContent=now.getHours().toString().padStart(2,'0')+':'+now.getMinutes().toString().padStart(2,'0');
        }

        // ─── Font Size ───
        let chatFontSize=parseInt(localStorage.getItem('kobold.chatFontSize')||'15');
        function adjustFontSize(delta){
          const fs=Math.max(11,Math.min(22,chatFontSize+delta));
          chatFontSize=fs;
          localStorage.setItem('kobold.chatFontSize',fs);
          document.querySelectorAll('.bubble').forEach(b=>{b.style.fontSize=fs+'px';});
          document.getElementById('msgInput').style.fontSize=fs+'px';
        }
        function applyChatFontSize(){
          if(chatFontSize!==15){
            document.querySelectorAll('.bubble').forEach(b=>{b.style.fontSize=chatFontSize+'px';});
            const inp=document.getElementById('msgInput');
            if(inp) inp.style.fontSize=chatFontSize+'px';
          }
        }

        // ─── Thinking Toggle ───
        let showThinking=localStorage.getItem('kobold.showThinking')!=='false';
        function toggleThinking(){
          showThinking=!showThinking;
          localStorage.setItem('kobold.showThinking',showThinking);
          const btn=document.getElementById('thinkToggle');
          if(btn) btn.classList.toggle('active',showThinking);
          document.querySelectorAll('.thinking-panel').forEach(p=>{
            p.style.display=showThinking?'':'none';
          });
        }
        function initThinkToggle(){
          const btn=document.getElementById('thinkToggle');
          if(btn) btn.classList.toggle('active',showThinking);
        }

        // ─── Chat STT (Speech-to-Text) ───
        let sttRecognition=null;
        let sttActive=false;
        function toggleSTT(){
          if(sttActive){ stopSTT(); return; }
          const SR=window.SpeechRecognition||window.webkitSpeechRecognition;
          if(!SR){ alert('Speech Recognition wird von diesem Browser nicht unterstützt. Bitte Chrome oder Edge verwenden.'); return; }
          sttRecognition=new SR();
          sttRecognition.lang='de-DE';
          sttRecognition.continuous=true;
          sttRecognition.interimResults=true;
          const input=document.getElementById('msgInput');
          const btn=document.getElementById('sttBtn');
          let finalTranscript=input.value;
          sttRecognition.onstart=()=>{ sttActive=true; btn.classList.add('recording'); btn.title='Spracheingabe stoppen'; };
          sttRecognition.onresult=(e)=>{
            let interim='';
            for(let i=e.resultIndex;i<e.results.length;i++){
              if(e.results[i].isFinal){ finalTranscript+=(finalTranscript?' ':'')+e.results[i][0].transcript; }
              else { interim+=e.results[i][0].transcript; }
            }
            input.value=finalTranscript+(interim?' '+interim:'');
            input.style.height='auto'; input.style.height=Math.min(input.scrollHeight,120)+'px';
          };
          sttRecognition.onerror=(e)=>{ if(e.error!=='no-speech') console.warn('STT error:',e.error); stopSTT(); };
          sttRecognition.onend=()=>{ if(sttActive) stopSTT(); };
          sttRecognition.start();
        }
        function stopSTT(){
          sttActive=false;
          const btn=document.getElementById('sttBtn');
          if(btn){ btn.classList.remove('recording'); btn.title='Spracheingabe'; }
          if(sttRecognition){ try{sttRecognition.stop();}catch(e){} sttRecognition=null; }
        }

        // ─── Sidebar Toggle ───
        function toggleSidebar(){
          const sb=document.querySelector('.sidebar');
          if(sb) sb.classList.toggle('collapsed');
        }

        // ─── Tab Switch ───
        function switchTab(name,el) {
          document.querySelectorAll('.tab').forEach(t=>{t.style.display='none';t.classList.remove('active')});
          document.querySelectorAll('.nav-item').forEach(n=>{
            if(!n.id||n.id!=='newChatBtn') n.classList.remove('active');
          });
          const tab=document.getElementById('tab-'+name);
          if(tab){tab.style.display='flex';tab.classList.add('active')}
          if(el) el.classList.add('active');
          currentTab=name;
          // Session list removed from sidebar — now in Historie popup
          if(name==='tasks'){ loadTasks(); loadIdleTasks(); }
          if(name==='voice') initVoiceTab();
          if(name==='memory') loadMemory();
          if(name==='settings') loadSettings();
          lucide.createIcons();
        }

        function switchSettingsTab(name,el){
          document.querySelectorAll('.settings-panel').forEach(p=>p.classList.remove('active'));
          document.querySelectorAll('.settings-tab').forEach(t=>t.classList.remove('active'));
          const panel=document.getElementById('sp-'+name);
          if(panel) panel.classList.add('active');
          if(el) el.classList.add('active');
          if(name==='settings'||name==='system'){ loadSettings(); loadAllSettings(); }
          if(name==='agents') loadAgentModels();
          if(name==='connections') loadConnections();
          if(name==='memory-settings') loadAllSettings();
          if(name==='skills') loadSkills();
          // Lade Settings-Werte für alle Tabs mit data-key Elementen
          if(['personality','permissions','notifications','speech','privacy','security','agents','skills','connections'].includes(name)) loadAllSettings();
          if(name==='speech'){loadBrowserVoices();toggleElevenLabs();}
          lucide.createIcons();
        }

        async function api(path,opts={}){
          const ah=getAuthHeader();
          const h={'Content-Type':'application/json'};
          if(ah) h['Authorization']=ah;
          const {headers:oh,...ro}=opts;
          const r=await fetch(API+path,{...ro,headers:{...h,...(oh||{})},credentials:'same-origin'});
          if(!r.ok){
            const text=await r.text().catch(()=>'');
            throw new Error('HTTP '+r.status+(text?' — '+text:''));
          }
          return r.json();
        }
        function esc(s){const d=document.createElement('div');d.textContent=s||'';return d.innerHTML}
        function collapsible(content,isHtml,limit){
          limit=limit||500;
          const raw=isHtml?content.replace(/<[^>]*>/g,''):content;
          if(raw.length<=limit) return isHtml?content:esc(content);
          const id='coll_'+Math.random().toString(36).substr(2,6);
          const maxH=isHtml?'200px':'120px';
          return '<div id="'+id+'" class="collapsible-wrap" style="max-height:'+maxH+';overflow:hidden;position:relative">'+(isHtml?content:esc(content))+
            '<div class="collapse-fade" id="'+id+'_fade"></div></div>'+
            '<button class="collapse-toggle" onclick="toggleCollapse(\\''+id+'\\')"><i data-lucide="chevron-down" id="'+id+'_icon"></i><span id="'+id+'_label">Mehr anzeigen</span></button>';
        }
        function toggleCollapse(id){
          const wrap=document.getElementById(id);
          const lbl=document.getElementById(id+'_label');
          const fade=document.getElementById(id+'_fade');
          if(!wrap) return;
          const collapsed=wrap.style.maxHeight!=='none';
          wrap.style.maxHeight=collapsed?'none':'200px';
          wrap.style.overflow=collapsed?'visible':'hidden';
          if(fade) fade.style.display=collapsed?'none':'';
          if(lbl) lbl.textContent=collapsed?'Weniger anzeigen':'Mehr anzeigen';
        }
        function fmt(text){
          if(!text) return '';
          // Split by code blocks first to avoid processing markdown inside them
          const parts=text.split(/(```[\\s\\S]*?```)/g);
          return parts.map((part,i)=>{
            if(i%2===1){
              // Code block
              const m=part.match(/```(\\w*)\\n?([\\s\\S]*?)```/);
              if(m) return '<pre><code class="lang-'+esc(m[1])+'">'+esc(m[2].trim())+'</code></pre>';
              return '<pre>'+esc(part.slice(3,-3))+'</pre>';
            }
            let s=esc(part);
            // Inline code
            s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
            // Bold + italic
            s=s.replace(/\\*\\*\\*(.+?)\\*\\*\\*/g,'<strong><em>$1</em></strong>');
            s=s.replace(/\\*\\*(.+?)\\*\\*/g,'<strong>$1</strong>');
            s=s.replace(/(?<![\\w*])\\*([^*]+)\\*(?![\\w*])/g,'<em>$1</em>');
            // Headers
            s=s.replace(/^### (.+)$/gm,'<h3>$1</h3>');
            s=s.replace(/^## (.+)$/gm,'<h2>$1</h2>');
            s=s.replace(/^# (.+)$/gm,'<h1>$1</h1>');
            // Blockquote
            s=s.replace(/^&gt; (.+)$/gm,'<blockquote>$1</blockquote>');
            // Horizontal rule
            s=s.replace(/^---$/gm,'<hr>');
            // Unordered list
            s=s.replace(/^[*-] (.+)$/gm,'<li>$1</li>');
            s=s.replace(/(<li>.*<\\/li>)/gs,'<ul>$1</ul>');
            // Ordered list
            s=s.replace(/^\\d+\\. (.+)$/gm,'<li>$1</li>');
            // Links
            s=s.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g,'<a href="$2" target="_blank">$1</a>');
            // Tables (simple)
            s=s.replace(/^\\|(.+)\\|$/gm, function(match,inner){
              const cells=inner.split('|').map(c=>c.trim());
              if(cells.every(c=>/^[-:]+$/.test(c))) return '';
              const isHeader=false;
              return '<tr>'+cells.map(c=>'<td>'+c+'</td>').join('')+'</tr>';
            });
            s=s.replace(/(<tr>.*?<\\/tr>\\s*)+/gs,m=>'<table>'+m.replace(/\\n+/g,'')+'</table>');
            // Newlines — collapse multiple into single <br>
            s=s.replace(/\\n{2,}/g,'<br>');
            s=s.replace(/\\n/g,'<br>');
            // Remove excessive <br> sequences
            s=s.replace(/(<br>\\s*){3,}/g,'<br>');
            // Remove <br> before/after block elements to prevent huge gaps
            s=s.replace(/<br>(<h[1-6]>)/gi,'$1');
            s=s.replace(/(<\\/h[1-6]>)<br>/gi,'$1');
            s=s.replace(/<br>(<ul>|<ol>|<table>|<hr>|<blockquote>|<pre>)/gi,'$1');
            s=s.replace(/(<\\/ul>|<\\/ol>|<\\/table>|<\\/blockquote>|<\\/pre>|<hr>)<br>/gi,'$1');
            return s;
          }).join('');
        }

        // ─── Health ───
        async function checkHealth(){
          try{
            const d=await api('/health');
            document.getElementById('statusDot').className='status';
            document.getElementById('versionFooter').textContent='KoboldOS '+((d.version)||'');
            // Update global header
            const ol=document.getElementById('ghOllama');
            if(ol){ const dot=ol.querySelector('.gh-dot'); if(dot) dot.className='gh-dot green'; ol.lastChild.textContent='Ollama'; }
          }catch{
            document.getElementById('statusDot').className='status offline';
            const ol=document.getElementById('ghOllama');
            if(ol){ const dot=ol.querySelector('.gh-dot'); if(dot) dot.className='gh-dot red'; }
          }
        }

        // ─── Sessions (localStorage) ───
        function loadSessions(){
          try{ sessions=JSON.parse(localStorage.getItem(STORAGE_KEY)||'[]'); }catch(e){ sessions=[]; }
          if(!sessions.length) newSession(true);
          else {
            activeSessionId=sessions[0].id;
            renderSessions();
            renderChat();
          }
        }
        function saveSessions(){ localStorage.setItem(STORAGE_KEY,JSON.stringify(sessions)); renderSessions(); }
        function newSession(silent){
          const s={id:'s_'+Date.now(),name:'Neuer Chat',messages:[],createdAt:Date.now()};
          sessions.unshift(s);
          activeSessionId=s.id;
          saveSessions();
          if(!silent){ renderChat(); api('/history/clear',{method:'POST'}).catch(()=>{}); }
        }
        function switchSession(id){
          activeSessionId=id;
          renderSessions();
          renderTopics();
          renderChat();
          updateChatTopicBadge();
        }
        function deleteSession(id,ev){
          if(ev) ev.stopPropagation();
          sessions=sessions.filter(s=>s.id!==id);
          if(activeSessionId===id){ if(sessions.length) activeSessionId=sessions[0].id; else newSession(true); }
          saveSessions(); renderChat();
        }
        function getSession(){ return sessions.find(s=>s.id===activeSessionId); }
        let sessionFilter='';
        function filterSessions(q){ sessionFilter=q.toLowerCase(); renderSessions(); }
        function renameSession(id,ev){
          ev.stopPropagation();
          const s=sessions.find(x=>x.id===id); if(!s) return;
          const name=prompt('Chat umbenennen:',s.name||'Neuer Chat');
          if(name&&name.trim()){ s.name=name.trim(); saveSessions(); }
        }
        function renderSessions(){
          const list=document.getElementById('sessionList');
          if(!list) return;
          // Only show sessions without topic assignment (topic sessions shown in topic folders)
          const topicIds=new Set(topics.map(t=>t.id));
          let filtered=sessions.filter(s=>!s.topicId||!topicIds.has(s.topicId));
          const now=Date.now(), day=86400000;
          const today=[], yesterday=[], older=[];
          filtered.forEach(s=>{
            const age=now-s.createdAt;
            if(age<day) today.push(s);
            else if(age<2*day) yesterday.push(s);
            else older.push(s);
          });
          let html='';
          const renderGroup=(label,items)=>{
            if(!items.length) return '';
            let h='<div class="session-date-group">'+label+'</div>';
            items.forEach(s=>{
              const active=s.id===activeSessionId?' active':'';
              const name=s.name||'Neuer Chat';
              h+='<div class="session-item'+active+'" onclick="switchSession(\\''+s.id+'\\')">'+
                '<span class="session-name" ondblclick="renameSession(\\''+s.id+'\\',event)">'+esc(name)+'</span>'+
                '<button class="session-delete" onclick="deleteSession(\\''+s.id+'\\',event)"><i data-lucide="x" style="width:12px;height:12px"></i></button></div>';
            });
            return h;
          };
          html+=renderGroup('Heute',today);
          html+=renderGroup('Gestern',yesterday);
          html+=renderGroup('Älter',older);
          list.innerHTML=html;
          lucide.createIcons();
        }
        function buildConversationHistory(){
          const s=getSession();
          if(!s) return [];
          const valid=new Set(['user','assistant']);
          return s.messages.slice(-100)
            .filter(m=>valid.has(m.role)&&m.content&&m.content.trim())
            .map(m=>({role:m.role,content:m.content}));
        }
        function renderChat(){
          const area=document.getElementById('chatArea');
          const s=getSession();
          if(!s||!s.messages.length){
            area.innerHTML='<div class="chat-welcome" id="chatWelcome"><img class="welcome-logo" src="/favicon.png" alt="KoboldOS"><h3>Hallo!</h3><p>Stelle eine Frage oder gib einen Auftrag — dein KoboldOS Agent antwortet in Echtzeit.</p><div class="welcome-suggestions"><div class="welcome-chip" onclick="document.getElementById(\\'msgInput\\').value=\\'Was kannst du alles?\\';sendMsg()">Was kannst du?</div><div class="welcome-chip" onclick="document.getElementById(\\'msgInput\\').value=\\'Fasse die neuesten Nachrichten zusammen\\';sendMsg()">Nachrichten</div><div class="welcome-chip" onclick="document.getElementById(\\'msgInput\\').value=\\'Schreib mir eine kreative Geschichte\\';sendMsg()">Geschichte</div><div class="welcome-chip" onclick="document.getElementById(\\'msgInput\\').value=\\'Hilf mir beim Programmieren\\';sendMsg()">Code-Hilfe</div></div></div>';
            lucide.createIcons(); return;
          }
          let html='';
          s.messages.forEach((m,i)=>{
            if(m.role==='user') html+='<div class="bubble-wrap user-wrap"><div class="bubble user">'+collapsible(m.content,false,500)+'</div><div class="bubble-actions"><button onclick="copyBubble(this,'+i+')"><i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren</button></div></div>';
            else if(m.role==='assistant') html+='<div class="bubble-wrap bot-wrap"><div class="bubble bot">'+collapsible(fmt(m.content),true,800)+'</div><div class="bubble-actions"><button onclick="copyBubble(this,'+i+')"><i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren</button><button onclick="ttsSpeak(this)"><i data-lucide="volume-2" style="width:11px;height:11px"></i>Vorlesen</button></div></div>';
            else if(m.role==='thinking'){
              let stepsHtml='';
              if(m.stepsData&&m.stepsData.length){
                m.stepsData.forEach(st=>{
                  let icon='brain',iconColor='var(--orange)',label='Gedanke',cls='type-think';
                  if(st.type==='toolCall'){ icon='wrench'; iconColor='#5ac8fa'; label=st.tool||'Tool'; cls='type-toolCall'; }
                  else if(st.type==='toolResult'){ icon=st.success?'check-circle':'x-circle'; iconColor=st.success?'var(--green)':'var(--red)'; label=st.tool||'Ergebnis'; cls='type-toolResult '+(st.success?'ok':'fail'); }
                  stepsHtml+='<div class="think-step '+cls+'"><div class="think-step-header" onclick="this.parentElement.classList.toggle(\\'open\\')"><span class="step-chevron">&#9654;</span><i data-lucide="'+icon+'" class="step-icon" style="color:'+iconColor+'"></i><span>'+esc(label)+'</span></div><div class="think-step-body">'+esc(st.content||'')+'</div></div>';
                });
              } else {
                stepsHtml='<div class="think-step type-think"><div class="think-step-header" onclick="this.parentElement.classList.toggle(\\'open\\')"><span class="step-chevron">&#9654;</span><i data-lucide="brain" class="step-icon" style="color:var(--orange)"></i><span>Gedanken</span></div><div class="think-step-body">'+esc(m.content)+'</div></div>';
              }
              html+='<div class="thinking-panel"'+(showThinking?'':' style="display:none"')+'><div class="thinking-toggle" onclick="this.parentElement.classList.toggle(\\'open\\')"><span class="think-chevron">&#9654;</span><i data-lucide="brain" style="width:12px;height:12px;color:var(--orange)"></i><span class="think-label">'+(m.steps||'Gedanken')+'</span></div><div class="thinking-content">'+stepsHtml+'</div></div>';
            }
          });
          area.innerHTML=html;
          area.scrollTop=area.scrollHeight;
          updateTrashColor();
          applyChatFontSize();
          lucide.createIcons();
        }

        // ─── Chat SSE Streaming ───
        async function sendMsg(){
          if(isSending)return;
          if(sttActive) stopSTT();
          const input=document.getElementById('msgInput');
          let msg=input.value.trim();
          if(!msg&&!pendingAttachments.length)return;
          if(!msg&&pendingAttachments.length) msg='Beschreibe die angehängten Dateien.';
          input.value='';input.style.height='auto';
          const attachments=[...pendingAttachments];
          pendingAttachments=[];
          showAttachmentBadge();
          isSending=true;
          document.getElementById('sendBtn').disabled=true;
          // Status wird im Header-Bereich nicht mehr angezeigt

          const area=document.getElementById('chatArea');
          const welcome=document.getElementById('chatWelcome');
          if(welcome) welcome.remove();

          // Save user message
          const s=getSession();
          if(s){ s.messages.push({role:'user',content:msg}); if(s.name==='Neuer Chat'&&msg.length>2) s.name=msg.substring(0,40); saveSessions(); }

          area.innerHTML+='<div class="bubble-wrap user-wrap"><div class="bubble user">'+collapsible(msg,false,500)+'</div><div class="bubble-actions"><button onclick="copyText(this,\\''+esc(msg.replace(/'/g,"\\\\'"))+'\\')"><i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren</button></div></div>';

          // Create streaming response elements
          const botId='bot_'+Date.now();
          const thinkId='think_'+Date.now();
          area.innerHTML+='<div class="thinking-panel live" id="'+thinkId+'"'+(showThinking?'':' style="display:none"')+'><div class="thinking-toggle" onclick="document.getElementById(\\''+thinkId+'\\').classList.toggle(\\'open\\')"><span class="think-chevron">&#9654;</span><i data-lucide="brain" style="width:12px;height:12px;color:var(--orange)"></i><span class="think-label">0 Schritte</span></div><div class="thinking-content" id="'+thinkId+'_steps"></div><div class="think-live-verb" id="'+thinkId+'_verb"><i data-lucide="brain" style="width:13px;height:13px"></i><span id="'+thinkId+'_verbText">Denkt nach...</span><div class="think-step-spinner"></div></div></div>';
          area.innerHTML+='<div class="bubble-wrap bot-wrap"><div class="bubble bot" id="'+botId+'"><div class="typing-dots"><span></span><span></span><span></span></div></div><div class="bubble-actions"><button onclick="copyBotResponse(this)"><i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren</button><button onclick="ttsSpeak(this)"><i data-lucide="volume-2" style="width:11px;height:11px"></i>Vorlesen</button></div></div>';
          area.scrollTop=area.scrollHeight;
          lucide.createIcons();

          const thinkVerbs=['Denkt nach...','Analysiert...','Überlegt...','Verarbeitet...','Formuliert...','Prüft...','Recherchiert...'];
          let fullResponse='', thinkingSteps=[], toolsHtml='', stepCount=0;
          let elapsed=0, verbIdx=0;
          const timer=setInterval(()=>{
            elapsed++;
            const label=document.querySelector('#'+thinkId+' .think-label');
            if(label) label.textContent=stepCount+' Schritte ('+elapsed+'s)';
            verbIdx=(verbIdx+1)%thinkVerbs.length;
            const vt=document.getElementById(thinkId+'_verbText');
            if(vt) vt.textContent=thinkVerbs[verbIdx];
          },3000);

          try{
            // Build message with text attachments
            let fullMsg=msg;
            const imageData=[];
            attachments.forEach(a=>{
              if(a.type==='text') fullMsg+='\\n\\n--- Datei: '+a.name+' ---\\n'+a.data;
              else if(a.type==='image') imageData.push(a.data);
            });

            const history=buildConversationHistory();
            const sseHeaders={'Content-Type':'application/json'};
            const sseAuth=getAuthHeader();
            if(sseAuth) sseHeaders['Authorization']=sseAuth;

            // Images: use non-streaming /agent with vision support
            if(imageData.length){
              const vr=await fetch(API+'/agent',{
                method:'POST',
                credentials:'same-origin',
                headers:sseHeaders,
                body:JSON.stringify({message:fullMsg,images:imageData,conversation_history:history})
              });
              if(!vr.ok) throw new Error('HTTP '+vr.status);
              const vj=await vr.json();
              const vText=vj.response||vj.text||JSON.stringify(vj);
              clearInterval(timer);
              const botEl=document.getElementById(botId);
              if(botEl) botEl.innerHTML=fmt(vText);
              const s2=getSession();
              if(s2){ s2.messages.push({role:'assistant',content:vText}); saveSessions(); }
              isSending=false;
              document.getElementById('sendBtn').disabled=false;
              area.scrollTop=area.scrollHeight;
              lucide.createIcons();
              return;
            }

            const resp=await fetch(API+'/agent/stream',{
              method:'POST',
              credentials:'same-origin',
              headers:sseHeaders,
              body:JSON.stringify({message:fullMsg,conversation_history:history})
            });

            if(!resp.ok) throw new Error('HTTP '+resp.status);

            const reader=resp.body.getReader();
            const decoder=new TextDecoder();
            let buffer='';

            while(true){
              const {done,value}=await reader.read();
              if(done) break;
              buffer+=decoder.decode(value,{stream:true});

              // Parse SSE events from buffer
              const lines=buffer.split('\\n');
              buffer=lines.pop()||'';

              for(const line of lines){
                if(line.startsWith('data: ')){
                  try{
                    const data=JSON.parse(line.substring(6));
                    stepCount=data.step||stepCount;

                    const tp=document.getElementById(thinkId);
                    const stepsEl=document.getElementById(thinkId+'_steps');

                    if(data.type==='think'||data.type==='toolCall'||data.type==='toolResult'){
                      stepCount=data.step||stepCount;
                      // Show thinking panel
                      if(tp&&showThinking) tp.style.display='';
                      if(tp) tp.classList.add('open');

                      // Build step entry
                      const stepId=thinkId+'_s'+stepCount+'_'+data.type;
                      let icon='brain', iconColor='var(--orange)', label=data.type;
                      let extraClass='type-think';
                      if(data.type==='think'){
                        icon='brain'; label='Gedanke'; extraClass='type-think';
                      } else if(data.type==='toolCall'){
                        icon='wrench'; iconColor='#5ac8fa'; label=data.tool||'Tool'; extraClass='type-toolCall';
                      } else if(data.type==='toolResult'){
                        icon=data.success?'check-circle':'x-circle';
                        iconColor=data.success?'var(--green)':'var(--red)';
                        label=data.tool||'Ergebnis';
                        extraClass='type-toolResult '+(data.success?'ok':'fail');
                      }

                      if(stepsEl){
                        // Collapse previous step
                        const prevSteps=stepsEl.querySelectorAll('.think-step.open');
                        prevSteps.forEach(s=>s.classList.remove('open'));

                        const stepDiv=document.createElement('div');
                        stepDiv.className='think-step open '+extraClass;
                        stepDiv.id=stepId;
                        stepDiv.innerHTML='<div class="think-step-header" onclick="this.parentElement.classList.toggle(\\'open\\')"><span class="step-chevron">&#9654;</span><i data-lucide="'+icon+'" class="step-icon" style="color:'+iconColor+'"></i><span>'+esc(label)+'</span>'+(data.type==='toolCall'?'<div class="think-step-spinner"></div>':'')+'</div><div class="think-step-body">'+esc(data.content||'')+'</div>';
                        stepsEl.appendChild(stepDiv);
                        stepsEl.scrollTop=stepsEl.scrollHeight;
                        lucide.createIcons();
                      }

                      // Remove spinner from previous toolCall on toolResult
                      if(data.type==='toolResult'){
                        const allSteps=stepsEl?stepsEl.querySelectorAll('.type-toolCall .think-step-spinner'):[];
                        if(allSteps.length) allSteps[allSteps.length-1].remove();
                      }

                      thinkingSteps.push({type:data.type,tool:data.tool||'',content:data.content||'',success:data.success});

                    } else if(data.type==='finalAnswer'){
                      fullResponse+=data.content||'';
                      // Collapse thinking, remove live styling
                      if(tp){ tp.classList.remove('open','live'); const verb=document.getElementById(thinkId+'_verb'); if(verb) verb.remove(); }
                    } else if(data.type==='context_info'){
                      try{
                        const ci=JSON.parse(data.content);
                        if(ci.usage_percent){ contextUsage=ci.usage_percent; updateContextBar(); }
                      }catch(e){}
                    } else if(data.type==='error'){
                      fullResponse+='\\u26a0\\ufe0f '+esc(data.content);
                    }

                    // Live-update bot bubble
                    const botEl=document.getElementById(botId);
                    if(botEl&&fullResponse) botEl.innerHTML=fmt(fullResponse);
                    area.scrollTop=area.scrollHeight;
                  }catch(e){/* skip unparseable lines */}
                }
              }
            }

            // Final render (with collapsible for long responses)
            if(!fullResponse) fullResponse='(Keine Antwort)';
            const botEl=document.getElementById(botId);
            if(botEl) botEl.innerHTML=collapsible(fmt(fullResponse),true,800);

            // Update thinking label with final count
            const finalLabel=document.querySelector('#'+thinkId+' .think-label');
            if(finalLabel) finalLabel.textContent=stepCount+' Schritte ('+elapsed+'s)';

            // Save assistant message with thinking steps
            if(s){
              if(thinkingSteps.length){
                const thinkText=thinkingSteps.map(st=>{
                  if(st.type==='think') return st.content;
                  if(st.type==='toolCall') return '[Tool: '+st.tool+'] '+st.content;
                  if(st.type==='toolResult') return '['+(st.success?'OK':'FAIL')+': '+st.tool+'] '+st.content;
                  return st.content;
                }).join('\\n');
                s.messages.push({role:'thinking',content:thinkText,steps:stepCount+' Schritte',stepsData:thinkingSteps});
              }
              s.messages.push({role:'assistant',content:fullResponse});
              saveSessions();
            }
          }catch(e){
            const botEl=document.getElementById(botId);
            if(botEl) botEl.outerHTML='<div class="bubble bot error">Fehler: '+esc(e.message)+'</div>';
          }
          clearInterval(timer);
          area.scrollTop=area.scrollHeight;
          isSending=false;
          document.getElementById('sendBtn').disabled=false;
          // chatStatus entfernt — kein Sub-Header mehr
          input.focus();
          lucide.createIcons();
        }

        function clearChat(){
          const s=getSession();
          if(s){ s.messages=[]; saveSessions(); }
          renderChat(); updateContextBar(); updateTrashColor();
          api('/history/clear',{method:'POST'}).catch(()=>{});
        }
        function updateTrashColor(){
          const btn=document.getElementById('trashBtn');
          if(!btn) return;
          const s=getSession();
          const hasContent=s&&s.messages&&s.messages.length>0;
          btn.classList.toggle('has-content',hasContent);
        }

        function copyBubble(btn,idx){
          const s=getSession(); if(!s||!s.messages[idx]) return;
          navigator.clipboard.writeText(s.messages[idx].content).then(()=>{
            btn.innerHTML='<i data-lucide="check" style="width:11px;height:11px"></i>Kopiert!';
            lucide.createIcons();
            setTimeout(()=>{ btn.innerHTML='<i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren'; lucide.createIcons(); },1500);
          });
        }
        function copyBotResponse(btn){
          const bubble=btn.closest('.bubble-wrap').querySelector('.bubble.bot');
          if(!bubble) return;
          navigator.clipboard.writeText(bubble.innerText).then(()=>{
            btn.innerHTML='<i data-lucide="check" style="width:11px;height:11px"></i>Kopiert!';
            lucide.createIcons();
            setTimeout(()=>{ btn.innerHTML='<i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren'; lucide.createIcons(); },1500);
          });
        }
        function copyText(btn,text){
          navigator.clipboard.writeText(text).then(()=>{
            btn.innerHTML='<i data-lucide="check" style="width:11px;height:11px"></i>Kopiert!';
            lucide.createIcons();
            setTimeout(()=>{ btn.innerHTML='<i data-lucide="copy" style="width:11px;height:11px"></i>Kopieren'; lucide.createIcons(); },1500);
          });
        }
        let ttsUtterance=null;
        // Browser-Stimmen ins Dropdown laden
        function loadBrowserVoices(){
          const sel=document.getElementById('ttsVoiceSelect');
          if(!sel) return;
          const voices=window.speechSynthesis.getVoices();
          if(!voices.length){setTimeout(loadBrowserVoices,300);return;}
          const saved=_settingsCache&&_settingsCache['kobold.tts.voice'];
          // Deutsch zuerst, dann Rest — gruppiert nach Sprache
          const groups={};
          voices.forEach(v=>{
            const lang=v.lang||'unknown';
            if(!groups[lang]) groups[lang]=[];
            groups[lang].push(v);
          });
          const sortedLangs=Object.keys(groups).sort((a,b)=>{
            if(a.startsWith('de')&&!b.startsWith('de')) return -1;
            if(!a.startsWith('de')&&b.startsWith('de')) return 1;
            return a.localeCompare(b);
          });
          sel.innerHTML='';
          sortedLangs.forEach(lang=>{
            const og=document.createElement('optgroup');
            og.label=lang;
            groups[lang].sort((a,b)=>a.name.localeCompare(b.name)).forEach(v=>{
              const opt=document.createElement('option');
              opt.value=v.voiceURI;
              opt.textContent=v.name+(v.localService?' (Lokal)':' (Remote)');
              if(saved&&(saved===v.voiceURI||saved===v.name)) opt.selected=true;
              og.appendChild(opt);
            });
            sel.appendChild(og);
          });
          // Auto-Select: Beste deutsche Stimme wenn nichts gespeichert
          if(!saved||!sel.value){
            const deVoices=voices.filter(v=>v.lang.startsWith('de'));
            const best=deVoices.find(v=>v.name.includes('Premium'))||deVoices.find(v=>v.name.includes('Enhanced'))||deVoices[0];
            if(best) sel.value=best.voiceURI;
          }
          sel.onchange=function(){saveSetting('kobold.tts.voice',sel.value);};
        }
        // Voices laden sobald bereit
        window.speechSynthesis.onvoiceschanged=loadBrowserVoices;
        setTimeout(loadBrowserVoices,500);
        function getSelectedVoice(){
          const voices=window.speechSynthesis.getVoices();
          const sel=document.getElementById('ttsVoiceSelect');
          const val=sel&&sel.value;
          if(val){
            const match=voices.find(v=>v.voiceURI===val||v.name===val);
            if(match) return match;
          }
          return voices.find(v=>v.lang.startsWith('de'))||null;
        }
        // ElevenLabs UI helpers
        let _elAudio=null;
        function toggleElevenLabs(){
          const on=document.getElementById('elToggle')&&document.getElementById('elToggle').checked;
          const s=document.getElementById('elSettings');
          if(s) s.style.display=on?'block':'none';
          if(on) loadElevenLabsVoices();
        }
        function saveElevenLabsKey(){
          const k=document.getElementById('elApiKey').value;
          saveSetting('kobold.elevenlabs.apiKey',k);
          if(k) setTimeout(loadElevenLabsVoices,300);
        }
        async function loadElevenLabsVoices(){
          const sel=document.getElementById('elVoiceSelect');
          if(!sel) return;
          try{
            const data=await api('/tts/elevenlabs/voices');
            const voices=data.voices||[];
            if(!voices.length){sel.innerHTML='<option value="">Keine Stimmen (API-Key prüfen)</option>';return;}
            const saved=_settingsCache&&_settingsCache['kobold.elevenlabs.voiceId'];
            sel.innerHTML='';
            voices.sort((a,b)=>a.name.localeCompare(b.name)).forEach(v=>{
              const opt=document.createElement('option');
              opt.value=v.voice_id;
              opt.textContent=v.name+' ('+v.language+')';
              if(saved&&saved===v.voice_id) opt.selected=true;
              sel.appendChild(opt);
            });
          }catch(e){sel.innerHTML='<option value="">Fehler beim Laden</option>';}
        }
        function ttsSpeak(btn){
          // Stopp wenn bereits sprechend
          if(_elAudio||window.speechSynthesis.speaking){
            if(_elAudio){_elAudio.pause();_elAudio=null;}
            window.speechSynthesis.cancel();
            btn.innerHTML='<i data-lucide="volume-2" style="width:11px;height:11px"></i>Vorlesen';lucide.createIcons();return;
          }
          const bubble=btn.closest('.bubble-wrap').querySelector('.bubble.bot');
          if(!bubble) return;
          const text=bubble.innerText;
          btn.innerHTML='<i data-lucide="volume-x" style="width:11px;height:11px"></i>Stopp';lucide.createIcons();
          const resetBtn=()=>{btn.innerHTML='<i data-lucide="volume-2" style="width:11px;height:11px"></i>Vorlesen';lucide.createIcons();};
          // ElevenLabs wenn aktiviert
          const elEnabled=_settingsCache&&_settingsCache['kobold.elevenlabs.enabled'];
          if(elEnabled){
            const voiceId=_settingsCache['kobold.elevenlabs.voiceId']||'';
            const modelId=_settingsCache['kobold.elevenlabs.model']||'eleven_multilingual_v2';
            api('/tts/elevenlabs/speak',{method:'POST',body:JSON.stringify({text,voice_id:voiceId,model_id:modelId})}).then(data=>{
              if(data.error){throw new Error(data.error);}
              const bytes=atob(data.audio);
              const arr=new Uint8Array(bytes.length);
              for(let i=0;i<bytes.length;i++) arr[i]=bytes.charCodeAt(i);
              const blob=new Blob([arr],{type:'audio/mpeg'});
              const url=URL.createObjectURL(blob);
              _elAudio=new Audio(url);
              _elAudio.volume=(_settingsCache['kobold.tts.volume']||80)/100;
              _elAudio.onended=()=>{_elAudio=null;URL.revokeObjectURL(url);resetBtn();};
              _elAudio.play();
            }).catch(()=>{
              _elAudio=null;
              speakBrowser(text,resetBtn);
            });
          } else {
            speakBrowser(text,resetBtn);
          }
        }
        function speakBrowser(text,onEnd){
          ttsUtterance=new SpeechSynthesisUtterance(text);
          ttsUtterance.lang='de-DE';
          const bv=getSelectedVoice();if(bv) ttsUtterance.voice=bv;
          ttsUtterance.rate=(_settingsCache&&_settingsCache['kobold.tts.rate'])?_settingsCache['kobold.tts.rate']/100:1.0;
          ttsUtterance.volume=(_settingsCache&&_settingsCache['kobold.tts.volume'])?_settingsCache['kobold.tts.volume']/100:1.0;
          ttsUtterance.onend=onEnd;
          window.speechSynthesis.speak(ttsUtterance);
        }
        function updateContextBar(){
          const bar=document.getElementById('ctxUsed');
          const label=document.getElementById('ctxLabel');
          if(bar) bar.style.width=contextUsage+'%';
          if(label) label.textContent=Math.round(contextUsage)+'%';
          if(bar&&contextUsage>95) bar.style.background='var(--red)';
          else if(bar&&contextUsage>80) bar.style.background='var(--orange)';
          else if(bar) bar.style.background='var(--accent)';
        }

        // ─── Tasks ───
        let allTasks=[];
        async function loadTasks(){
          try{
            const data=await api('/tasks');
            allTasks=data.tasks||[];
            const area=document.getElementById('tasksArea');
            if(!allTasks.length){area.innerHTML='<div class="empty-state"><i data-lucide="list-checks"></i><p>Keine geplanten Aufgaben</p></div>';lucide.createIcons();return}
            area.innerHTML=allTasks.map(t=>{
              const on=t.enabled!==false;
              const lastRun=t.last_run||t.lastRun?new Date(t.last_run||t.lastRun).toLocaleString('de-DE',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'—';
              return '<div class="task-item" id="task_'+t.id+'"><div class="task-row">'+
                '<span class="task-name">'+esc(t.name)+'</span>'+
                (t.schedule?'<span class="task-cron">'+esc(t.schedule)+'</span>':'')+
                '<span class="task-status '+(on?'on':'off')+'">'+(on?'Aktiv':'Pausiert')+'</span>'+
                '</div>'+(t.prompt?'<div class="task-prompt" id="taskprompt_'+t.id+'">'+esc(t.prompt)+'</div>':'')+
                '<div style="font-size:11px;color:var(--text-tertiary);margin-top:4px">Letzter Lauf: '+lastRun+'</div>'+
                '<div class="task-actions">'+
                '<button class="btn btn-primary btn-sm" onclick="runTaskNow(\\''+t.id+'\\')"><i data-lucide="play-circle"></i>Jetzt</button>'+
                '<button class="btn btn-secondary btn-sm" onclick="editTask(\\''+t.id+'\\')"><i data-lucide="pencil"></i>Bearbeiten</button>'+
                '<button class="btn btn-secondary btn-sm" onclick="toggleTask(\\''+t.id+'\\','+(!on)+')"><i data-lucide="'+(on?'pause':'play')+'"></i>'+(on?'Pause':'An')+'</button>'+
                '<button class="btn btn-danger btn-sm" onclick="deleteTask(\\''+t.id+'\\')"><i data-lucide="trash-2"></i></button>'+
                '</div></div>';
            }).join('');
            lucide.createIcons();
          }catch(e){
            document.getElementById('tasksArea').innerHTML='<div class="empty-state"><i data-lucide="alert-circle"></i><p>Fehler beim Laden</p></div>';
            lucide.createIcons();
          }
        }

        function editTask(id){
          const t=allTasks.find(x=>x.id===id); if(!t) return;
          const el=document.getElementById('task_'+id); if(!el) return;
          const existing=el.querySelector('.edit-form'); if(existing){existing.remove();return}
          const form=document.createElement('div');form.className='edit-form';
          form.innerHTML='<input class="form-input" id="tedit_name_'+id+'" value="'+esc(t.name)+'" placeholder="Name">'+
            '<textarea class="form-input" id="tedit_prompt_'+id+'" style="resize:vertical;min-height:50px" placeholder="Prompt">'+esc(t.prompt||'')+'</textarea>'+
            '<input class="form-input" id="tedit_sched_'+id+'" value="'+esc(t.schedule||'')+'" placeholder="Cron (leer=manuell)">'+
            '<div style="display:flex;gap:6px;margin-top:6px"><button class="btn btn-primary btn-sm" onclick="saveTask(\\''+id+'\\')">Speichern</button><button class="btn btn-secondary btn-sm" onclick="this.closest(\\'.edit-form\\').remove()">Abbrechen</button></div>';
          el.appendChild(form);
        }

        async function saveTask(id){
          const name=document.getElementById('tedit_name_'+id).value.trim();
          const prompt=document.getElementById('tedit_prompt_'+id).value.trim();
          const schedule=document.getElementById('tedit_sched_'+id).value.trim();
          if(!name) return;
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'update',id,name,prompt,schedule})});
          loadTasks();showToast('Aufgabe gespeichert','success');
        }

        function toggleTaskForm(){document.getElementById('taskForm').classList.toggle('show');document.getElementById('idleForm').classList.remove('show')}
        function toggleIdleForm(){document.getElementById('idleForm').classList.toggle('show');document.getElementById('taskForm').classList.remove('show')}

        let selectedCron='';
        function pickSched(btn,val){
          document.querySelectorAll('.sched-pill').forEach(b=>b.classList.remove('active'));
          btn.classList.add('active');
          const customInput=document.getElementById('taskSchedule');
          if(val==='custom'){ customInput.style.display=''; customInput.focus(); selectedCron=''; }
          else { customInput.style.display='none'; customInput.value=''; selectedCron=val; }
        }

        async function createTask(){
          const name=document.getElementById('taskName').value.trim();
          const prompt=document.getElementById('taskPrompt').value.trim();
          const customCron=document.getElementById('taskSchedule').value.trim();
          const schedule=customCron||selectedCron||'';
          if(!name||!prompt)return;
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'create',name,prompt,schedule:schedule,enabled:true})});
          document.getElementById('taskName').value='';document.getElementById('taskPrompt').value='';document.getElementById('taskSchedule').value='';
          selectedCron='';
          document.querySelectorAll('.sched-pill').forEach((b,i)=>{b.classList.toggle('active',i===0)});
          document.getElementById('taskSchedule').style.display='none';
          toggleTaskForm();loadTasks();
        }

        async function toggleTask(id,enabled){
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'update',id,enabled})});
          loadTasks();
        }

        async function runTaskNow(id){
          try{
            const task=allTasks.find(t=>t.id===id);
            if(!task){showToast('Aufgabe nicht gefunden','error');return;}
            // Task-Session erstellen und Prompt dort senden
            const sid='s_'+Date.now();
            const s={id:sid,name:'Task: '+(task.name||id),messages:[],createdAt:Date.now(),taskId:id};
            sessions.unshift(s);
            activeSessionId=sid;
            saveSessions();
            // Zum Chat wechseln und Prompt absenden
            switchTab('chat',document.querySelector('.nav-item'));
            renderChat();
            // Prompt als Nachricht ins Input setzen und absenden
            const input=document.getElementById('msgInput');
            if(input){input.value=task.prompt||task.name;sendMsg();}
            showToast('Aufgabe gestartet','success');
          }catch(e){ showToast('Fehler: '+e.message,'error'); }
        }

        async function deleteTask(id){
          if(!confirm('Aufgabe wirklich löschen?'))return;
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'delete',id})});
          loadTasks();
        }

        // ─── Idle Tasks ───
        let allIdleTasks=[];
        async function loadIdleTasks(){
          try{
            const data=await api('/idle-tasks');
            allIdleTasks=data.idle_tasks||[];
            const area=document.getElementById('idleTasksArea');
            if(!allIdleTasks.length){area.innerHTML='<div class="empty-state"><i data-lucide="coffee"></i><p>Keine Idle-Aufgaben — diese laufen automatisch wenn du inaktiv bist.</p></div>';lucide.createIcons();return}
            area.innerHTML=allIdleTasks.map(t=>{
              const on=t.enabled!==false;
              const prio=t.priority||'medium';
              const prioLabel=prio==='high'?'Hoch':prio==='low'?'Niedrig':'Mittel';
              const cooldown=t.cooldownMinutes||30;
              const runs=t.runCount||0;
              return '<div class="task-item" id="idle_'+t.id+'"><div class="task-row">'+
                '<span class="task-name">'+esc(t.name)+'</span>'+
                '<span class="priority-badge '+prio+'">'+prioLabel+'</span>'+
                '<span class="idle-cooldown">'+cooldown+' min</span>'+
                '<span class="task-status '+(on?'on':'off')+'">'+(on?'Aktiv':'Pausiert')+'</span>'+
                '</div>'+(t.prompt?'<div class="task-prompt" id="idleprompt_'+t.id+'">'+esc(t.prompt)+'</div>':'')+
                '<div style="font-size:11px;color:var(--text-tertiary);margin-top:4px">Ausführungen: '+runs+'</div>'+
                '<div class="task-actions">'+
                '<button class="btn btn-secondary btn-sm" onclick="editIdleTask(\\''+t.id+'\\')"><i data-lucide="pencil"></i>Bearbeiten</button>'+
                '<button class="btn btn-secondary btn-sm" onclick="toggleIdleTask(\\''+t.id+'\\','+(!on)+')"><i data-lucide="'+(on?'pause':'play')+'"></i>'+(on?'Pause':'An')+'</button>'+
                '<button class="btn btn-danger btn-sm" onclick="deleteIdleTask(\\''+t.id+'\\')"><i data-lucide="trash-2"></i></button>'+
                '</div></div>';
            }).join('');
            lucide.createIcons();
          }catch(e){
            document.getElementById('idleTasksArea').innerHTML='<div class="empty-state"><i data-lucide="alert-circle"></i><p>Fehler beim Laden</p></div>';
            lucide.createIcons();
          }
        }

        async function createIdleTask(){
          const name=document.getElementById('idleName').value.trim();
          const prompt=document.getElementById('idlePrompt').value.trim();
          const priority=document.getElementById('idlePriority').value;
          const cooldown=parseInt(document.getElementById('idleCooldown').value)||30;
          if(!name||!prompt)return;
          await api('/idle-tasks',{method:'POST',body:JSON.stringify({action:'create',name,prompt,priority,cooldownMinutes:cooldown,enabled:true})});
          document.getElementById('idleName').value='';document.getElementById('idlePrompt').value='';
          document.getElementById('idlePriority').value='medium';document.getElementById('idleCooldown').value='30';
          toggleIdleForm();loadIdleTasks();
        }

        function editIdleTask(id){
          const t=allIdleTasks.find(x=>x.id===id); if(!t) return;
          const el=document.getElementById('idle_'+id); if(!el) return;
          const existing=el.querySelector('.edit-form'); if(existing){existing.remove();return}
          const form=document.createElement('div');form.className='edit-form';
          form.innerHTML='<input class="form-input" id="iedit_name_'+id+'" value="'+esc(t.name)+'" placeholder="Name">'+
            '<textarea class="form-input" id="iedit_prompt_'+id+'" style="resize:vertical;min-height:50px" placeholder="Prompt">'+esc(t.prompt||'')+'</textarea>'+
            '<div style="display:flex;gap:8px;margin-bottom:6px">'+
            '<div style="flex:1"><div style="font-size:11px;color:var(--text-secondary);margin-bottom:3px">Priorität</div><select class="form-select" id="iedit_prio_'+id+'"><option value="high"'+(t.priority==='high'?' selected':'')+'>Hoch</option><option value="medium"'+((!t.priority||t.priority==='medium')?' selected':'')+'>Mittel</option><option value="low"'+(t.priority==='low'?' selected':'')+'>Niedrig</option></select></div>'+
            '<div style="flex:1"><div style="font-size:11px;color:var(--text-secondary);margin-bottom:3px">Cooldown (Min)</div><input class="form-input" id="iedit_cool_'+id+'" type="number" value="'+(t.cooldownMinutes||30)+'" min="1" style="margin:0"></div></div>'+
            '<div style="display:flex;gap:6px;margin-top:6px"><button class="btn btn-primary btn-sm" onclick="saveIdleTask(\\''+id+'\\')">Speichern</button><button class="btn btn-secondary btn-sm" onclick="this.closest(\\'.edit-form\\').remove()">Abbrechen</button></div>';
          el.appendChild(form);
        }

        async function saveIdleTask(id){
          const name=document.getElementById('iedit_name_'+id).value.trim();
          const prompt=document.getElementById('iedit_prompt_'+id).value.trim();
          const priority=document.getElementById('iedit_prio_'+id).value;
          const cooldown=parseInt(document.getElementById('iedit_cool_'+id).value)||30;
          if(!name) return;
          await api('/idle-tasks',{method:'POST',body:JSON.stringify({action:'update',id,name,prompt,priority,cooldownMinutes:cooldown})});
          loadIdleTasks();showToast('Idle-Aufgabe gespeichert','success');
        }

        async function toggleIdleTask(id,enabled){
          await api('/idle-tasks',{method:'POST',body:JSON.stringify({action:'update',id,enabled})});
          loadIdleTasks();
        }

        async function deleteIdleTask(id){
          if(!confirm('Idle-Aufgabe wirklich löschen?'))return;
          await api('/idle-tasks',{method:'POST',body:JSON.stringify({action:'delete',id})});
          loadIdleTasks();
        }

        // ─── Memory ───
        async function loadMemory(){
          try{
            const data=await api('/memory/entries');
            memoryEntries=data.entries||[];
            memoryTags={};
            memoryEntries.forEach(e=>(e.tags||[]).forEach(t=>{memoryTags[t]=(memoryTags[t]||0)+1}));
            const byType={kurzzeit:0,langzeit:0,wissen:0,lösungen:0,fehler:0};
            memoryEntries.forEach(e=>{const t=e.memoryType||e.type||'kurzzeit';byType[t]=(byType[t]||0)+1});
            document.getElementById('memStats').innerHTML=
              '<div class="mem-stat"><div class="num" style="color:var(--teal)">'+byType.kurzzeit+'</div><div class="lbl">Kurzzeit</div></div>'+
              '<div class="mem-stat"><div class="num" style="color:var(--accent)">'+byType.langzeit+'</div><div class="lbl">Langzeit</div></div>'+
              '<div class="mem-stat"><div class="num" style="color:var(--orange)">'+byType.wissen+'</div><div class="lbl">Wissen</div></div>'+
              '<div class="mem-stat"><div class="num" style="color:#4da6ff">'+byType.lösungen+'</div><div class="lbl">Lösungen</div></div>'+
              '<div class="mem-stat"><div class="num" style="color:#ef4444">'+byType.fehler+'</div><div class="lbl">Fehler</div></div>'+
              '<div class="mem-stat"><div class="num">'+memoryEntries.length+'</div><div class="lbl">Gesamt</div></div>';
            renderTagBar();filterMemory();
          }catch(e){
            document.getElementById('memEntries').innerHTML='<div class="empty-state"><i data-lucide="alert-circle"></i><p>Fehler beim Laden</p></div>';
            lucide.createIcons();
          }
        }

        function renderTagBar(){
          const bar=document.getElementById('memTagBar');
          const sorted=Object.entries(memoryTags).sort((a,b)=>b[1]-a[1]).slice(0,15);
          bar.innerHTML=sorted.map(([tag,count])=>
            '<span class="tag-pill'+(filterTag===tag?' active':'')+'" onclick="setMemTag(\\''+tag+'\\')">'+esc(tag)+' ('+count+')</span>'
          ).join('');
        }

        function setMemType(type,el){
          filterType=(filterType===type)?null:type;
          document.querySelectorAll('#memTypeFilter .pill').forEach(c=>c.classList.remove('active'));
          if(filterType===null) document.querySelector('#memTypeFilter .pill').classList.add('active');
          else if(el) el.classList.add('active');
          filterMemory();
        }

        function setMemTag(tag){
          filterTag=(filterTag===tag)?null:tag;
          renderTagBar();filterMemory();
        }

        function filterMemory(){
          const search=(document.getElementById('memSearch').value||'').toLowerCase();
          let f=memoryEntries;
          if(filterType) f=f.filter(e=>(e.memoryType||e.type)===filterType);
          if(filterTag) f=f.filter(e=>(e.tags||[]).some(t=>t.toLowerCase()===filterTag.toLowerCase()));
          if(search) f=f.filter(e=>(e.text||'').toLowerCase().includes(search)||(e.tags||[]).join(' ').toLowerCase().includes(search));

          const area=document.getElementById('memEntries');
          if(!f.length){area.innerHTML='<div class="empty-state"><i data-lucide="brain"></i><p>Keine Erinnerungen gefunden</p></div>';lucide.createIcons();return}
          area.innerHTML=f.map(e=>{
            const tags=(e.tags||[]).map(t=>'<span class="mem-tag">#'+esc(t)+'</span>').join(' ');
            const tc=e.memoryType||e.type||'kurzzeit';
            const tl=tc==='langzeit'?'Langzeit':tc==='wissen'?'Wissen':tc==='lösungen'?'Lösungen':tc==='fehler'?'Fehler':'Kurzzeit';
            const val=e.valence||0;
            const valBadge=val!==0?'<span class="mem-valence" style="background:'+(val>0?'rgba(0,200,0,0.15);color:#0c0':'rgba(200,0,0,0.15);color:#c00')+'">V='+(val>0?'+':'')+val+'</span>':'';
            const dt=e.timestamp?new Date(e.timestamp).toLocaleDateString('de-DE',{day:'2-digit',month:'2-digit',year:'2-digit',hour:'2-digit',minute:'2-digit'}):'';
            return '<div class="mem-card" id="mem_'+e.id+'"><div class="mem-header">'+
              '<span class="mem-badge '+tc+'">'+tl+'</span>'+valBadge+' '+tags+
              '<button class="mem-edit" onclick="editMem(\\''+e.id+'\\')"><i data-lucide="pencil" style="width:13px;height:13px"></i></button>'+
              '<button class="mem-delete" onclick="deleteMem(\\''+e.id+'\\')"><i data-lucide="x" style="width:14px;height:14px"></i></button>'+
              '</div><div class="mem-text" id="memtext_'+e.id+'">'+esc(e.text)+'</div><div class="mem-date">'+dt+'</div></div>';
          }).join('');
          lucide.createIcons();
        }

        function toggleMemForm(){document.getElementById('memForm').classList.toggle('show')}

        async function createMemory(){
          const text=document.getElementById('memText').value.trim();
          if(!text)return;
          const type=document.getElementById('memType').value;
          const tags=document.getElementById('memTags').value.split(',').map(t=>t.trim()).filter(Boolean);
          await api('/memory/entries',{method:'POST',body:JSON.stringify({text,type,tags})});
          document.getElementById('memText').value='';document.getElementById('memTags').value='';
          toggleMemForm();loadMemory();
        }

        function editMem(id){
          const entry=memoryEntries.find(e=>e.id===id);
          if(!entry) return;
          const textEl=document.getElementById('memtext_'+id);
          if(!textEl) return;
          textEl.innerHTML='<textarea class="mem-edit-area" id="memedit_'+id+'" style="width:100%;min-height:60px;background:var(--bg-primary);border:0.5px solid var(--accent);color:var(--text);padding:8px;border-radius:6px;font-size:12px;font-family:inherit;resize:vertical">'+esc(entry.text)+'</textarea>'+
            '<div style="display:flex;gap:6px;margin-top:6px">'+
            '<button class="btn btn-primary btn-sm" onclick="saveMem(\\''+id+'\\')">Speichern</button>'+
            '<button class="btn btn-secondary btn-sm" onclick="filterMemory()">Abbrechen</button></div>';
        }
        async function saveMem(id){
          const area=document.getElementById('memedit_'+id);
          if(!area) return;
          const newText=area.value.trim();
          if(!newText) return;
          await api('/memory/entries',{method:'PUT',body:JSON.stringify({id,text:newText})});
          loadMemory();
        }
        async function deleteMem(id){
          await api('/memory/entries',{method:'DELETE',body:JSON.stringify({id})});
          loadMemory();
        }

        // ─── Settings ───
        async function loadSettings(){
          try{
            const[metrics,health,models]=await Promise.all([api('/metrics'),api('/health'),api('/models')]);
            document.getElementById('settingsMetrics').innerHTML=
              statCard('Anfragen',metrics.chat_requests||0,'green')+
              statCard('Tool-Aufrufe',metrics.tool_calls||0,'accent')+
              statCard('Tokens',metrics.tokens_total||0,'orange')+
              statCard('Fehler',metrics.errors||0,'red')+
              statCard('Uptime',Math.round((metrics.uptime||0)/60)+' min','green')+
              statCard('Latenz',Math.round(metrics.avg_latency_ms||0)+' ms','accent');

            document.getElementById('daemonInfo').innerHTML=
              '<div class="settings-row"><span class="settings-label">Version</span><span class="settings-value">'+(health.version||'?')+'</span></div>'+
              '<div class="settings-row"><span class="settings-label">PID</span><span class="settings-value">'+(health.pid||'?')+'</span></div>'+
              '<div class="settings-row"><span class="settings-label">Status</span><span class="settings-value" style="color:var(--green)">Online</span></div>'+
              '<div class="settings-row"><span class="settings-label">Modell</span><span class="settings-value">'+(metrics.model||'?')+'</span></div>';
            document.getElementById('aboutVersion').textContent='Alpha '+(health.version||'v\(KoboldVersion.current)');

            const modelList=document.getElementById('modelList');
            const available=models.models||[];
            const active=models.active||'';
            if(available.length){
              const opts=available.map(m=>{const name=m.name||m;const sel=name===active;return '<option value="'+esc(name)+'"'+(sel?' selected':'')+'>'+esc(name)+(m.size?' ('+m.size+')':'')+'</option>'}).join('');
              modelList.innerHTML='<div class="settings-row"><div class="s-left"><span class="settings-label">Aktives Modell</span><span class="s-desc">'+available.length+' verfügbar</span></div><select class="s-select" onchange="setModel(this.value)" style="min-width:200px">'+opts+'</select></div>';
            } else {
              modelList.innerHTML='<div style="color:var(--text-secondary);font-size:13px">Keine Modelle verfügbar — ist Ollama aktiv?</div>';
            }
          }catch(e){
            document.getElementById('settingsMetrics').innerHTML='<div style="color:var(--red);font-size:13px;grid-column:1/-1">Daemon nicht erreichbar</div>';
            document.getElementById('daemonInfo').innerHTML='<div style="color:var(--red);font-size:13px">Offline</div>';
          }
          loadActivityLog();
        }

        function statCard(label,val,color){
          return '<div class="stat-card"><div class="label">'+label+'</div><div class="value '+color+'">'+val+'</div></div>';
        }

        async function setModel(name){
          await api('/model/set',{method:'POST',body:JSON.stringify({model:name})});
          loadSettings();
        }

        // ─── Core Memory ───
        // ─── Activity Log ───
        async function loadActivityLog(){
          try{
            const data=await api('/trace');
            const log=document.getElementById('activityLog');
            const events=data.events||data.trace||[];
            if(!events.length){log.innerHTML='<div style="color:var(--text-secondary);font-size:13px">Keine Aktivitäten</div>';return}
            const recent=events.slice(-30).reverse();
            log.innerHTML=recent.map(ev=>{
              const time=ev.timestamp?new Date(ev.timestamp).toLocaleTimeString('de-DE',{hour:'2-digit',minute:'2-digit',second:'2-digit'}):'';
              const type=ev.type||ev.event||'event';
              const detail=ev.detail||ev.message||ev.tool||'';
              const color=type.includes('error')?'var(--red)':type.includes('tool')?'var(--green)':'var(--text-secondary)';
              return '<div style="padding:6px 0;border-bottom:0.5px solid var(--separator);font-size:12px;display:flex;gap:10px;align-items:baseline">'+
                '<span style="color:var(--text-tertiary);font-family:SF Mono,monospace;font-size:10px;flex-shrink:0">'+time+'</span>'+
                '<span style="color:'+color+';font-weight:600;min-width:60px">'+esc(type)+'</span>'+
                '<span style="color:var(--text-secondary);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+esc(detail)+'</span>'+
                '</div>';
            }).join('');
          }catch(e){
            document.getElementById('activityLog').innerHTML='<div style="color:var(--red);font-size:13px">Fehler: '+esc(e.message)+'</div>';
          }
        }

        // ─── Metrics Reset ───
        async function resetMetrics(){
          try{
            await api('/metrics/reset',{method:'POST'});
            loadSettings();
          }catch(e){alert('Fehler: '+e.message)}
        }

        // ─── Agent Models ───
        async function loadAgentModels(){
          try{
            const models=await api('/models');
            const available=models.models||[];
            const active=models.active||'';
            const area=document.getElementById('agentModelsArea');
            const agents=['General','Coder','Web'];
            const opts=available.map(m=>{const name=m.name||m;const sel=name===active;return '<option value="'+esc(name)+'"'+(sel?' selected':'')+'>'+esc(name)+'</option>'}).join('');
            let html='';
            agents.forEach(agent=>{
              html+='<div class="settings-row"><div class="s-left"><span class="settings-label">'+agent+'</span><span class="s-desc">Agent-Modell</span></div><select class="s-select" onchange="setModel(this.value)" style="min-width:180px">'+opts+'</select></div>';
            });
            area.innerHTML=html;
            lucide.createIcons();
          }catch(e){
            document.getElementById('agentModelsArea').innerHTML='<div style="color:var(--red);font-size:13px">Fehler: '+esc(e.message)+'</div>';
          }
        }

        // ─── Connections (read-only) ───
        async function loadConnections(){
          const area=document.getElementById('connectionsArea');
          const services=[
            {name:'GitHub',icon:'github',key:'kobold.github.token'},
            {name:'Telegram',icon:'send',key:'kobold.telegram.token'},
            {name:'Google Drive',icon:'hard-drive',key:'kobold.google.accessToken'},
            {name:'SoundCloud',icon:'music',key:'kobold.soundcloud.accessToken'},
            {name:'YouTube',icon:'youtube',key:'kobold.youtube.accessToken'},
            {name:'Microsoft',icon:'monitor',key:'kobold.microsoft.accessToken'},
            {name:'Slack',icon:'hash',key:'kobold.slack.accessToken'},
            {name:'Notion',icon:'book-open',key:'kobold.notion.token'},
            {name:'Reddit',icon:'message-square',key:'kobold.reddit.accessToken'},
            {name:'WhatsApp',icon:'smartphone',key:'kobold.whatsapp.phone'},
            {name:'Suno',icon:'music-2',key:'kobold.suno.apiKey'},
          ];
          area.innerHTML=services.map(s=>{
            return '<div class="settings-row"><span class="settings-label" style="display:flex;align-items:center;gap:8px"><i data-lucide="'+s.icon+'" style="width:16px;height:16px;color:var(--accent)"></i>'+s.name+'</span><span class="gh-badge"><span class="gh-dot green"></span>Desktop</span></div>';
          }).join('');
          lucide.createIcons();
        }

        // ─── Generic Settings Load/Save ───
        let _settingsCache={};
        async function loadAllSettings(){
          try{
            _settingsCache=await api('/settings');
            document.querySelectorAll('[data-key]').forEach(el=>{
              const key=el.dataset.key;
              const val=_settingsCache[key];
              if(val===undefined) return;
              if(el.type==='checkbox') el.checked=!!val;
              else if(el.tagName==='SELECT') el.value=String(val);
              else if(el.type==='range'){
                // Slider: Werte 0-1 auf 0-100 mappen wenn max=100
                const max=parseInt(el.max)||100;
                const rawVal=(typeof val==='number' && val<=1 && max>=10)?(val*100):val;
                el.value=String(Math.round(rawVal));
                const label=el.parentElement.querySelector('.s-slider-val');
                if(label) label.textContent=Math.round(rawVal)+'%';
              }
              else if(el.tagName==='TEXTAREA') el.value=val||'';
              else el.value=val||'';
            });
            // Daemon Port readonly
            const portEl=document.getElementById('daemonPortInfo');
            if(portEl) portEl.textContent=(_settingsCache['kobold.port']||8080);
          }catch(e){console.error('loadAllSettings:',e)}
        }

        async function saveSetting(key,value){
          try{
            await api('/settings',{method:'POST',body:JSON.stringify({key,value})});
            _settingsCache[key]=value;
            showToast('Gespeichert','success');
          }catch(e){showToast('Fehler: '+e.message,'error')}
        }

        function saveTextarea(key){
          const el=document.querySelector('[data-key="'+key+'"]');
          if(!el) return;
          saveSetting(key,el.value);
        }

        // Auto-save für Toggles, Selects, Sliders
        function initSettingsListeners(){
          document.querySelectorAll('.s-toggle input[data-key]').forEach(el=>{
            el.addEventListener('change',()=>saveSetting(el.dataset.key,el.checked));
          });
          document.querySelectorAll('.s-select[data-key]').forEach(el=>{
            el.addEventListener('change',()=>{
              const v=el.value;
              // Int-Werte korrekt senden
              const num=parseInt(v);
              saveSetting(el.dataset.key,isNaN(num)?v:num);
            });
          });
          document.querySelectorAll('.s-slider[data-key]').forEach(el=>{
            const label=el.parentElement.querySelector('.s-slider-val');
            el.addEventListener('input',()=>{
              if(label) label.textContent=el.value+'%';
            });
            el.addEventListener('change',()=>{
              const max=parseInt(el.max)||100;
              const raw=parseInt(el.value);
              // 0-100 Slider → 0.0-1.0 für Werte die als Double gespeichert werden
              const val=(max>=10 && raw<=100)?raw/100:raw;
              saveSetting(el.dataset.key,val);
            });
          });
          // Text-Inputs mit Enter speichern
          document.querySelectorAll('.form-input[data-key]').forEach(el=>{
            el.addEventListener('keydown',ev=>{
              if(ev.key==='Enter'){ev.preventDefault();saveSetting(el.dataset.key,el.value)}
            });
            el.addEventListener('blur',()=>saveSetting(el.dataset.key,el.value));
          });
        }

        // Skills laden
        async function loadSkills(){
          const area=document.getElementById('skillsArea');
          try{
            const data=await api('/skills');
            const skills=data.skills||[];
            if(!skills.length){area.innerHTML='<div style="color:var(--text-secondary)">Keine Skills gefunden</div>';return}
            area.innerHTML=skills.map(s=>{
              const name=s.name||s;
              const enabled=s.enabled!==false;
              return '<div class="settings-row"><div class="s-left"><span class="settings-label">'+esc(name)+'</span>'+(s.description?'<span class="s-desc">'+esc(s.description)+'</span>':'')+'</div>'+
                '<label class="s-toggle"><input type="checkbox" '+(enabled?'checked':'')+' onchange="toggleSkill(\\''+esc(name)+'\\',this.checked)"><span class="slider"></span></label></div>';
            }).join('');
          }catch(e){
            area.innerHTML='<div style="color:var(--text-secondary)">Skills nicht verfügbar</div>';
          }
        }

        async function toggleSkill(name,enabled){
          try{
            await api('/skills/toggle',{method:'POST',body:JSON.stringify({name,enabled})});
            showToast(name+(enabled?' aktiviert':' deaktiviert'),'success');
          }catch(e){showToast('Fehler: '+e.message,'error')}
        }

        // ─── Notifications ───
        let notifications=[];
        function toggleNotifPanel(){
          const panel=document.getElementById('notifPanel');
          if(panel) panel.classList.toggle('open');
        }
        function toggleHistorie(){
          document.getElementById('historiePopup').classList.toggle('open');
          document.getElementById('historieBackdrop').classList.toggle('open');
          if(document.getElementById('historiePopup').classList.contains('open')) renderHistorie();
        }
        function renderHistorie(){
          const list=document.getElementById('historieList');
          if(!list) return;
          let html='';
          sessions.forEach(s=>{
            const active=s.id===activeSessionId?' active':'';
            const d=s.messages.length?new Date(s.messages[s.messages.length-1].ts||Date.now()).toLocaleDateString('de-DE'):'';
            html+='<div class="historie-item'+active+'" onclick="activeSessionId=\\''+s.id+'\\';saveSessions();renderChat();toggleHistorie();switchTab(\\'chat\\',document.querySelector(\\'.nav-item\\'))">';
            html+='<span class="historie-actions"><button class="historie-del" onclick="event.stopPropagation();deleteSession(\\''+s.id+'\\');renderHistorie()">Loeschen</button></span>';
            html+=esc(s.name)+'<div class="historie-date">'+d+'</div></div>';
          });
          list.innerHTML=html||'<div style="color:var(--text-secondary);text-align:center;padding:20px">Keine Chats</div>';
          lucide.createIcons();
        }
        function toggleTaskHistorie(){
          document.getElementById('taskHistoriePopup').classList.toggle('open');
          document.getElementById('taskHistorieBackdrop').classList.toggle('open');
          if(document.getElementById('taskHistoriePopup').classList.contains('open')) renderTaskHistorie();
        }
        function renderTaskHistorie(){
          const list=document.getElementById('taskHistorieList');
          if(!list) return;
          const taskSessions=sessions.filter(s=>s.taskId);
          let html='';
          taskSessions.forEach(s=>{
            const active=s.id===activeSessionId?' active':'';
            const d=s.messages.length?new Date(s.messages[s.messages.length-1].ts||Date.now()).toLocaleDateString('de-DE'):'';
            html+='<div class="historie-item'+active+'" style="border-left-color:var(--orange)" onclick="activeSessionId=\\''+s.id+'\\';saveSessions();renderChat();toggleTaskHistorie();switchTab(\\'chat\\',document.querySelector(\\'.nav-item\\'))">';
            html+='<span class="historie-actions"><button class="historie-del" onclick="event.stopPropagation();deleteSession(\\''+s.id+'\\');renderTaskHistorie()">Loeschen</button></span>';
            html+=esc(s.name)+'<div class="historie-date">'+d+'</div></div>';
          });
          list.innerHTML=html||'<div style="color:var(--text-secondary);text-align:center;padding:20px">Keine Aufgaben-Chats</div>';
          lucide.createIcons();
        }
        function addNotification(title,text){
          notifications.unshift({title,text,time:new Date()});
          if(notifications.length>20) notifications=notifications.slice(0,20);
          renderNotifications();
          const count=document.getElementById('ghBellCount');
          if(count){count.textContent=notifications.length;count.style.display='';}
        }
        function renderNotifications(){
          const list=document.getElementById('notifList');
          if(!list)return;
          if(!notifications.length){list.innerHTML='<div class="notif-empty">Keine neuen Benachrichtigungen</div>';return;}
          list.innerHTML=notifications.map(n=>{
            const ago=Math.round((Date.now()-n.time.getTime())/60000);
            const t=ago<1?'Gerade eben':ago<60?ago+'m':Math.round(ago/60)+'h';
            return '<div class="notif-item"><div class="notif-title">'+esc(n.title)+'</div><div>'+esc(n.text)+'</div><div class="notif-time">'+t+'</div></div>';
          }).join('');
        }

        // ─── Weather ───
        function fetchWeather(){
          if(navigator.geolocation){
            navigator.geolocation.getCurrentPosition(
              pos=>fetchWeatherData(pos.coords.latitude,pos.coords.longitude),
              ()=>fetchWeatherData(48.14,11.58) // Fallback: München
            );
          } else { fetchWeatherData(48.14,11.58); }
        }
        function fetchWeatherData(lat,lon){
          fetch('https://api.open-meteo.com/v1/forecast?latitude='+lat+'&longitude='+lon+'&current_weather=true')
            .then(r=>r.json()).then(d=>{
              if(!d.current_weather) return;
              const t=Math.round(d.current_weather.temperature);
              const code=d.current_weather.weathercode;
              const icon=weatherIcon(code);
              const el=document.getElementById('weatherTemp');
              const ic=document.getElementById('weatherIcon');
              if(el) el.textContent=t+'°';
              if(ic) ic.textContent=icon;
            }).catch(()=>{});
        }
        function weatherIcon(code){
          if(code===0) return '\\u2600'; // ☀
          if(code<=3) return '\\u26C5'; // ⛅
          if(code<=49) return '\\u2601'; // ☁
          if(code<=69) return '\\uD83C\\uDF27'; // 🌧
          if(code<=79) return '\\u2744'; // ❄
          if(code<=99) return '\\u26C8'; // ⛈
          return '\\u2600';
        }

        // ─── Sprechen/Voice ───
        let _voiceState='idle'; // idle|listening|recording|transcribing|thinking|speaking
        let _voiceInputMethod='vad'; // vad|ptt
        let _voiceTranscript=[];
        let _voiceSessionChars=0;
        let _voiceRecognition=null;
        let _voiceMediaRecorder=null;
        let _voiceAudioChunks=[];
        let _voiceWaveformBars=[];
        let _voiceAnimFrame=null;
        let _voiceAnalyser=null;
        let _voiceAudioCtx=null;
        let _voicePlaybackCtx=null;
        let _voiceStream=null;
        let _voicePTTActive=false;
        let _voiceTTSEnabled=localStorage.getItem('kobold.voice.tts')!=='false'; // default: an

        function toggleVoiceTTS(){
          _voiceTTSEnabled=!_voiceTTSEnabled;
          localStorage.setItem('kobold.voice.tts',_voiceTTSEnabled?'true':'false');
          const btn=document.getElementById('voiceTTSToggle');
          if(btn){
            btn.style.color=_voiceTTSEnabled?'var(--orange)':'var(--text-tertiary)';
            btn.style.borderColor=_voiceTTSEnabled?'var(--orange)':'var(--glass-border)';
            btn.innerHTML=_voiceTTSEnabled?'<i data-lucide="volume-2" style="width:16px;height:16px"></i>':'<i data-lucide="volume-x" style="width:16px;height:16px"></i>';
            if(typeof lucide!=='undefined') lucide.createIcons();
          }
          showToast(_voiceTTSEnabled?'Sprachausgabe an':'Sprachausgabe aus','success');
        }

        function initVoiceTab(){
          // Init waveform bars
          const wf=document.getElementById('voiceWaveform');
          if(wf && !wf.children.length){
            for(let i=0;i<30;i++){
              const bar=document.createElement('div');
              bar.className='voice-bar';
              bar.style.height='4px';
              bar.style.flex='1';
              wf.appendChild(bar);
              _voiceWaveformBars.push(bar);
            }
          }
          // PTT uses same voiceBtn as toggle (click to start/stop)
          // TTS-Toggle initialisieren
          const ttsBtn=document.getElementById('voiceTTSToggle');
          if(ttsBtn){
            ttsBtn.style.color=_voiceTTSEnabled?'var(--orange)':'var(--text-tertiary)';
            ttsBtn.style.borderColor=_voiceTTSEnabled?'var(--orange)':'var(--glass-border)';
            ttsBtn.innerHTML=_voiceTTSEnabled?'<i data-lucide="volume-2" style="width:16px;height:16px"></i>':'<i data-lucide="volume-x" style="width:16px;height:16px"></i>';
          }
          updateVoiceUI();
          lucide.createIcons();
        }

        function voiceInputChanged(method){
          _voiceInputMethod=method;
          if(_voiceState!=='idle') voiceStop();
          updateVoiceUI();
          // Both modes use onclick toggle now
          const btn=document.getElementById('voiceBtn');
          if(!btn)return;
          btn.onmousedown=null;btn.onmouseup=null;btn.onmouseleave=null;
          btn.ontouchstart=null;btn.ontouchend=null;
          btn.onclick=voiceBtnClick;
        }

        function voiceBtnClick(){
          if(_voiceInputMethod==='ptt'){
            // PTT Toggle: Klick 1 = Start Aufnahme, Klick 2 = Stop + Senden
            if(_voiceState==='recording'){
              voiceStopPTT();
            } else if(_voiceState==='idle'){
              voiceStartPTT();
            }
          } else {
            // VAD: Toggle listening
            if(_voiceState==='idle'||_voiceState==='listening'){
              voiceStart();
            } else {
              voiceStop();
            }
          }
        }

        async function voiceStart(){
          // Secure-Context-Check: getUserMedia braucht HTTPS oder localhost
          if(!window.isSecureContext){
            showToast('Mikrofon braucht HTTPS oder localhost. Bitte über https:// oder http://localhost aufrufen.','error');
            setVoiceState('idle');
            return;
          }
          if(!navigator.mediaDevices||!navigator.mediaDevices.getUserMedia){
            showToast('Mikrofon-API nicht verfügbar. Bitte HTTPS verwenden.','error');
            setVoiceState('idle');
            return;
          }

          // Permission vorab prüfen (zeigt Prompt falls nötig)
          try {
            if(navigator.permissions&&navigator.permissions.query){
              const perm=await navigator.permissions.query({name:'microphone'});
              if(perm.state==='denied'){
                showToast('Mikrofon-Zugriff blockiert. Bitte in den Browser-Einstellungen erlauben.','error');
                setVoiceState('idle');
                return;
              }
            }
          } catch(e){/* permissions.query nicht überall unterstützt, weiter mit getUserMedia */}

          try {
            _voiceStream=await navigator.mediaDevices.getUserMedia({audio:{sampleRate:16000,channelCount:1,echoCancellation:true,noiseSuppression:true}});
            _voiceAudioCtx=new (window.AudioContext||window.webkitAudioContext)({sampleRate:16000});
            const source=_voiceAudioCtx.createMediaStreamSource(_voiceStream);
            _voiceAnalyser=_voiceAudioCtx.createAnalyser();
            _voiceAnalyser.fftSize=256;
            source.connect(_voiceAnalyser);
            startWaveformAnim();

            // Playback-AudioContext im User-Gesture erstellen (unlocked VAD TTS)
            if(!_voicePlaybackCtx||_voicePlaybackCtx.state==='closed'){
              _voicePlaybackCtx=new (window.AudioContext||window.webkitAudioContext)();
              const sBuf=_voicePlaybackCtx.createBuffer(1,1,_voicePlaybackCtx.sampleRate);
              const sSrc=_voicePlaybackCtx.createBufferSource();
              sSrc.buffer=sBuf;sSrc.connect(_voicePlaybackCtx.destination);sSrc.start();
            }

            // Web Speech API for STT
            if('webkitSpeechRecognition' in window || 'SpeechRecognition' in window){
              const SR=window.SpeechRecognition||window.webkitSpeechRecognition;
              _voiceRecognition=new SR();
              _voiceRecognition.lang='de-DE';
              _voiceRecognition.continuous=false;
              _voiceRecognition.interimResults=true;
              _voiceRecognition.onresult=(e)=>{
                let text='';
                for(let i=e.resultIndex;i<e.results.length;i++){
                  text+=e.results[i][0].transcript;
                  if(e.results[i].isFinal){
                    addVoiceEntry('user',text.trim());
                    setVoiceState('thinking');
                    sendVoiceToAgent(text.trim());
                  }
                }
              };
              _voiceRecognition.onerror=(e)=>{
                if(e.error==='not-allowed'){
                  showToast('Mikrofon-Berechtigung verweigert. Bitte im Browser erlauben und Seite neu laden.','error');
                } else if(e.error!=='no-speech'&&e.error!=='aborted'){
                  showToast('Spracherkennung: '+e.error,'error');
                }
                setVoiceState('idle');
              };
              _voiceRecognition.onend=()=>{
                if(_voiceState==='recording'||_voiceState==='listening'){
                  // Restart for continuous listening
                  try{_voiceRecognition.start();}catch(ex){}
                }
              };
              _voiceRecognition.start();
              setVoiceState('listening');
            } else {
              showToast('Spracherkennung nicht unterstützt. Bitte Chrome oder Edge verwenden.','error');
              voiceStop();
            }
          } catch(err){
            if(err.name==='NotAllowedError'){
              showToast('Mikrofon-Berechtigung verweigert. Bitte im Browser erlauben (Schloss-Icon in der Adressleiste).','error');
            } else if(err.name==='NotFoundError'){
              showToast('Kein Mikrofon gefunden. Bitte Mikrofon anschließen.','error');
            } else {
              showToast('Mikrofon-Fehler: '+err.message,'error');
            }
            setVoiceState('idle');
          }
        }

        function voiceStop(){
          if(_voiceRecognition){try{_voiceRecognition.abort();}catch(e){}_voiceRecognition=null;}
          if(_voiceStream){_voiceStream.getTracks().forEach(t=>t.stop());_voiceStream=null;}
          if(_voiceAudioCtx){_voiceAudioCtx.close();_voiceAudioCtx=null;}
          if(_voicePlaybackCtx){try{_voicePlaybackCtx.close();}catch(e){}_voicePlaybackCtx=null;}
          _voiceAnalyser=null;
          if(_voiceAnimFrame){cancelAnimationFrame(_voiceAnimFrame);_voiceAnimFrame=null;}
          _voiceWaveformBars.forEach(b=>b.style.height='4px');
          _voicePTTActive=false;
          setVoiceState('idle');
        }

        // Push-to-Talk Toggle: Klick 1 = Start, Klick 2 = Stop + Senden
        let _pttFinalTranscript='';
        let _pttInterimTranscript='';
        async function voiceStartPTT(){
          if(!window.isSecureContext){showToast('Mikrofon braucht HTTPS oder localhost.','error');return;}
          if(!navigator.mediaDevices||!navigator.mediaDevices.getUserMedia){showToast('Mikrofon-API nicht verfügbar.','error');return;}
          _pttFinalTranscript='';
          _pttInterimTranscript='';
          try{
            _voiceStream=await navigator.mediaDevices.getUserMedia({audio:{sampleRate:16000,channelCount:1,echoCancellation:true,noiseSuppression:true}});
            _voiceAudioCtx=new (window.AudioContext||window.webkitAudioContext)({sampleRate:16000});
            const source=_voiceAudioCtx.createMediaStreamSource(_voiceStream);
            _voiceAnalyser=_voiceAudioCtx.createAnalyser();_voiceAnalyser.fftSize=256;
            source.connect(_voiceAnalyser);
            startWaveformAnim();
            // Playback-AudioContext im User-Gesture erstellen
            if(!_voicePlaybackCtx||_voicePlaybackCtx.state==='closed'){
              _voicePlaybackCtx=new (window.AudioContext||window.webkitAudioContext)();
              const sBuf=_voicePlaybackCtx.createBuffer(1,1,_voicePlaybackCtx.sampleRate);
              const sSrc=_voicePlaybackCtx.createBufferSource();
              sSrc.buffer=sBuf;sSrc.connect(_voicePlaybackCtx.destination);sSrc.start();
            }
            if('webkitSpeechRecognition' in window||'SpeechRecognition' in window){
              const SR=window.SpeechRecognition||window.webkitSpeechRecognition;
              _voiceRecognition=new SR();
              _voiceRecognition.lang='de-DE';
              _voiceRecognition.continuous=true;
              _voiceRecognition.interimResults=true;
              _voiceRecognition.onresult=(e)=>{
                _pttInterimTranscript='';
                for(let i=e.resultIndex;i<e.results.length;i++){
                  if(e.results[i].isFinal){
                    _pttFinalTranscript+=(_pttFinalTranscript?' ':'')+e.results[i][0].transcript;
                  } else {
                    _pttInterimTranscript+=e.results[i][0].transcript;
                  }
                }
                // Live-Preview im Transkript
                const preview=(_pttFinalTranscript+' '+_pttInterimTranscript).trim();
                let liveEl=document.getElementById('pttLivePreview');
                if(!liveEl){
                  liveEl=document.createElement('div');
                  liveEl.id='pttLivePreview';
                  liveEl.style.cssText='padding:8px 12px;margin:8px 16px;border-radius:12px;background:var(--glass-bg);border:1px solid var(--orange);font-size:14px;color:var(--text-primary);opacity:0.8;font-style:italic';
                  const transcript=document.getElementById('voiceTranscript');
                  if(transcript) transcript.appendChild(liveEl);
                }
                liveEl.textContent=preview||'...';
              };
              _voiceRecognition.onerror=(e)=>{
                if(e.error==='not-allowed'){showToast('Mikrofon blockiert.','error');}
                else if(e.error!=='no-speech'&&e.error!=='aborted'){showToast('Spracherkennung: '+e.error,'error');}
                voiceCleanupPTT(); setVoiceState('idle');
              };
              _voiceRecognition.onend=()=>{
                // Restart if still recording (browser may stop after silence)
                if(_voiceState==='recording'){
                  try{_voiceRecognition.start();}catch(ex){}
                }
              };
              _voiceRecognition.start();
              setVoiceState('recording');
            } else {showToast('Spracherkennung nicht unterstützt.','error');}
          }catch(err){showToast('Mikrofon-Fehler: '+err.message,'error');setVoiceState('idle');}
        }

        // PTT Stop: Aufnahme beenden und Text senden
        function voiceStopPTT(){
          if(_voiceRecognition){try{_voiceRecognition.stop();}catch(e){}_voiceRecognition=null;}
          // Remove live preview
          const liveEl=document.getElementById('pttLivePreview');
          if(liveEl) liveEl.remove();
          // Collect final text
          const text=(_pttFinalTranscript+' '+_pttInterimTranscript).trim();
          voiceCleanupPTT();
          if(text){
            addVoiceEntry('user',text);
            setVoiceState('thinking');
            sendVoiceToAgent(text);
          } else {
            setVoiceState('idle');
          }
        }

        function voiceCleanupPTT(){
          if(_voiceStream){_voiceStream.getTracks().forEach(t=>t.stop());_voiceStream=null;}
          if(_voiceAudioCtx){_voiceAudioCtx.close();_voiceAudioCtx=null;}
          _voiceAnalyser=null;
          if(_voiceAnimFrame){cancelAnimationFrame(_voiceAnimFrame);_voiceAnimFrame=null;}
          _voiceWaveformBars.forEach(b=>b.style.height='4px');
        }

        function startWaveformAnim(){
          if(!_voiceAnalyser)return;
          const data=new Uint8Array(_voiceAnalyser.frequencyBinCount);
          function draw(){
            if(!_voiceAnalyser){return;}
            _voiceAnalyser.getByteFrequencyData(data);
            const step=Math.floor(data.length/_voiceWaveformBars.length);
            for(let i=0;i<_voiceWaveformBars.length;i++){
              const val=data[i*step]||0;
              const h=Math.max(4,val/255*36);
              _voiceWaveformBars[i].style.height=h+'px';
              const stateColor=_voiceState==='speaking'?'var(--blue)':_voiceState==='recording'?'#f24040':'var(--green)';
              _voiceWaveformBars[i].style.background=stateColor;
            }
            _voiceAnimFrame=requestAnimationFrame(draw);
          }
          draw();
        }

        function setVoiceState(s){
          _voiceState=s;
          updateVoiceUI();
        }

        function updateVoiceUI(){
          const btn=document.getElementById('voiceBtn');
          const dot=document.getElementById('voiceStatusDot');
          const txt=document.getElementById('voiceStatusText');
          const proc=document.getElementById('voiceProcessing');
          const procLabel=document.getElementById('voiceProcessLabel');
          const credits=document.getElementById('voiceCredits');
          if(!btn)return;

          const isPTT=_voiceInputMethod==='ptt';
          const icons={idle:'mic',listening:'ear',recording:'mic',transcribing:'loader',thinking:'cpu',speaking:'volume-2'};
          const colors={idle:'var(--green)',listening:'var(--green)',recording:'#f24040',transcribing:'var(--orange)',thinking:'var(--orange)',speaking:'var(--blue)'};
          const labels={idle:isPTT?'Antippen':'Bereit',listening:'Hört zu...',recording:'Aufnahme...',transcribing:'Transkribiere...',thinking:'Denkt...',speaking:'Spricht...'};

          btn.innerHTML='<i data-lucide="'+(icons[_voiceState]||'mic')+'" style="width:20px;height:20px"></i>';
          // Red mic button when recording
          if(_voiceState==='recording'){
            btn.style.background='#f24040';btn.style.color='#fff';btn.style.animation='sttPulse 1s ease-in-out infinite';
          } else {
            btn.style.background='';btn.style.color='';btn.style.animation='';
          }
          if(dot) dot.style.background=colors[_voiceState]||'var(--green)';
          if(txt) txt.textContent=labels[_voiceState]||'Bereit';

          const isProcessing=_voiceState==='transcribing'||_voiceState==='thinking'||_voiceState==='speaking';
          if(proc) proc.style.display=isProcessing?'block':'none';
          if(procLabel) procLabel.textContent=labels[_voiceState]||'Verarbeite...';

          if(credits) credits.textContent=_voiceSessionChars>0?_voiceSessionChars+' Zeichen':'';

          // Stop-Button: sichtbar wenn aktiv (nicht idle)
          const stopBtn=document.getElementById('voiceStopBtn');
          if(stopBtn) stopBtn.style.display=(_voiceState!=='idle')?'inline-flex':'none';

          lucide.createIcons();
        }

        function voiceForceStop(){
          // Alles stoppen: Recognition, Stream, TTS, Player
          if(_voiceRecognition){try{_voiceRecognition.abort();}catch(e){}}
          window.speechSynthesis&&window.speechSynthesis.cancel();
          voiceStop();
          showToast('Gestoppt','info');
        }

        function addVoiceEntry(role,text){
          const chars=role==='assistant'?text.length:0;
          _voiceSessionChars+=chars;
          _voiceTranscript.push({role,text,time:new Date(),chars});
          renderVoiceTranscript();
        }

        function renderVoiceTranscript(){
          const area=document.getElementById('voiceTranscript');
          if(!area)return;
          if(!_voiceTranscript.length){
            area.innerHTML='<div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:12px;color:var(--text-tertiary)">'+
              '<i data-lucide="mic" style="width:48px;height:48px;opacity:0.3"></i>'+
              '<div style="font-size:13px;text-align:center">Drücke den Mikrofon-Button und sprich.<br>Dein Gespräch erscheint hier.</div></div>';
            lucide.createIcons();
            return;
          }
          area.innerHTML=_voiceTranscript.map(e=>{
            const isUser=e.role==='user';
            const time=e.time.toLocaleTimeString('de-DE',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
            const creditBadge=e.chars>0?'<span style="font-size:9px;color:var(--text-tertiary);font-family:monospace">'+e.chars+' Z</span>':'';
            return '<div style="display:flex;'+(isUser?'justify-content:flex-end':'')+';margin-bottom:8px">'+
              '<div style="max-width:80%;padding:10px;border-radius:10px;background:'+(isUser?'rgba(255,204,0,0.08)':'rgba(48,209,88,0.06)')+'">'+
              '<div style="display:flex;align-items:center;gap:4px;margin-bottom:4px">'+
              '<i data-lucide="'+(isUser?'user':'cpu')+'" style="width:10px;height:10px;color:'+(isUser?'var(--orange)':'var(--green)')+'"></i>'+
              '<span style="font-size:11px;font-weight:600;color:'+(isUser?'var(--orange)':'var(--green)')+'">'+(isUser?'Du':'Kobold')+'</span>'+
              '<span style="flex:1"></span>'+
              creditBadge+
              '<span style="font-size:10px;color:var(--text-tertiary)">'+time+'</span></div>'+
              '<div style="font-size:13px;color:var(--text-primary)">'+esc(e.text)+'</div></div></div>';
          }).join('');
          area.scrollTop=area.scrollHeight;
          lucide.createIcons();
        }

        async function sendVoiceToAgent(text){
          try{
            const ah=getAuthHeader();
            const history=_voiceTranscript.filter(e=>e.role).map(e=>({role:e.role,content:e.text}));
            const body={message:text,agent_type:'general',provider:'ollama',source:'voice'};
            if(history.length>1) body.conversation_history=history.slice(-20);
            const hdrs={'Content-Type':'application/json'};
            if(ah) hdrs['Authorization']=ah;
            const resp=await fetch(API+'/agent/stream',{method:'POST',headers:hdrs,body:JSON.stringify(body)});
            if(!resp.ok){addVoiceEntry('assistant','Fehler: HTTP '+resp.status);setVoiceState('idle');return;}
            const reader=resp.body.getReader();
            const dec=new TextDecoder();
            let fullText='';let buf='';
            setVoiceState('thinking');

            // ─── Phrase-Streaming TTS (Low-Latency) ───
            const elEnabled=_voiceTTSEnabled&&_settingsCache&&_settingsCache['kobold.elevenlabs.enabled'];
            let spokenLen=0;
            let audioQueue=[];   // [{promise:Promise<{audio,content_type}|null>, text:string}]
            let playIdx=0;
            let streamEnded=false;
            let playerDone=null;
            let playerPromise=new Promise(r=>{playerDone=r;});
            let playerActive=false;

            // Pre-fetch ElevenLabs audio for a phrase (fire-and-forget)
            function prefetchAudio(sentence){
              if(!elEnabled) return Promise.resolve(null);
              const voiceId=_settingsCache['kobold.elevenlabs.voiceId']||'';
              const modelId=_settingsCache['kobold.elevenlabs.model']||'eleven_flash_v2_5';
              const h={'Content-Type':'application/json'};
              const a=getAuthHeader();if(a) h['Authorization']=a;
              return fetch(API+'/tts/elevenlabs/speak',{
                method:'POST',headers:h,
                body:JSON.stringify({text:sentence,voice_id:voiceId,model_id:modelId})
              }).then(r=>r.ok?r.json():null).then(j=>j&&j.audio?j:null).catch(()=>null);
            }

            // Play one audio chunk via pre-unlocked AudioContext (VAD-safe)
            function playChunk(data){
              const binary=atob(data.audio);
              const bytes=new Uint8Array(binary.length);
              for(let i=0;i<binary.length;i++) bytes[i]=binary.charCodeAt(i);
              // AudioContext-Playback: funktioniert ohne User-Gesture weil Context im Click erstellt wurde
              if(_voicePlaybackCtx&&_voicePlaybackCtx.state!=='closed'){
                return _voicePlaybackCtx.decodeAudioData(bytes.buffer.slice(0)).then(audioBuffer=>{
                  return new Promise(resolve=>{
                    const src=_voicePlaybackCtx.createBufferSource();
                    src.buffer=audioBuffer;
                    src.connect(_voicePlaybackCtx.destination);
                    src.onended=resolve;
                    src.start();
                    setTimeout(resolve,Math.ceil(audioBuffer.duration*1000)+500);
                  });
                }).catch(()=>{});
              }
              // Fallback: Audio element (funktioniert nur bei PTT/User-Gesture)
              const blob=new Blob([bytes],{type:data.content_type||'audio/mpeg'});
              const url=URL.createObjectURL(blob);
              const audio=new Audio(url);
              return new Promise(res=>{audio.onended=()=>{URL.revokeObjectURL(url);res();};audio.onerror=()=>{URL.revokeObjectURL(url);res();};audio.play().catch(res);});
            }

            // Browser TTS for one sentence (fallback)
            function browserChunk(sentence){
              if(!window.speechSynthesis) return Promise.resolve();
              return new Promise(res=>{
                const utt=new SpeechSynthesisUtterance(sentence);
                utt.lang='de-DE';
                const voices=window.speechSynthesis.getVoices();
                const de=voices.find(v=>v.lang.startsWith('de'));if(de) utt.voice=de;
                utt.rate=(_settingsCache&&_settingsCache['kobold.tts.rate'])?_settingsCache['kobold.tts.rate']/100:1.0;
                utt.volume=(_settingsCache&&_settingsCache['kobold.tts.volume'])?Math.max(0.1,_settingsCache['kobold.tts.volume']/100):1.0;
                let done=false;const fin=()=>{if(!done){done=true;res();}};
                utt.onend=fin;utt.onerror=()=>fin();
                window.speechSynthesis.speak(utt);
                setTimeout(()=>{window.speechSynthesis.cancel();fin();},15000);
              });
            }

            // Audio player — runs concurrently, plays chunks in order
            async function startPlayer(){
              if(playerActive) return;
              playerActive=true;
              setVoiceState('speaking');
              // Mic muten während Playback (verhindert Echo-Cancellation-Interferenz)
              if(_voiceStream) _voiceStream.getAudioTracks().forEach(t=>{t.enabled=false;});
              while(true){
                if(playIdx<audioQueue.length){
                  const item=audioQueue[playIdx];playIdx++;
                  if(_voiceTTSEnabled){
                    const data=await item.promise;
                    if(data) await playChunk(data);
                    else await browserChunk(item.text);
                  }
                } else if(streamEnded){
                  break;
                } else {
                  await new Promise(r=>setTimeout(r,50));
                }
              }
              // Mic wieder aktivieren
              if(_voiceStream) _voiceStream.getAudioTracks().forEach(t=>{t.enabled=true;});
              playerActive=false;
              playerDone();
            }

            // Check for complete phrases in accumulated text (split on . ! ? , ; : for low-latency)
            function flushSentences(){
              const pending=fullText.substring(spokenLen);
              // Erst Satzenden matchen, dann Kommas/Semikolons wenn Phrase lang genug (>20 Zeichen)
              const re=/[^.!?;,:\\n]*[.!?]+[\\s]*|[^,;:\\n]{20,}?[,;:][\\s]*/g;
              let m;
              while((m=re.exec(pending))!==null){
                const phrase=m[0].trim();
                if(phrase.length>3){
                  audioQueue.push({promise:prefetchAudio(phrase),text:phrase});
                  spokenLen+=m[0].length;
                  if(!playerActive) startPlayer();
                }
              }
            }

            // ─── SSE read loop ───
            while(true){
              const{done,value}=await reader.read();
              if(done)break;
              buf+=dec.decode(value,{stream:true});
              const lines=buf.split('\\n');
              buf=lines.pop()||'';
              for(const line of lines){
                if(!line.startsWith('data: '))continue;
                const payload=line.slice(6).trim();
                if(payload==='[DONE]'||payload==='{}')continue;
                try{
                  const ev=JSON.parse(payload);
                  if(ev.type==='finalAnswer'&&ev.content){fullText+=ev.content;}
                }catch(e){}
              }
              flushSentences();
            }

            // Queue remaining text after stream ends
            const remaining=fullText.substring(spokenLen).trim();
            if(remaining&&remaining.length>1){
              audioQueue.push({promise:prefetchAudio(remaining),text:remaining});
              if(!playerActive) startPlayer();
            }
            streamEnded=true;

            // Wait for player to finish (max 60s safety)
            if(playerActive||playIdx<audioQueue.length){
              await Promise.race([playerPromise,new Promise(r=>setTimeout(r,60000))]);
            }

            if(fullText.trim()){
              addVoiceEntry('assistant',fullText.trim());
            } else {
              addVoiceEntry('assistant','(Keine Antwort)');
            }
            // VAD: Recognition neu starten nach Antwort
            if(_voiceInputMethod==='vad'&&_voiceRecognition){
              try{_voiceRecognition.start();}catch(ex){}
              setVoiceState('listening');
            } else {
              setVoiceState('idle');
            }
          }catch(err){
            addVoiceEntry('assistant','Fehler: '+err.message);
            setVoiceState('idle');
          }
        }

        async function speakTTS(text){
          if(!_voiceTTSEnabled){console.log('[TTS] Sprachausgabe deaktiviert');return;}
          if(!text||!text.trim())return;
          setVoiceState('speaking');
          try{
            const ttsWork=(async()=>{
              // 1) ElevenLabs TTS versuchen (Daemon hat API-Key serverseitig)
              const elEnabled=_settingsCache&&_settingsCache['kobold.elevenlabs.enabled'];
              if(elEnabled){
                console.log('[TTS] ElevenLabs...');
                const voiceId=_settingsCache['kobold.elevenlabs.voiceId']||'';
                const modelId=_settingsCache['kobold.elevenlabs.model']||'eleven_multilingual_v2';
                const ah=getAuthHeader();
                const hdrs={'Content-Type':'application/json'};
                if(ah) hdrs['Authorization']=ah;
                try{
                  const resp=await fetch(API+'/tts/elevenlabs/speak',{
                    method:'POST',
                    headers:hdrs,
                    body:JSON.stringify({text,voice_id:voiceId,model_id:modelId})
                  });
                  if(resp.ok){
                    const json=await resp.json();
                    if(json.audio){
                      const binary=atob(json.audio);
                      const bytes=new Uint8Array(binary.length);
                      for(let i=0;i<binary.length;i++) bytes[i]=binary.charCodeAt(i);
                      const blob=new Blob([bytes],{type:json.content_type||'audio/mpeg'});
                      const url=URL.createObjectURL(blob);
                      const audio=new Audio(url);
                      await new Promise((resolve)=>{audio.onended=resolve;audio.onerror=resolve;audio.play().catch(resolve);});
                      URL.revokeObjectURL(url);
                      return;
                    }
                  }
                }catch(ex){console.warn('[TTS] ElevenLabs Fehler:',ex);}
                console.warn('[TTS] ElevenLabs fehlgeschlagen, Fallback...');
              }
              // 2) Fallback: Browser Speech Synthesis
              if(window.speechSynthesis){
                console.log('[TTS] Browser speechSynthesis...');
                window.speechSynthesis.cancel();
                const utt=new SpeechSynthesisUtterance(text);
                utt.lang='de-DE';
                const rate=(_settingsCache&&_settingsCache['kobold.tts.rate'])?_settingsCache['kobold.tts.rate']/100:1.0;
                const vol=(_settingsCache&&_settingsCache['kobold.tts.volume'])?_settingsCache['kobold.tts.volume']/100:1.0;
                utt.rate=rate;utt.volume=Math.max(0.1,vol);
                const voices=window.speechSynthesis.getVoices();
                const deVoice=voices.find(v=>v.lang.startsWith('de'));
                if(deVoice) utt.voice=deVoice;
                await new Promise((resolve)=>{
                  let done=false;const fin=()=>{if(!done){done=true;resolve();}};
                  utt.onend=fin;
                  utt.onerror=function(e){console.warn('[TTS] speechSynthesis Fehler:',e);fin();};
                  window.speechSynthesis.speak(utt);
                  // Chrome-Bug: onend feuert nie bei langem Text → Safety-Timeout
                  setTimeout(()=>{window.speechSynthesis.cancel();fin();},25000);
                });
              } else {
                console.warn('[TTS] Keine TTS-Engine verfügbar');
              }
            })();
            // Gesamt-Timeout: 30s damit "Spricht..." nie ewig hängt
            await Promise.race([ttsWork,new Promise(r=>setTimeout(r,30000))]);
          }catch(e){console.warn('[TTS] Fehler:',e);}
        }

        // ─── Topics ───
        let topics=[];
        const topicColors=['#4ECDC4','#FFD93D','#FF6B6B','#A0E7E5','#B8B8FF','#FFABAB','#95E1D3','#F38181','#888888'];
        let selectedTopicColor=topicColors[0];
        let topicFormOpen=false;

        function loadTopics(){
          api('/topics').then(d=>{
            topics=d.topics||[];
            renderTopics();
          }).catch(()=>{topics=[];renderTopics();});
        }
        function renderTopics(){
          const area=document.getElementById('topicList');
          if(!area)return;
          let html='<div class="new-topic-btn" onclick="toggleTopicForm()"><i data-lucide="folder-plus" style="width:12px;height:12px"></i>Neues Thema</div>';
          html+='<div class="topic-form" id="topicForm">';
          html+='<input class="form-input" id="topicName" placeholder="Themenname" style="margin-bottom:4px;font-size:11px;padding:6px 8px">';
          html+='<div class="topic-colors">';
          topicColors.forEach(c=>{
            html+='<div class="color-dot'+(c===selectedTopicColor?' selected':'')+'" style="background:'+c+'" onclick="selectTopicColor(\\''+c+'\\')"></div>';
          });
          html+='</div>';
          html+='<div style="display:flex;gap:4px"><button class="btn btn-primary btn-sm" style="font-size:10px" onclick="createTopic()">Erstellen</button><button class="btn btn-secondary btn-sm" style="font-size:10px" onclick="toggleTopicForm()">Abbrechen</button></div>';
          html+='</div>';
          // Render topic folders
          topics.forEach(t=>{
            const topicSessions=sessions.filter(s=>(s.topicId||'')===(t.id||''));
            const collapsed=t.isExpanded===false;
            html+='<div class="topic-folder">';
            html+='<div class="topic-header'+(collapsed?' collapsed':'')+'" onclick="toggleTopicExpand(\\''+t.id+'\\')">';
            html+='<div class="topic-dot" style="background:'+t.color+'"></div>';
            html+='<span class="topic-name">'+esc(t.name)+'</span>';
            html+='<span class="topic-count">'+topicSessions.length+'</span>';
            html+='<div class="topic-actions" onclick="event.stopPropagation()">';
            html+='<button onclick="deleteTopic(\\''+t.id+'\\')" title="Löschen"><i data-lucide="x" style="width:10px;height:10px"></i></button>';
            html+='</div>';
            html+='<i data-lucide="chevron-down" class="topic-chevron"></i>';
            html+='</div>';
            html+='<div class="topic-sessions'+(collapsed?' hidden':'')+'">';
            topicSessions.forEach(s=>{
              const active=s.id===activeSessionId?' active':'';
              html+='<div class="session-item'+active+'" onclick="switchSession(\\''+s.id+'\\')">'+
                '<div class="topic-dot" style="background:'+t.color+';width:5px;height:5px"></div>'+
                '<span class="session-name" ondblclick="renameSession(\\''+s.id+'\\',event)">'+esc(s.name||'Neuer Chat')+'</span>'+
                '<button class="session-delete" onclick="deleteSession(\\''+s.id+'\\',event)"><i data-lucide="x" style="width:10px;height:10px"></i></button></div>';
            });
            html+='</div></div>';
          });
          area.innerHTML=html;
          lucide.createIcons();
          updateChatTopicBadge();
        }
        function toggleTopicForm(){
          topicFormOpen=!topicFormOpen;
          const f=document.getElementById('topicForm');
          if(f) f.classList.toggle('open',topicFormOpen);
        }
        function selectTopicColor(c){
          selectedTopicColor=c;
          document.querySelectorAll('.topic-colors .color-dot').forEach(d=>{
            d.classList.toggle('selected',d.style.background===c);
          });
        }
        function createTopic(){
          const name=(document.getElementById('topicName')?.value||'').trim();
          if(!name){showToast('Name erforderlich','error');return;}
          api('/topics',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'create',name,color:selectedTopicColor})})
            .then(()=>{showToast('Thema erstellt','success');topicFormOpen=false;loadTopics();}).catch(()=>showToast('Fehler','error'));
        }
        function deleteTopic(id){
          if(!confirm('Thema wirklich löschen?'))return;
          api('/topics',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'delete',id})})
            .then(()=>{showToast('Gelöscht','success');loadTopics();}).catch(()=>showToast('Fehler','error'));
        }
        function toggleTopicExpand(id){
          const t=topics.find(x=>x.id===id);
          if(!t)return;
          t.isExpanded=!(t.isExpanded!==false);
          api('/topics',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'update',id,isExpanded:t.isExpanded})}).catch(()=>{});
          renderTopics();
        }
        function assignSessionToTopic(sessionId,topicId){
          const s=sessions.find(x=>x.id===sessionId);
          if(s){ s.topicId=topicId; saveSessions(); }
          api('/topics',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'assign',sessionId,topicId})}).catch(()=>{});
          renderTopics(); renderSessions();
        }
        function newSessionInTopic(topicId){
          const t=topics.find(x=>x.id===topicId);
          const name=t?t.name+' — Neuer Chat':'Neuer Chat';
          const id='s_'+Date.now();
          sessions.unshift({id,name,messages:[],createdAt:Date.now(),topicId});
          activeSessionId=id;
          saveSessions(); renderChat(); renderTopics();
        }
        function updateChatTopicBadge(){
          const badge=document.getElementById('chatTopicBadge');
          if(!badge)return;
          const s=sessions.find(x=>x.id===activeSessionId);
          if(s&&s.topicId){
            const t=topics.find(x=>x.id===s.topicId);
            if(t){
              badge.style.display='';
              badge.style.background=t.color+'1a';
              badge.innerHTML='<div class="topic-dot" style="background:'+t.color+'"></div><span style="color:'+t.color+'">'+esc(t.name)+'</span>';
              return;
            }
          }
          badge.style.display='none';
        }

        // ─── Attach File ───
        let pendingAttachments=[];
        function attachFile(){
          const inp=document.createElement('input');
          inp.type='file';
          inp.accept='image/*,.txt,.md,.json,.csv,.log,.py,.js,.swift,.html,.css,.xml,.yaml,.yml';
          inp.multiple=true;
          inp.onchange=()=>{
            Array.from(inp.files).forEach(f=>{
              const reader=new FileReader();
              if(f.type.startsWith('image/')){
                reader.onload=()=>{
                  const b64=reader.result.split(',')[1];
                  pendingAttachments.push({type:'image',name:f.name,data:b64});
                  showAttachmentBadge();
                  showToast(f.name+' angehängt','success');
                };
                reader.readAsDataURL(f);
              } else {
                reader.onload=()=>{
                  pendingAttachments.push({type:'text',name:f.name,data:reader.result});
                  showAttachmentBadge();
                  showToast(f.name+' angehängt','success');
                };
                reader.readAsText(f);
              }
            });
          };
          inp.click();
        }
        function showAttachmentBadge(){
          let badge=document.getElementById('attachBadge');
          if(!badge){
            const row=document.querySelector('.composer-row');
            badge=document.createElement('div');
            badge.id='attachBadge';
            badge.style.cssText='position:absolute;top:-24px;left:20px;display:flex;gap:6px;flex-wrap:wrap';
            row.parentElement.style.position='relative';
            row.parentElement.insertBefore(badge,row);
          }
          badge.innerHTML=pendingAttachments.map((a,i)=>
            '<span style="background:var(--fill);color:var(--text-secondary);font-size:10px;padding:2px 8px;border-radius:8px;display:flex;align-items:center;gap:4px">'+
            (a.type==='image'?'🖼':'📄')+' '+esc(a.name)+
            '<span onclick="pendingAttachments.splice('+i+',1);showAttachmentBadge()" style="cursor:pointer;margin-left:2px">×</span></span>'
          ).join('');
          if(!pendingAttachments.length && badge) badge.innerHTML='';
        }

        // ─── Toast ───
        function showToast(msg,type){
          let container=document.querySelector('.toast-container');
          if(!container){container=document.createElement('div');container.className='toast-container';document.body.appendChild(container)}
          const t=document.createElement('div');
          t.className='toast '+(type||'');
          t.textContent=msg;
          container.appendChild(t);
          setTimeout(()=>t.remove(),3000);
        }
        </script>
        </body>
        </html>
        """
    }
}
