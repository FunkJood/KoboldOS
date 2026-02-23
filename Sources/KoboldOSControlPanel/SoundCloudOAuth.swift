import Foundation
import Network
import AppKit
import KoboldCore
import CryptoKit

// MARK: - SoundCloud OAuth2 Integration (PKCE + localhost redirect)

final class SoundCloudOAuth: NSObject, @unchecked Sendable {
    static let shared = SoundCloudOAuth()

    // Hardcoded OAuth client
    let clientId = "56Xd1suRhHAWfNXKY8BGYIfWAkZJEAsk"
    let clientSecret = "wj9oBAItfD0X1asfihfOABkql9FTZAV1"
    private let callbackPort: UInt16 = 7777

    private let lock = NSLock()
    private var _isConnected = false
    private var _userName = ""
    private var _accessToken = ""
    private var _refreshToken = ""
    private var _tokenExpiry: Date = .distantPast
    private var pendingCodeVerifier: String?
    private var pendingState: String?
    private var callbackListener: NWListener?

    var isConnected: Bool { lock.withLock { _isConnected } }
    var userName: String { lock.withLock { _userName } }

    private func setConnected(_ v: Bool) { lock.withLock { _isConnected = v } }
    private func setUserName(_ v: String) { lock.withLock { _userName = v } }
    private func setAccessToken(_ v: String) { lock.withLock { _accessToken = v } }
    private func setRefreshToken(_ v: String) { lock.withLock { _refreshToken = v } }
    private func setTokenExpiry(_ v: Date) { lock.withLock { _tokenExpiry = v } }
    private func getAccessTokenRaw() -> String { lock.withLock { _accessToken } }
    private func getRefreshTokenRaw() -> String { lock.withLock { _refreshToken } }
    private func getTokenExpiry() -> Date { lock.withLock { _tokenExpiry } }

    private override init() {
        super.init()
        restoreFromDefaults()
    }

    // MARK: - Restore from UserDefaults (avoids Keychain password prompts)

    private func restoreFromDefaults() {
        let d = UserDefaults.standard
        if let access = d.string(forKey: "kobold.soundcloud.accessToken"),
           let refresh = d.string(forKey: "kobold.soundcloud.refreshToken"),
           d.double(forKey: "kobold.soundcloud.tokenExpiry") > 0 {
            let expiryInterval = d.double(forKey: "kobold.soundcloud.tokenExpiry")
            setAccessToken(access)
            setRefreshToken(refresh)
            setTokenExpiry(Date(timeIntervalSince1970: expiryInterval))
            setConnected(true)
            if let name = d.string(forKey: "kobold.soundcloud.username") {
                setUserName(name)
            }
            print("[SoundCloud] Restored session for \(userName)")
        }
    }

    // MARK: - PKCE

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

    // MARK: - Sign In

    func signIn() {
        guard startCallbackServer() else {
            print("[SoundCloud] Failed to start callback server")
            return
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = randomState()
        lock.withLock {
            pendingCodeVerifier = codeVerifier
            pendingState = state
        }

        let redirectUri = "http://127.0.0.1:\(callbackPort)/callback"

        var components = URLComponents(string: "https://api.soundcloud.com/connect")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: ""),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else { return }
        NSWorkspace.shared.open(authURL)
        print("[SoundCloud] Opened browser for sign-in (callback on port \(callbackPort))")
    }

    // MARK: - Callback Server

    private func startCallbackServer() -> Bool {
        stopCallbackServer()
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: callbackPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    print("[SoundCloud] Listener failed: \(err)")
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.callbackListener = listener
            return true
        } catch {
            print("[SoundCloud] Failed to create listener: \(error)")
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

            guard let firstLine = request.components(separatedBy: "\r\n").first,
                  let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                  let components = URLComponents(string: "http://localhost\(urlPart)"),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
                let html = self.buildHTML(success: false)
                self.sendHTTPResponse(connection: connection, html: html)
                return
            }

            let expectedState: String? = self.lock.withLock { self.pendingState }
            guard state == expectedState else {
                let html = self.buildHTML(success: false)
                self.sendHTTPResponse(connection: connection, html: html)
                return
            }

            let html = self.buildHTML(success: true)
            self.sendHTTPResponse(connection: connection, html: html)

