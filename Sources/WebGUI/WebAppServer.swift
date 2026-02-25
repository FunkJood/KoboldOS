import Foundation
import Network

// MARK: - WebAppServer — Local HTTP server serving a full mirror of the native UI

final class WebAppServer: @unchecked Sendable {
    static let shared = WebAppServer()

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

    func start(port: Int, daemonPort: Int, daemonToken: String, username: String, password: String) {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        let cfg = WebAppConfig(port: port, daemonPort: daemonPort, daemonToken: daemonToken, username: username, password: password)
        config = cfg
        lock.unlock()

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
    static func installCloudflared(completion: @escaping (Bool) -> Void) {
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

    /// Start Cloudflare quick tunnel (no account needed)
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
            proc.arguments = ["tunnel", "--url", "http://localhost:\(localPort)", "--no-autoupdate"]

            let errPipe = Pipe()
            proc.standardError = errPipe  // cloudflared outputs URL to stderr

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
                    // cloudflared outputs: "... https://xxxxx.trycloudflare.com ..."
                    if let range = output.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                        let url = String(output[range])
                        self?.lock.lock()
                        self?._tunnelURL = url
                        self?.lock.unlock()
                        // Post notification for UI update
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                conn.cancel()
                return
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            self.processRequest(raw: raw, conn: conn, config: config)
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

        // Basic Auth check
        let auth = headers["authorization"] ?? ""
        if auth != config.basicAuthExpected {
            let body = "<!DOCTYPE html><html><body style='background:#0d1117;color:#e6edf3;font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh'><div style='text-align:center'><h1>401</h1><p>Zugriff verweigert</p></div></body></html>"
            let resp = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"KoboldOS\"\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        if path == "/" || path == "/index.html" {
            serveHTML(conn: conn)
        } else if path.hasPrefix("/api/") {
            proxyToDaemon(method: method, path: String(path.dropFirst(4)), headers: headers, raw: raw, conn: conn, config: config)
        } else {
            let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
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
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 1800

        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty {
                req.httpBody = bodyStr.data(using: .utf8)
            }
        }

        URLSession.shared.dataTask(with: req) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            let body = data ?? Data()
            let resp = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var fullResp = resp.data(using: .utf8)!
            fullResp.append(body)
            conn.send(content: fullResp, completion: .contentProcessed { _ in conn.cancel() })
        }.resume()
    }

    // MARK: - Serve HTML

