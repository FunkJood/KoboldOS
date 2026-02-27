import Foundation
import Network
import AppKit
import KoboldCore
import CryptoKit

// MARK: - Google OAuth2 Integration
// Uses localhost redirect + PKCE — the standard flow for Google Desktop apps.
// Google automatically allows http://localhost redirects for Desktop-type clients.
// No client_secret needed.

// MARK: - GoogleScope

enum GoogleScope: String, CaseIterable, Codable, Sendable {
    case youtube_readonly, youtube_upload, drive, docs, sheets
    case gmail, calendar, contacts, tasks

    var scopeString: String {
        switch self {
        case .youtube_readonly: return "https://www.googleapis.com/auth/youtube.readonly"
        case .youtube_upload:   return "https://www.googleapis.com/auth/youtube.upload"
        case .drive:            return "https://www.googleapis.com/auth/drive"
        case .docs:             return "https://www.googleapis.com/auth/documents"
        case .sheets:           return "https://www.googleapis.com/auth/spreadsheets"
        case .gmail:            return "https://www.googleapis.com/auth/gmail.modify"
        case .calendar:         return "https://www.googleapis.com/auth/calendar"
        case .contacts:         return "https://www.googleapis.com/auth/contacts.readonly"
        case .tasks:            return "https://www.googleapis.com/auth/tasks"
        }
    }

    var label: String {
        switch self {
        case .youtube_readonly: return "YouTube (Lesen)"
        case .youtube_upload:   return "YouTube (Upload)"
        case .drive:            return "Drive"
        case .docs:             return "Docs"
        case .sheets:           return "Sheets"
        case .gmail:            return "Gmail"
        case .calendar:         return "Kalender"
        case .contacts:         return "Kontakte"
        case .tasks:            return "Tasks"
        }
    }

    var scopeDescription: String {
        switch self {
        case .youtube_readonly: return "Videos, Playlists & Kanäle ansehen"
        case .youtube_upload:   return "Videos auf YouTube hochladen"
        case .drive:            return "Dateien in Google Drive verwalten"
        case .docs:             return "Google Docs lesen & bearbeiten"
        case .sheets:           return "Google Sheets lesen & bearbeiten"
        case .gmail:            return "E-Mails lesen & senden"
        case .calendar:         return "Termine erstellen & verwalten"
        case .contacts:         return "Kontakte lesen"
        case .tasks:            return "Aufgaben verwalten"
        }
    }
}

// MARK: - GoogleOAuth (Localhost Redirect + PKCE)

final class GoogleOAuth: NSObject, @unchecked Sendable {
    static let shared = GoogleOAuth()

    private let lock = NSLock()
    private var _isConnected = false
    private var _userEmail = ""
    private var _accessToken = ""
    private var _refreshToken = ""
    private var _tokenExpiry: Date = .distantPast
    private var pendingCodeVerifier: String?
    private var pendingState: String?
    private var callbackListener: NWListener?
    private var callbackPort: UInt16 = 0

    // Thread-safe accessors
    var isConnected: Bool { lock.withLock { _isConnected } }
    var userEmail: String { lock.withLock { _userEmail } }

    private func setConnected(_ v: Bool) { lock.withLock { _isConnected = v } }
    private func setUserEmail(_ v: String) { lock.withLock { _userEmail = v } }
    private func setAccessToken(_ v: String) { lock.withLock { _accessToken = v } }
    private func setRefreshToken(_ v: String) { lock.withLock { _refreshToken = v } }
    private func setTokenExpiry(_ v: Date) { lock.withLock { _tokenExpiry = v } }
    private func getAccessTokenRaw() -> String { lock.withLock { _accessToken } }
    private func getRefreshTokenRaw() -> String { lock.withLock { _refreshToken } }
    private func getTokenExpiry() -> Date { lock.withLock { _tokenExpiry } }

    // OAuth client loaded from Settings (Verbindungen → Google)
    var clientId: String { UserDefaults.standard.string(forKey: "kobold.google.clientId") ?? "" }
    var clientSecret: String { UserDefaults.standard.string(forKey: "kobold.google.clientSecret") ?? "" }

    private override init() {
        super.init()
        restoreFromDefaults()
    }

    // MARK: - Restore from UserDefaults (avoids Keychain password prompts)

