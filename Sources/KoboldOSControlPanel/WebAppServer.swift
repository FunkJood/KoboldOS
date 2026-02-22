import Foundation
import Network

// MARK: - WebAppServer — Local HTTP server serving a remote control web UI

final class WebAppServer: @unchecked Sendable {
    static let shared = WebAppServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _isRunning = false
    private var config: WebAppConfig?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
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
        // Parse HTTP request
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers
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
            let body = "<!DOCTYPE html><html><body><h1>401 — Zugriff verweigert</h1></body></html>"
            let resp = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"KoboldOS\"\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        // Route
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
        guard let url = URL(string: "http://localhost:\(config.daemonPort)\(path)") else {
            conn.cancel(); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.daemonToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        // Extract body from raw request
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

    // MARK: - HTML Template

    private static func buildHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="de">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>KoboldOS — Fernsteuerung</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', sans-serif;
                    background: #0d1117; color: #e6edf3;
                    min-height: 100vh; display: flex; flex-direction: column;
                }
                .header {
                    background: rgba(22, 27, 34, 0.95); border-bottom: 1px solid #30363d;
                    padding: 12px 20px; display: flex; align-items: center; gap: 12px;
                }
                .header h1 { font-size: 16px; font-weight: 600; }
                .header .status { font-size: 11px; padding: 3px 8px; border-radius: 12px; background: #238636; }
                .header .status.offline { background: #da3633; }
                .nav { display: flex; gap: 4px; margin-left: auto; }
                .nav button {
                    background: transparent; border: 1px solid #30363d; color: #8b949e;
                    padding: 6px 14px; border-radius: 6px; cursor: pointer; font-size: 12px;
                }
                .nav button.active { background: #238636; color: white; border-color: #238636; }
                .main { flex: 1; display: flex; flex-direction: column; padding: 16px; gap: 12px; max-width: 900px; margin: 0 auto; width: 100%; }
                .card {
                    background: rgba(22, 27, 34, 0.8); border: 1px solid #30363d;
                    border-radius: 10px; padding: 16px;
                }
                .card h3 { font-size: 13px; margin-bottom: 8px; color: #58a6ff; }
                .chat-messages { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; }
                .msg { padding: 8px 12px; border-radius: 8px; font-size: 13px; max-width: 80%; word-wrap: break-word; white-space: pre-wrap; }
                .msg.user { background: #238636; align-self: flex-end; }
                .msg.assistant { background: #30363d; align-self: flex-start; }
                .input-bar {
                    display: flex; gap: 8px; padding: 12px;
                    background: rgba(22, 27, 34, 0.95); border-top: 1px solid #30363d;
                }
                .input-bar input {
                    flex: 1; background: #0d1117; border: 1px solid #30363d; color: #e6edf3;
                    padding: 10px 14px; border-radius: 8px; font-size: 14px; outline: none;
                }
                .input-bar input:focus { border-color: #238636; }
                .input-bar button {
                    background: #238636; border: none; color: white; padding: 10px 20px;
                    border-radius: 8px; cursor: pointer; font-weight: 600; font-size: 13px;
                }
                .input-bar button:hover { background: #2ea043; }
                .metric { display: inline-block; margin: 4px 8px 4px 0; padding: 6px 10px; background: #161b22; border-radius: 6px; font-size: 11px; }
                .metric .val { font-weight: 700; color: #58a6ff; }
                .memory-block { margin: 6px 0; padding: 8px; background: #161b22; border-radius: 6px; font-size: 12px; }
                .memory-block .label { color: #f0883e; font-weight: 600; }
                .loading { text-align: center; padding: 40px; color: #8b949e; }
            </style>
        </head>
        <body>
            <div class="header">
                <span style="font-size: 20px;">&#x1F409;</span>
                <h1>KoboldOS</h1>
                <span class="status" id="statusBadge">Verbunden</span>
                <div class="nav">
                    <button class="active" onclick="showTab('chat')">Chat</button>
                    <button onclick="showTab('dashboard')">Dashboard</button>
                    <button onclick="showTab('memory')">Ged\\u00e4chtnis</button>
                    <button onclick="showTab('tasks')">Aufgaben</button>
                </div>
            </div>

            <div class="main" id="tab-chat">
                <div class="chat-messages" id="chatMessages">
                    <div class="loading">Sende eine Nachricht um zu starten...</div>
                </div>
            </div>
            <div class="input-bar" id="chatInput">
                <input type="text" id="msgInput" placeholder="Nachricht eingeben..." onkeydown="if(event.key==='Enter')sendMsg()">
                <button onclick="sendMsg()">Senden</button>
            </div>

            <div class="main" id="tab-dashboard" style="display:none">
                <div class="card">
                    <h3>Metriken</h3>
                    <div id="metricsArea"><div class="loading">Lade...</div></div>
                </div>
            </div>

            <div class="main" id="tab-memory" style="display:none">
                <div class="card">
                    <h3>Ged\\u00e4chtnisbl\\u00f6cke</h3>
                    <div id="memoryArea"><div class="loading">Lade...</div></div>
                </div>
            </div>

            <div class="main" id="tab-tasks" style="display:none">
                <div class="card">
                    <h3>Geplante Aufgaben</h3>
                    <div id="tasksArea"><div class="loading">Lade...</div></div>
                </div>
            </div>

            <script>
                const API = '/api';
                let currentTab = 'chat';

                function showTab(name) {
                    document.querySelectorAll('.main').forEach(el => el.style.display = 'none');
                    document.querySelectorAll('.nav button').forEach(b => b.classList.remove('active'));
                    document.getElementById('tab-' + name).style.display = 'flex';
                    document.getElementById('chatInput').style.display = name === 'chat' ? 'flex' : 'none';
                    event.target.classList.add('active');
                    currentTab = name;
                    if (name === 'dashboard') loadDashboard();
                    if (name === 'memory') loadMemory();
                    if (name === 'tasks') loadTasks();
                }

                async function api(path, opts = {}) {
                    const resp = await fetch(API + path, {
                        headers: { 'Content-Type': 'application/json' },
                        ...opts
                    });
                    return resp.json();
                }

                async function sendMsg() {
                    const input = document.getElementById('msgInput');
                    const msg = input.value.trim();
                    if (!msg) return;
                    input.value = '';
                    const area = document.getElementById('chatMessages');
                    if (area.querySelector('.loading')) area.innerHTML = '';
                    area.innerHTML += '<div class="msg user">' + escHtml(msg) + '</div>';
                    area.innerHTML += '<div class="msg assistant" id="thinking">Denke nach...</div>';
                    area.scrollTop = area.scrollHeight;
                    try {
                        const data = await api('/chat', { method: 'POST', body: JSON.stringify({ message: msg }) });
                        const el = document.getElementById('thinking');
                        if (el) el.outerHTML = '<div class="msg assistant">' + escHtml(data.response || data.error || 'Keine Antwort') + '</div>';
                    } catch(e) {
                        const el = document.getElementById('thinking');
                        if (el) el.outerHTML = '<div class="msg assistant" style="color:#da3633">Fehler: ' + e.message + '</div>';
                    }
                    area.scrollTop = area.scrollHeight;
                }

                async function loadDashboard() {
                    try {
                        const data = await api('/metrics');
                        let h = '';
                        h += m('Anfragen', data.chat_requests||0);
                        h += m('Tool-Aufrufe', data.tool_calls||0);
                        h += m('Tokens', data.tokens_total||0);
                        h += m('Fehler', data.errors||0);
                        h += m('Uptime', (data.uptime_minutes||0)+' min');
                        document.getElementById('metricsArea').innerHTML = h;
                    } catch(e) { document.getElementById('metricsArea').innerHTML = '<div class="loading">Fehler</div>'; }
                }
                function m(l,v) { return '<span class="metric">' + l + ': <span class="val">' + v + '</span></span>'; }

                async function loadMemory() {
                    try {
                        const data = await api('/memory');
                        const blocks = data.blocks || [];
                        if (!blocks.length) { document.getElementById('memoryArea').innerHTML = '<div class="loading">Keine Eintr\\u00e4ge</div>'; return; }
                        let html = '';
                        blocks.forEach(b => {
                            html += '<div class="memory-block"><span class="label">[' + escHtml(b.label) + ']</span> (' + (b.content||'').length + '/' + (b.limit||2000) + ')<br>' + escHtml((b.content||b.value||'').substring(0,200)) + '</div>';
                        });
                        document.getElementById('memoryArea').innerHTML = html;
                    } catch(e) { document.getElementById('memoryArea').innerHTML = '<div class="loading">Fehler</div>'; }
                }

                async function loadTasks() {
                    try {
                        const data = await api('/tasks');
                        const tasks = data.tasks || [];
                        if (!tasks.length) { document.getElementById('tasksArea').innerHTML = '<div class="loading">Keine Aufgaben</div>'; return; }
                        let html = '';
                        tasks.forEach(t => {
                            html += '<div class="memory-block"><strong>' + escHtml(t.name) + '</strong> \\u2014 ' + escHtml(t.schedule||'Manuell') + '<br><span style="color:#8b949e">' + escHtml(t.prompt||'') + '</span></div>';
                        });
                        document.getElementById('tasksArea').innerHTML = html;
                    } catch(e) { document.getElementById('tasksArea').innerHTML = '<div class="loading">Fehler</div>'; }
                }

                function escHtml(s) { const d = document.createElement('div'); d.textContent = s||''; return d.innerHTML; }

                setInterval(async () => {
                    try {
                        await fetch(API + '/health');
                        document.getElementById('statusBadge').className = 'status';
                        document.getElementById('statusBadge').textContent = 'Verbunden';
                    } catch {
                        document.getElementById('statusBadge').className = 'status offline';
                        document.getElementById('statusBadge').textContent = 'Offline';
                    }
                }, 5000);
            </script>
        </body>
        </html>
        """
    }
}