    private func serveHTML(conn: NWConnection) {
        let html = Self.buildHTML()
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Full HTML Template (Apple-inspired redesign)

    private static func buildHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <title>KoboldOS</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
        <script src="https://unpkg.com/lucide@latest"></script>
        <style>
        :root {
          --bg: #000000;
          --bg-primary: #1c1c1e;
          --bg-secondary: #2c2c2e;
          --bg-tertiary: #3a3a3c;
          --bg-elevated: rgba(44,44,46,0.72);
          --fill: rgba(120,120,128,0.2);
          --fill-secondary: rgba(120,120,128,0.16);
          --separator: rgba(84,84,88,0.65);
          --text: #ffffff;
          --text-secondary: rgba(235,235,245,0.6);
          --text-tertiary: rgba(235,235,245,0.3);
          --accent: #0a84ff;
          --accent-secondary: #5e5ce6;
          --green: #30d158;
          --orange: #ff9f0a;
          --red: #ff453a;
          --teal: #64d2ff;
          --pink: #ff375f;
          --purple: #bf5af2;
          --radius: 12px;
          --radius-lg: 16px;
          --shadow: 0 2px 20px rgba(0,0,0,0.3);
          --transition: all 0.2s cubic-bezier(0.25,0.1,0.25,1);
        }
        * { margin:0; padding:0; box-sizing:border-box; }
        body {
          font-family: 'Inter',-apple-system,BlinkMacSystemFont,'SF Pro Display',system-ui,sans-serif;
          background: var(--bg);
          color: var(--text);
          height: 100vh; height: 100dvh;
          display: flex;
          overflow: hidden;
          -webkit-font-smoothing: antialiased;
        }

        /* ─── Sidebar ─── */
        .sidebar {
          width: 260px; flex-shrink: 0;
          background: var(--bg-primary);
          display: flex; flex-direction: column;
          border-right: 0.5px solid var(--separator);
        }
        .sidebar-brand {
          padding: 20px 20px 16px;
          display: flex; align-items: center; gap: 12px;
        }
        .sidebar-brand .logo {
          width: 36px; height: 36px;
          background: linear-gradient(135deg, var(--accent), var(--accent-secondary));
          border-radius: 10px;
          display: flex; align-items: center; justify-content: center;
          font-size: 18px; font-weight: 700; color: #fff;
        }
        .sidebar-brand h1 { font-size: 17px; font-weight: 700; letter-spacing: -0.3px; }
        .sidebar-brand .status {
          margin-left: auto;
          width: 8px; height: 8px; border-radius: 50%;
          background: var(--green);
          box-shadow: 0 0 6px var(--green);
        }
        .sidebar-brand .status.offline { background: var(--red); box-shadow: 0 0 6px var(--red); }
        .nav { flex: 1; padding: 0 12px; overflow-y: auto; }
        .nav-section { font-size: 11px; font-weight: 600; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: 0.5px; padding: 16px 8px 6px; }
        .nav-item {
          display: flex; align-items: center; gap: 10px;
          padding: 9px 12px; border-radius: 8px;
          color: var(--text-secondary); font-size: 13px; font-weight: 500;
          cursor: pointer; transition: var(--transition);
          margin-bottom: 2px;
        }
        .nav-item:hover { background: var(--fill); color: var(--text); }
        .nav-item.active { background: var(--accent); color: #fff; }
        .nav-item.active i { color: #fff; }
        .nav-item i { width: 18px; height: 18px; stroke-width: 1.8; color: var(--text-tertiary); }
        .nav-item.active:hover { background: var(--accent); }
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
        .page-header h2 { font-size: 20px; font-weight: 700; letter-spacing: -0.4px; }
        .page-header .subtitle { font-size: 12px; color: var(--text-secondary); }
        .page-body { flex: 1; overflow-y: auto; padding: 20px 24px 24px; }
        .tab { display: none; height: 100%; flex-direction: column; }
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
        .glass-title { font-size: 13px; font-weight: 600; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
        .glass-title i { width: 16px; height: 16px; color: var(--accent); }

        /* ─── Chat ─── */
        .chat-container { flex: 1; display: flex; flex-direction: column; height: 100%; }
        .chat-messages {
          flex: 1; overflow-y: auto; padding: 16px 24px;
          display: flex; flex-direction: column; gap: 12px;
          scroll-behavior: smooth;
        }
        .chat-messages::-webkit-scrollbar { width: 6px; }
        .chat-messages::-webkit-scrollbar-thumb { background: var(--fill); border-radius: 3px; }
        .chat-welcome {
          flex: 1; display: flex; flex-direction: column;
          align-items: center; justify-content: center; gap: 12px;
          color: var(--text-tertiary);
        }
        .chat-welcome .welcome-icon {
          width: 56px; height: 56px; border-radius: 16px;
          background: linear-gradient(135deg, var(--accent), var(--accent-secondary));
          display: flex; align-items: center; justify-content: center;
        }
        .chat-welcome .welcome-icon i { width: 28px; height: 28px; color: #fff; }
        .chat-welcome h3 { font-size: 17px; font-weight: 600; color: var(--text); }
        .chat-welcome p { font-size: 13px; max-width: 280px; text-align: center; line-height: 1.5; }
        .bubble {
          max-width: 72%; padding: 12px 16px;
          border-radius: 18px; font-size: 14px; line-height: 1.55;
          word-break: break-word; white-space: pre-wrap;
          animation: fadeIn 0.25s ease;
        }
        @keyframes fadeIn { from { opacity:0; transform:translateY(6px); } to { opacity:1; transform:translateY(0); } }
        .bubble.user {
          background: var(--accent); color: #fff;
          align-self: flex-end;
          border-bottom-right-radius: 6px;
        }
        .bubble.bot {
          background: var(--bg-secondary);
          border: 0.5px solid var(--separator);
          align-self: flex-start;
          border-bottom-left-radius: 6px;
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
        .tool-tag {
          display: inline-flex; align-items: center; gap: 4px;
          font-size: 11px; padding: 3px 8px; border-radius: 6px;
          background: var(--fill); color: var(--text-secondary);
          margin: 2px 2px 0 0;
        }
        .tool-tag.ok { color: var(--green); }
        .tool-tag.fail { color: var(--red); }
        .chat-composer {
          padding: 12px 20px 16px;
          background: rgba(28,28,30,0.9);
          backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
          border-top: 0.5px solid var(--separator);
        }
        .composer-row { display: flex; gap: 10px; align-items: flex-end; }
        .composer-input {
          flex: 1; background: var(--bg-secondary);
          border: 0.5px solid var(--separator);
          color: var(--text); padding: 12px 16px;
          border-radius: 22px; font-size: 14px; font-family: inherit;
          outline: none; resize: none; min-height: 44px; max-height: 120px;
          transition: var(--transition);
        }
        .composer-input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(10,132,255,0.15); }
        .composer-input::placeholder { color: var(--text-tertiary); }
        .send-btn {
          width: 44px; height: 44px; border-radius: 50%;
          background: var(--accent); border: none;
          display: flex; align-items: center; justify-content: center;
          cursor: pointer; transition: var(--transition);
          flex-shrink: 0;
        }
        .send-btn:hover { filter: brightness(1.1); transform: scale(1.05); }
        .send-btn:disabled { opacity: 0.3; transform: none; cursor: default; }
        .send-btn i { width: 20px; height: 20px; color: #fff; }
        .typing-dots { display: flex; gap: 4px; padding: 4px 0; }
        .typing-dots span {
          width: 7px; height: 7px; border-radius: 50%; background: var(--text-tertiary);
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
        .stat-card .label { font-size: 11px; color: var(--text-tertiary); font-weight: 500; text-transform: uppercase; letter-spacing: 0.3px; }
        .stat-card .value { font-size: 28px; font-weight: 700; margin-top: 4px; letter-spacing: -0.5px; }
        .stat-card .value.accent { color: var(--accent); }
        .stat-card .value.green { color: var(--green); }
        .stat-card .value.orange { color: var(--orange); }
        .stat-card .value.red { color: var(--red); }

        /* ─── Memory ─── */
        .search-bar {
          display: flex; gap: 10px; margin-bottom: 16px;
        }
        .search-field {
          flex: 1; background: var(--bg-secondary);
          border: 0.5px solid var(--separator);
          color: var(--text); padding: 10px 14px 10px 36px;
          border-radius: 10px; font-size: 13px; font-family: inherit;
          outline: none; transition: var(--transition);
        }
        .search-field:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(10,132,255,0.1); }
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
        .pill.active { background: var(--accent); color: #fff; border-color: var(--accent); }
        .pill.active:hover { background: var(--accent); }
        .tag-row { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 14px; }
        .tag-pill {
          font-size: 11px; padding: 3px 10px; border-radius: 20px;
          background: var(--fill); color: var(--text-secondary);
          cursor: pointer; transition: var(--transition);
        }
        .tag-pill:hover { background: var(--fill-secondary); color: var(--text); }
        .tag-pill.active { background: rgba(10,132,255,0.2); color: var(--accent); }
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
        .mem-badge.langzeit { background: rgba(10,132,255,0.12); color: var(--accent); }
        .mem-badge.wissen { background: rgba(255,159,10,0.12); color: var(--orange); }
        .mem-card .mem-text { font-size: 13px; line-height: 1.55; color: var(--text-secondary); }
        .mem-card .mem-date { font-size: 10px; color: var(--text-tertiary); margin-top: 8px; }
        .mem-card .mem-tag { font-size: 10px; padding: 2px 7px; border-radius: 6px; background: var(--fill); color: var(--text-tertiary); }
        .mem-card .mem-delete {
          margin-left: auto; background: none; border: none;
          color: var(--text-tertiary); cursor: pointer; padding: 4px;
          border-radius: 6px; transition: var(--transition);
        }
        .mem-card .mem-delete:hover { color: var(--red); background: rgba(255,69,58,0.1); }
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
        .task-name { font-size: 14px; font-weight: 600; flex: 1; }
        .task-cron { font-size: 11px; font-family: 'SF Mono',monospace; color: var(--orange); background: rgba(255,159,10,0.1); padding: 2px 8px; border-radius: 6px; }
        .task-status {
          font-size: 10px; font-weight: 600; padding: 3px 10px;
          border-radius: 20px;
        }
        .task-status.on { background: rgba(48,209,88,0.12); color: var(--green); }
        .task-status.off { background: rgba(255,69,58,0.1); color: var(--red); }
        .task-prompt { font-size: 12px; color: var(--text-secondary); margin-top: 8px; line-height: 1.5; }
        .task-actions { display: flex; gap: 6px; margin-top: 10px; }
        .add-task-form {
          display: none; background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 14px; margin-bottom: 14px;
        }
        .add-task-form.show { display: block; }
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
        .settings-label { font-size: 14px; }
        .settings-value { font-size: 13px; color: var(--text-secondary); }
        .model-card {
          background: var(--bg-secondary); border: 0.5px solid var(--separator);
          border-radius: var(--radius); padding: 12px 14px;
          margin-bottom: 6px; cursor: pointer; transition: var(--transition);
          display: flex; align-items: center; gap: 10px;
        }
        .model-card:hover { border-color: rgba(120,120,128,0.4); }
        .model-card.selected { border-color: var(--accent); background: rgba(10,132,255,0.08); }
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
        .btn-primary { background: var(--accent); color: #fff; }
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
          .sidebar {
            position: fixed; bottom: 0; left: 0; right: 0;
            width: 100%; height: 60px; flex-direction: row;
            border-right: none; border-top: 0.5px solid var(--separator);
            z-index: 100;
            background: rgba(28,28,30,0.95);
            backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
          }
          .sidebar-brand, .nav-section, .sidebar-footer { display: none; }
          .nav { display: flex; flex-direction: row; padding: 0; overflow-x: auto; }
          .nav-item { flex: 1; justify-content: center; padding: 10px; border-radius: 0; flex-direction: column; gap: 3px; margin: 0; }
          .nav-item span { display: block !important; font-size: 9px !important; text-align: center; }
          .main { margin-bottom: 60px; }
          .bubble { max-width: 95%; }
        }
        </style>
        </head>
        <body>
        <div class="sidebar">
          <div class="sidebar-brand">
            <div class="logo">K</div>
            <h1>KoboldOS</h1>
            <div class="status" id="statusDot"></div>
          </div>
          <div class="nav">
            <div class="nav-section">Navigation</div>
            <div class="nav-item active" onclick="switchTab('chat',this)"><i data-lucide="message-circle"></i><span>Chat</span></div>
            <div class="nav-item" onclick="switchTab('tasks',this)"><i data-lucide="list-checks"></i><span>Aufgaben</span></div>
            <div class="nav-item" onclick="switchTab('memory',this)"><i data-lucide="brain"></i><span>Gedächtnis</span></div>
            <div class="nav-item" onclick="switchTab('settings',this)"><i data-lucide="settings"></i><span>Einstellungen</span></div>
          </div>
          <div class="sidebar-footer" id="versionFooter">KoboldOS</div>
        </div>

        <div class="main">
          <!-- Chat -->
          <div class="tab active" id="tab-chat">
            <div class="chat-container">
              <div class="page-header">
                <h2>Chat</h2>
                <div class="subtitle" id="chatStatus">Bereit</div>
                <div style="flex:1"></div>
                <button class="btn btn-secondary btn-sm" onclick="clearChat()"><i data-lucide="trash-2"></i>Leeren</button>
              </div>
              <div class="chat-messages" id="chatArea">
                <div class="chat-welcome" id="chatWelcome">
                  <div class="welcome-icon"><i data-lucide="sparkles"></i></div>
                  <h3>Hallo!</h3>
                  <p>Stelle eine Frage oder gib einen Auftrag — dein KoboldOS Agent antwortet in Echtzeit.</p>
                </div>
              </div>
              <div class="chat-composer">
                <div class="composer-row">
                  <textarea class="composer-input" id="msgInput" placeholder="Nachricht eingeben..." rows="1"
                    onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();sendMsg()}"
                    oninput="this.style.height='auto';this.style.height=Math.min(this.scrollHeight,120)+'px'"></textarea>
                  <button class="send-btn" id="sendBtn" onclick="sendMsg()"><i data-lucide="arrow-up"></i></button>
                </div>
              </div>
            </div>
          </div>

          <!-- Tasks -->
          <div class="tab" id="tab-tasks">
            <div class="page-header">
              <h2>Aufgaben</h2>
              <div style="flex:1"></div>
              <button class="btn btn-primary btn-sm" onclick="toggleTaskForm()"><i data-lucide="plus"></i>Neue Aufgabe</button>
            </div>
            <div class="page-body">
              <div class="add-task-form" id="taskForm">
                <input class="form-input" id="taskName" placeholder="Aufgabenname">
                <textarea class="form-input" id="taskPrompt" placeholder="Prompt / Anweisung" style="resize:vertical;min-height:60px"></textarea>
                <div class="form-row">
                  <input class="form-input" id="taskSchedule" placeholder="Cron (z.B. */5 * * * *)" style="flex:1;margin:0">
                  <button class="btn btn-primary" onclick="createTask()">Erstellen</button>
                  <button class="btn btn-secondary" onclick="toggleTaskForm()">Abbrechen</button>
                </div>
              </div>
              <div id="tasksArea"></div>
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
                  <select class="form-select" id="memType"><option value="kurzzeit">Kurzzeit</option><option value="langzeit">Langzeit</option><option value="wissen">Wissen</option></select>
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
              </div>
              <div class="tag-row" id="memTagBar"></div>
              <div id="memEntries"></div>
            </div>
          </div>

          <!-- Settings -->
          <div class="tab" id="tab-settings">
            <div class="page-header"><h2>Einstellungen</h2></div>
            <div class="page-body">
              <div class="settings-section">
                <h3>System</h3>
                <div class="glass">
                  <div class="stats-grid" id="settingsMetrics"></div>
                </div>
              </div>
              <div class="settings-section">
                <h3>Modell</h3>
                <div id="modelList"></div>
              </div>
              <div class="settings-section">
                <h3>Daemon</h3>
                <div class="glass" id="daemonInfo">
                  <div style="color:var(--text-secondary);font-size:13px">Lade...</div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <script>
        const API='/api';
        let currentTab='chat', memoryEntries=[], memoryTags={}, filterType=null, filterTag=null, isSending=false;

        // ─── Init ───
        document.addEventListener('DOMContentLoaded', () => {
          lucide.createIcons();
          checkHealth();
          setInterval(checkHealth, 6000);
        });

        // ─── Tab Switch ───
        function switchTab(name,el) {
          document.querySelectorAll('.tab').forEach(t=>{t.style.display='none';t.classList.remove('active')});
          document.querySelectorAll('.nav-item').forEach(n=>n.classList.remove('active'));
          const tab=document.getElementById('tab-'+name);
          if(tab){tab.style.display='flex';tab.classList.add('active')}
          if(el) el.classList.add('active');
          currentTab=name;
          if(name==='tasks') loadTasks();
          if(name==='memory') loadMemory();
          if(name==='settings') loadSettings();
          lucide.createIcons();
        }

        async function api(path,opts={}){
          const r=await fetch(API+path,{credentials:'same-origin',headers:{'Content-Type':'application/json'},...opts});
          if(!r.ok){
            const text=await r.text().catch(()=>'');
            throw new Error('HTTP '+r.status+(text?' — '+text:''));
          }
          return r.json();
        }
        function esc(s){const d=document.createElement('div');d.textContent=s||'';return d.innerHTML}
        function fmt(text){
          let s=esc(text);
          s=s.replace(/```([\\s\\S]*?)```/g,'<pre>$1</pre>');
          s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
          s=s.replace(/\\*\\*(.+?)\\*\\*/g,'<strong>$1</strong>');
          s=s.replace(/\\n/g,'<br>');
          return s;
        }

        // ─── Health ───
        async function checkHealth(){
          try{
            const d=await api('/health');
            document.getElementById('statusDot').className='status';
            document.getElementById('versionFooter').textContent='KoboldOS '+((d.version)||'');
          }catch{
            document.getElementById('statusDot').className='status offline';
          }
        }

        // ─── Chat ───
        async function sendMsg(){
          if(isSending)return;
          const input=document.getElementById('msgInput');
          const msg=input.value.trim();
          if(!msg)return;
          input.value='';input.style.height='auto';
          isSending=true;
          document.getElementById('sendBtn').disabled=true;
          document.getElementById('chatStatus').textContent='Denkt nach...';

          const area=document.getElementById('chatArea');
          const welcome=document.getElementById('chatWelcome');
          if(welcome) welcome.remove();

          area.innerHTML+='<div class="bubble user">'+esc(msg)+'</div>';
          const tid='t_'+Date.now();
          area.innerHTML+='<div class="bubble thinking" id="'+tid+'"><div class="typing-dots"><span></span><span></span><span></span></div>Denkt nach...</div>';
          area.scrollTop=area.scrollHeight;
          lucide.createIcons();

          // Timer to show elapsed time while waiting
          let elapsed=0;
          const timer=setInterval(()=>{
            elapsed++;
            const el=document.getElementById(tid);
            if(el) el.innerHTML='<div class="typing-dots"><span></span><span></span><span></span></div>Denkt nach... ('+elapsed+'s)';
          },1000);

          try{
            const ctrl=new AbortController();
            const timeout=setTimeout(()=>ctrl.abort(),1800000); // 30min max
            const data=await api('/agent',{method:'POST',body:JSON.stringify({message:msg}),signal:ctrl.signal});
            clearTimeout(timeout);
            const el=document.getElementById(tid);
            const answer=data.output||data.error||'Keine Antwort';
            let tools='';
            if(data.tool_results&&data.tool_results.length>0){
              tools='<div style="margin-top:8px;display:flex;flex-wrap:wrap;gap:4px">'+
                data.tool_results.map(t=>'<span class="tool-tag '+(t.success?'ok':'fail')+'">'+
                (t.success?'\\u2713':'\\u2717')+' '+esc(t.name)+'</span>').join('')+'</div>';
            }
            if(el) el.outerHTML='<div class="bubble bot">'+fmt(answer)+tools+'</div>';
          }catch(e){
            const el=document.getElementById(tid);
            if(el) el.outerHTML='<div class="bubble bot error">Fehler: '+esc(e.message)+'</div>';
          }
          clearInterval(timer);
          area.scrollTop=area.scrollHeight;
          isSending=false;
          document.getElementById('sendBtn').disabled=false;
          document.getElementById('chatStatus').textContent='Bereit';
          input.focus();
          lucide.createIcons();
        }

        function clearChat(){
          const area=document.getElementById('chatArea');
          area.innerHTML='<div class="chat-welcome" id="chatWelcome"><div class="welcome-icon"><i data-lucide="sparkles"></i></div><h3>Hallo!</h3><p>Stelle eine Frage oder gib einen Auftrag.</p></div>';
          api('/history/clear',{method:'POST'}).catch(()=>{});
          lucide.createIcons();
        }

        // ─── Tasks ───
        async function loadTasks(){
          try{
            const data=await api('/tasks');
            const tasks=data.tasks||[];
            const area=document.getElementById('tasksArea');
            if(!tasks.length){area.innerHTML='<div class="empty-state"><i data-lucide="list-checks"></i><p>Keine Aufgaben vorhanden</p></div>';lucide.createIcons();return}
            area.innerHTML=tasks.map(t=>{
              const on=t.enabled!==false;
              return '<div class="task-item"><div class="task-row">'+
                '<span class="task-name">'+esc(t.name)+'</span>'+
                (t.schedule?'<span class="task-cron">'+esc(t.schedule)+'</span>':'')+
                '<span class="task-status '+(on?'on':'off')+'">'+(on?'Aktiv':'Pausiert')+'</span>'+
                '</div>'+(t.prompt?'<div class="task-prompt">'+esc(t.prompt)+'</div>':'')+
                '<div class="task-actions">'+
                '<button class="btn btn-secondary btn-sm" onclick="toggleTask(\\''+t.id+'\\','+(!on)+')"><i data-lucide="'+(on?'pause':'play')+'"></i>'+(on?'Pausieren':'Aktivieren')+'</button>'+
                '<button class="btn btn-danger btn-sm" onclick="deleteTask(\\''+t.id+'\\')"><i data-lucide="trash-2"></i></button>'+
                '</div></div>';
            }).join('');
            lucide.createIcons();
          }catch(e){
            document.getElementById('tasksArea').innerHTML='<div class="empty-state"><i data-lucide="alert-circle"></i><p>Fehler beim Laden</p></div>';
            lucide.createIcons();
          }
        }

        function toggleTaskForm(){document.getElementById('taskForm').classList.toggle('show')}

        async function createTask(){
          const name=document.getElementById('taskName').value.trim();
          const prompt=document.getElementById('taskPrompt').value.trim();
          const schedule=document.getElementById('taskSchedule').value.trim();
          if(!name||!prompt)return;
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'create',name,prompt,schedule:schedule||'0 * * * *',enabled:true})});
          document.getElementById('taskName').value='';document.getElementById('taskPrompt').value='';document.getElementById('taskSchedule').value='';
          toggleTaskForm();loadTasks();
        }

        async function toggleTask(id,enabled){
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'update',id,enabled})});
          loadTasks();
        }

        async function deleteTask(id){
          if(!confirm('Aufgabe wirklich löschen?'))return;
          await api('/tasks',{method:'POST',body:JSON.stringify({action:'delete',id})});
          loadTasks();
        }

        // ─── Memory ───
        async function loadMemory(){
          try{
            const data=await api('/memory/entries');
            memoryEntries=data.entries||[];
            memoryTags={};
            memoryEntries.forEach(e=>(e.tags||[]).forEach(t=>{memoryTags[t]=(memoryTags[t]||0)+1}));
            const byType={kurzzeit:0,langzeit:0,wissen:0};
            memoryEntries.forEach(e=>{const t=e.memoryType||e.type||'kurzzeit';byType[t]=(byType[t]||0)+1});
            document.getElementById('memStats').innerHTML=
              '<div class="mem-stat"><div class="num" style="color:var(--teal)">'+byType.kurzzeit+'</div><div class="lbl">Kurzzeit</div></div>'+
              '<div class="mem-stat"><div class="num" style="color:var(--accent)">'+byType.langzeit+'</div><div class="lbl">Langzeit</div></div>'+
              '<div class="mem-stat"><div class="num" style="color:var(--orange)">'+byType.wissen+'</div><div class="lbl">Wissen</div></div>'+
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
            const tl=tc==='langzeit'?'Langzeit':tc==='wissen'?'Wissen':'Kurzzeit';
            const dt=e.timestamp?new Date(e.timestamp).toLocaleDateString('de-DE',{day:'2-digit',month:'2-digit',year:'2-digit',hour:'2-digit',minute:'2-digit'}):'';
            return '<div class="mem-card"><div class="mem-header">'+
              '<span class="mem-badge '+tc+'">'+tl+'</span> '+tags+
              '<button class="mem-delete" onclick="deleteMem(\\''+e.id+'\\')"><i data-lucide="x" style="width:14px;height:14px"></i></button>'+
              '</div><div class="mem-text">'+esc(e.text)+'</div><div class="mem-date">'+dt+'</div></div>';
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

        async function deleteMem(id){
          await api('/memory/entries',{method:'DELETE',body:JSON.stringify({id})});
          loadMemory();
        }

        // ─── Settings ───
        async function loadSettings(){
          try{
            const[metrics,health,models]=await Promise.all([api('/metrics'),api('/health'),api('/models')]);
            document.getElementById('settingsMetrics').innerHTML=
              statCard('Anfragen',metrics.chat_requests||0,'accent')+
              statCard('Tool-Aufrufe',metrics.tool_calls||0,'green')+
              statCard('Tokens',metrics.tokens_total||0,'orange')+
              statCard('Fehler',metrics.errors||0,'red')+
              statCard('Uptime',Math.round((metrics.uptime||0)/60)+' min','accent')+
              statCard('Latenz',Math.round(metrics.avg_latency_ms||0)+' ms','green');

            document.getElementById('daemonInfo').innerHTML=
              '<div class="settings-row"><span class="settings-label">Version</span><span class="settings-value">'+(health.version||'?')+'</span></div>'+
              '<div class="settings-row"><span class="settings-label">PID</span><span class="settings-value">'+(health.pid||'?')+'</span></div>'+
              '<div class="settings-row"><span class="settings-label">Status</span><span class="settings-value" style="color:var(--green)">Online</span></div>'+
              '<div class="settings-row"><span class="settings-label">Modell</span><span class="settings-value">'+(metrics.model||'?')+'</span></div>';

            const modelList=document.getElementById('modelList');
            const available=models.models||[];
            const active=models.active||'';
            if(available.length){
              modelList.innerHTML=available.map(m=>{
                const name=m.name||m;
                const sel=name===active;
                return '<div class="model-card'+(sel?' selected':'')+'" onclick="setModel(\\''+esc(name)+'\\')">'+
                  '<div class="model-radio"></div>'+
                  '<span class="model-name">'+esc(name)+'</span>'+
                  (m.size?'<span class="model-size">'+m.size+'</span>':'')+
                  '</div>';
              }).join('');
            } else {
              modelList.innerHTML='<div class="glass" style="color:var(--text-secondary);font-size:13px">Keine Modelle verfügbar — ist Ollama aktiv?</div>';
            }
          }catch(e){
            document.getElementById('settingsMetrics').innerHTML='<div style="color:var(--red);font-size:13px;grid-column:1/-1">Daemon nicht erreichbar</div>';
            document.getElementById('daemonInfo').innerHTML='<div style="color:var(--red);font-size:13px">Offline</div>';
          }
        }

        function statCard(label,val,color){
          return '<div class="stat-card"><div class="label">'+label+'</div><div class="value '+color+'">'+val+'</div></div>';
        }

        async function setModel(name){
          await api('/model/set',{method:'POST',body:JSON.stringify({model:name})});
          loadSettings();
        }
        </script>
        </body>
        </html>
        """
    }
}