    private func restoreFromDefaults() {
        let d = UserDefaults.standard
        if let access = d.string(forKey: "kobold.google.accessToken"),
           let refresh = d.string(forKey: "kobold.google.refreshToken"),
           d.double(forKey: "kobold.google.tokenExpiry") > 0 {
            let expiryInterval = d.double(forKey: "kobold.google.tokenExpiry")
            setAccessToken(access)
            setRefreshToken(refresh)
            setTokenExpiry(Date(timeIntervalSince1970: expiryInterval))
            setConnected(true)
            if let email = d.string(forKey: "kobold.google.email") {
                setUserEmail(email)
            }
            // P12: print entfernt
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sign In (localhost redirect)

    /// Enabled scopes — persisted in UserDefaults (reset if cached scopes contain removed values)
    var enabledScopes: Set<GoogleScope> {
        get {
            if let data = UserDefaults.standard.data(forKey: "kobold.google.scopes"),
               let scopes = try? JSONDecoder().decode(Set<GoogleScope>.self, from: data),
               !scopes.isEmpty {
                return scopes
            }
            return Set(GoogleScope.allCases) // default: all
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "kobold.google.scopes")
            }
        }
    }

    func signIn() {
        // Start local callback server
        guard startCallbackServer() else {
            // P12: print entfernt
            return
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = randomState()
        lock.withLock {
            pendingCodeVerifier = codeVerifier
            pendingState = state
        }

        let scopeStrings = enabledScopes.map(\.scopeString).joined(separator: " ")
        let redirectUri = "http://127.0.0.1:\(callbackPort)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: scopeStrings + " openid email profile"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else { return }

        // Open in default browser
        NSWorkspace.shared.open(authURL)
        print("[GoogleOAuth] Opened browser for sign-in (callback on port \(callbackPort))")
    }

    // Legacy aliases
    func startAuth(clientId: String, enabledScopes: [GoogleScope]) { signIn() }
    func startAuth(clientId: String, clientSecret: String, enabledScopes: [GoogleScope]) { signIn() }

    // MARK: - Local Callback Server

    private func startCallbackServer() -> Bool {
        stopCallbackServer()

        // Pick a random high port
        let port = UInt16.random(in: 49152...65000)

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.callbackPort = port

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    print("[GoogleOAuth] Listener failed: \(err)")
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.callbackListener = listener
            return true
        } catch {
            print("[GoogleOAuth] Failed to create listener: \(error)")
            return false
        }
    }

    private func stopCallbackServer() {
        callbackListener?.cancel()
        callbackListener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let request = String(data: data, encoding: .utf8) else { return }

            // Parse GET /?code=...&state=...
            guard let firstLine = request.components(separatedBy: "\r\n").first,
                  let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                  let components = URLComponents(string: "http://localhost\(urlPart)"),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
                // Send error response
                let errorHTML = self.buildResponseHTML(success: false)
                self.sendHTTPResponse(connection: connection, html: errorHTML)
                return
            }

            // Validate state
            let expectedState: String? = self.lock.withLock { self.pendingState }
            guard state == expectedState else {
                print("[GoogleOAuth] State mismatch!")
                let errorHTML = self.buildResponseHTML(success: false)
                self.sendHTTPResponse(connection: connection, html: errorHTML)
                return
            }

            // Send success response immediately
            let successHTML = self.buildResponseHTML(success: true)
            self.sendHTTPResponse(connection: connection, html: successHTML)