            let redirectUri = "http://127.0.0.1:\(self.callbackPort)/callback"
            Task {
                await self.exchangeCodeForTokens(code: code, redirectUri: redirectUri)
                self.stopCallbackServer()
            }
        }
    }

    private func sendHTTPResponse(connection: NWConnection, html: String) {
        let body = html.data(using: .utf8)!
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = header.data(using: .utf8)! + body
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func buildHTML(success: Bool) -> String {
        let title = success ? "SoundCloud verbunden!" : "Verbindung fehlgeschlagen"
        let msg = success ? "Du bist jetzt mit SoundCloud verbunden. Du kannst dieses Fenster schliessen." : "Bitte versuche es erneut."
        let color = success ? "#FF5500" : "#FF3B30"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>body{font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff;}
        .card{text-align:center;padding:48px;border-radius:16px;background:#2a2a2a;box-shadow:0 8px 32px rgba(0,0,0,0.3);}
        h1{font-size:24px;margin:0 0 8px;color:\(color);}p{color:#999;font-size:14px;}</style>
        <script>setTimeout(function(){window.close();},3000);</script>
        </head><body><div class="card"><h1>\(title)</h1><p>\(msg)</p></div></body></html>
        """
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, redirectUri: String) async {
        let codeVerifier: String? = lock.withLock { pendingCodeVerifier }
        guard let verifier = codeVerifier else { return }

        guard let url = URL(string: "https://secure.soundcloud.com/oauth/token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "code=\(code.sc_urlEncoded)",
            "client_id=\(clientId.sc_urlEncoded)",
            "client_secret=\(clientSecret.sc_urlEncoded)",
            "redirect_uri=\(redirectUri.sc_urlEncoded)",
            "grant_type=authorization_code",
            "code_verifier=\(verifier.sc_urlEncoded)"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                print("[SoundCloud] Token exchange failed: \(errBody)")
                return
            }

            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = json["expires_in"] as? Int ?? 86400
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            setAccessToken(accessToken)
            setRefreshToken(refreshToken)
            setTokenExpiry(expiry)
            setConnected(true)

            let d = UserDefaults.standard
            d.set(accessToken, forKey: "kobold.soundcloud.accessToken")
            if !refreshToken.isEmpty {
                d.set(refreshToken, forKey: "kobold.soundcloud.refreshToken")
            }
            d.set(expiry.timeIntervalSince1970, forKey: "kobold.soundcloud.tokenExpiry")
            d.set(true, forKey: "kobold.soundcloud.connected")

            await fetchUserInfo(accessToken: accessToken)
            print("[SoundCloud] Sign-in successful")
        } catch {
            print("[SoundCloud] Token exchange error: \(error)")
        }
    }

    // MARK: - Refresh

    func refreshAccessToken() async -> Bool {
        let refreshToken = getRefreshTokenRaw()
        guard !refreshToken.isEmpty else { return false }

        guard let url = URL(string: "https://secure.soundcloud.com/oauth/token") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "refresh_token=\(refreshToken.sc_urlEncoded)",
            "client_id=\(clientId.sc_urlEncoded)",
            "client_secret=\(clientSecret.sc_urlEncoded)",
            "grant_type=refresh_token"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else { return false }

            let expiresIn = json["expires_in"] as? Int ?? 86400
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            setAccessToken(accessToken)
            setTokenExpiry(expiry)

            UserDefaults.standard.set(accessToken, forKey: "kobold.soundcloud.accessToken")
            UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: "kobold.soundcloud.tokenExpiry")

            if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
                setRefreshToken(newRefresh)
                UserDefaults.standard.set(newRefresh, forKey: "kobold.soundcloud.refreshToken")
            }
            return true
        } catch {
            print("[SoundCloud] Refresh error: \(error)")
            return false
        }
    }

    // MARK: - Get Valid Token

    func getAccessToken() async -> String? {
        let token = getAccessTokenRaw()
        guard !token.isEmpty else { return nil }
        if getTokenExpiry() < Date() {
            if !(await refreshAccessToken()) { return nil }
        }
        return getAccessTokenRaw()
    }

    // MARK: - Sign Out

    func signOut() async {
        setAccessToken("")
        setRefreshToken("")
        setTokenExpiry(.distantPast)
        setUserName("")
        setConnected(false)

        let d = UserDefaults.standard
        d.removeObject(forKey: "kobold.soundcloud.accessToken")
        d.removeObject(forKey: "kobold.soundcloud.refreshToken")
        d.removeObject(forKey: "kobold.soundcloud.tokenExpiry")
        d.removeObject(forKey: "kobold.soundcloud.username")
        d.set(false, forKey: "kobold.soundcloud.connected")
        print("[SoundCloud] Signed out")
    }

    // MARK: - User Info

    private func fetchUserInfo(accessToken: String) async {
        guard let url = URL(string: "https://api.soundcloud.com/me") else { return }
        var req = URLRequest(url: url)
        req.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let username = json["username"] as? String {
                setUserName(username)
                UserDefaults.standard.set(username, forKey: "kobold.soundcloud.username")
                print("[SoundCloud] User: \(username)")
            }
        } catch {
            print("[SoundCloud] User info error: \(error)")
        }
    }
}

private extension String {
    var sc_urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