            // Exchange code for tokens
            let redirectUri = "http://127.0.0.1:\(self.callbackPort)"
            let clientId = self.clientId
            Task {
                await self.exchangeCodeForTokens(code: code, clientId: clientId, redirectUri: redirectUri)
                self.stopCallbackServer()
            }
        }
    }

    private func sendHTTPResponse(connection: NWConnection, html: String) {
        let body = html.data(using: .utf8)!
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = header.data(using: .utf8)! + body
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func buildResponseHTML(success: Bool) -> String {
        let title = success ? "Anmeldung erfolgreich!" : "Anmeldung fehlgeschlagen"
        let message = success
            ? "Du bist jetzt mit Google verbunden. Du kannst dieses Fenster schliessen."
            : "Etwas ist schiefgelaufen. Bitte versuche es erneut."
        let color = success ? "#34C759" : "#FF3B30"
        let icon = success ? "&#10003;" : "&#10007;"

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        body { font-family: -apple-system, system-ui, sans-serif; display: flex; justify-content: center;
               align-items: center; height: 100vh; margin: 0; background: #1a1a1a; color: #fff; }
        .card { text-align: center; padding: 48px; border-radius: 16px; background: #2a2a2a;
                box-shadow: 0 8px 32px rgba(0,0,0,0.3); }
        .icon { font-size: 48px; color: \(color); margin-bottom: 16px; }
        h1 { font-size: 24px; margin: 0 0 8px 0; }
        p { color: #999; font-size: 14px; margin: 0; }
        </style>
        <script>setTimeout(function(){ window.close(); }, 3000);</script>
        </head><body><div class="card">
        <div class="icon">\(icon)</div>
        <h1>\(title)</h1>
        <p>\(message)</p>
        </div></body></html>
        """
    }

    // MARK: - Token Exchange (PKCE)

    private func exchangeCodeForTokens(code: String, clientId: String, redirectUri: String) async {
        let codeVerifier: String? = lock.withLock { pendingCodeVerifier }
        guard let verifier = codeVerifier else {
            print("[GoogleOAuth] No code verifier found")
            return
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "code=\(code.urlEncoded)",
            "client_id=\(clientId.urlEncoded)",
            "client_secret=\(self.clientSecret.urlEncoded)",
            "redirect_uri=\(redirectUri.urlEncoded)",
            "grant_type=authorization_code",
            "code_verifier=\(verifier.urlEncoded)"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                print("[GoogleOAuth] Token exchange failed: \(errBody)")
                return
            }

            let refreshToken = json["refresh_token"] as? String ?? getRefreshTokenRaw()
            let expiresIn = json["expires_in"] as? Int ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            setAccessToken(accessToken)
            setRefreshToken(refreshToken)
            setTokenExpiry(expiry)
            setConnected(true)

            let d = UserDefaults.standard
            d.set(accessToken, forKey: "kobold.google.accessToken")
            d.set(refreshToken, forKey: "kobold.google.refreshToken")
            d.set(expiry.timeIntervalSince1970, forKey: "kobold.google.tokenExpiry")
            d.set(true, forKey: "kobold.google.connected")

            await fetchUserEmail(accessToken: accessToken)
            print("[GoogleOAuth] Sign-in successful")
        } catch {
            print("[GoogleOAuth] Token exchange error: \(error)")
        }
    }

    // MARK: - Refresh Token

    func refreshAccessToken() async -> Bool {
        let refreshToken = getRefreshTokenRaw()
        guard !refreshToken.isEmpty else { return false }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "refresh_token=\(refreshToken.urlEncoded)",
            "client_id=\(clientId.urlEncoded)",
            "client_secret=\(clientSecret.urlEncoded)",
            "grant_type=refresh_token"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                return false
            }

            let expiresIn = json["expires_in"] as? Int ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            setAccessToken(accessToken)
            setTokenExpiry(expiry)

            UserDefaults.standard.set(accessToken, forKey: "kobold.google.accessToken")
            UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: "kobold.google.tokenExpiry")

            return true
        } catch {
            print("[GoogleOAuth] Refresh error: \(error)")
            return false
        }
    }

    // MARK: - Verify Token (lightweight check)

    func verifyToken() async {
        let token = getAccessTokenRaw()
        guard !token.isEmpty else {
            setConnected(false)
            return
        }

        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                if !(await refreshAccessToken()) {
                    setConnected(false)
                }
            }
        } catch {
            // Network error → don't disconnect
        }
    }

    // MARK: - Get Valid Access Token

    func getAccessToken() async -> String? {
        let token = getAccessTokenRaw()
        guard !token.isEmpty else { return nil }
        if getTokenExpiry() < Date() {
            let ok = await refreshAccessToken()
            if !ok { return nil }
        }
        return getAccessTokenRaw()
    }

    // MARK: - Sign Out

    func signOut() async {
        let token = getAccessTokenRaw()
        if !token.isEmpty {
            if let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(token.urlEncoded)") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        setAccessToken("")
        setRefreshToken("")
        setTokenExpiry(.distantPast)
        setUserEmail("")
        setConnected(false)

        let d = UserDefaults.standard
        d.removeObject(forKey: "kobold.google.accessToken")
        d.removeObject(forKey: "kobold.google.refreshToken")
        d.removeObject(forKey: "kobold.google.tokenExpiry")
        d.removeObject(forKey: "kobold.google.email")
        d.set(false, forKey: "kobold.google.connected")
        // P12: print entfernt
    }

    func revokeToken() async { await signOut() }

    // MARK: - Fetch User Email

    private func fetchUserEmail(accessToken: String) async {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = json["email"] as? String {
                setUserEmail(email)
                UserDefaults.standard.set(email, forKey: "kobold.google.email")
            }
        } catch {
            // P12: print entfernt
        }
    }
}

// MARK: - URL Encoding Helper

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
