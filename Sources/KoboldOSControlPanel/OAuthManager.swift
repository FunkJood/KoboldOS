import Foundation
import Network
import AppKit
import CryptoKit

// MARK: - Generic OAuth2 Manager (PKCE + localhost redirect)
// Extracts common OAuth patterns from GoogleOAuth / SoundCloudOAuth

struct OAuthConfig {
    let serviceName: String          // e.g. "github"
    let authorizeURL: String         // e.g. "https://github.com/login/oauth/authorize"
    let tokenURL: String             // e.g. "https://github.com/login/oauth/access_token"
    let userInfoURL: String?         // optional user info endpoint
    let scopes: String               // space-separated scopes
    let clientIdKey: String          // UserDefaults key for clientId
    let clientSecretKey: String      // UserDefaults key for clientSecret
    let usePKCE: Bool                // use PKCE code_challenge
    let authHeaderPrefix: String     // "Bearer" or "token" etc.
    let tokenJsonPath: String?       // nil = "access_token", e.g. "authed_user.access_token" for Slack
    let tokenExchangeAuth: TokenExchangeAuth // how to auth the token exchange request
    let extraAuthorizeParams: [String: String]  // extra params for authorize URL
    let extraTokenParams: [String: String]      // extra params for token exchange
    let acceptJSON: Bool             // send Accept: application/json on token exchange
    let userNameJsonPath: String     // JSON path to username in userinfo response

    enum TokenExchangeAuth {
        case body       // client_id + client_secret in POST body (default)
        case basicAuth  // HTTP Basic Auth header
    }

    init(
        serviceName: String,
        authorizeURL: String,
        tokenURL: String,
        userInfoURL: String? = nil,
        scopes: String = "",
        clientIdKey: String? = nil,
        clientSecretKey: String? = nil,
        usePKCE: Bool = true,
        authHeaderPrefix: String = "Bearer",
        tokenJsonPath: String? = nil,
        tokenExchangeAuth: TokenExchangeAuth = .body,
        extraAuthorizeParams: [String: String] = [:],
        extraTokenParams: [String: String] = [:],
        acceptJSON: Bool = false,
        userNameJsonPath: String = "name"
    ) {
        self.serviceName = serviceName
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.userInfoURL = userInfoURL
        self.scopes = scopes
        self.clientIdKey = clientIdKey ?? "kobold.\(serviceName).clientId"
        self.clientSecretKey = clientSecretKey ?? "kobold.\(serviceName).clientSecret"
        self.usePKCE = usePKCE
        self.authHeaderPrefix = authHeaderPrefix
        self.tokenJsonPath = tokenJsonPath
        self.tokenExchangeAuth = tokenExchangeAuth
        self.extraAuthorizeParams = extraAuthorizeParams
        self.extraTokenParams = extraTokenParams
        self.acceptJSON = acceptJSON
        self.userNameJsonPath = userNameJsonPath
    }
}

// MARK: - OAuthManager Base Class

class OAuthManager: NSObject, @unchecked Sendable {
    let config: OAuthConfig

    private let lock = NSLock()
    private var _isConnected = false
    private var _userName = ""
    private var _accessToken = ""
    private var _refreshToken = ""
    private var _tokenExpiry: Date = .distantPast
    private var pendingCodeVerifier: String?
    private var pendingState: String?
    private var callbackListener: NWListener?
    private var callbackPort: UInt16 = 0

    var isConnected: Bool { lock.withLock { _isConnected } }
    var userName: String { lock.withLock { _userName } }

    func setConnected(_ v: Bool) { lock.withLock { _isConnected = v } }
    func setUserName(_ v: String) { lock.withLock { _userName = v } }
    private func setAccessToken(_ v: String) { lock.withLock { _accessToken = v } }
    private func setRefreshToken(_ v: String) { lock.withLock { _refreshToken = v } }
    private func setTokenExpiry(_ v: Date) { lock.withLock { _tokenExpiry = v } }
    func getAccessTokenRaw() -> String { lock.withLock { _accessToken } }
    private func getRefreshTokenRaw() -> String { lock.withLock { _refreshToken } }
    private func getTokenExpiry() -> Date { lock.withLock { _tokenExpiry } }

    var clientId: String { UserDefaults.standard.string(forKey: config.clientIdKey) ?? "" }
    var clientSecret: String { UserDefaults.standard.string(forKey: config.clientSecretKey) ?? "" }

    private var prefix: String { "kobold.\(config.serviceName)" }

    init(config: OAuthConfig) {
        self.config = config
        super.init()
        restoreFromDefaults()
    }

    // MARK: - Persistence (UserDefaults — avoids Keychain prompts on unsigned apps)

    private func restoreFromDefaults() {
        let d = UserDefaults.standard
        if let access = d.string(forKey: "\(prefix).accessToken"),
           let refresh = d.string(forKey: "\(prefix).refreshToken"),
           d.double(forKey: "\(prefix).tokenExpiry") > 0 {
            let expiryInterval = d.double(forKey: "\(prefix).tokenExpiry")
            setAccessToken(access)
            setRefreshToken(refresh)
            setTokenExpiry(Date(timeIntervalSince1970: expiryInterval))
            setConnected(true)
            if let name = d.string(forKey: "\(prefix).username") {
                setUserName(name)
            }
            print("[\(config.serviceName)] Restored session for \(userName)")
        }
    }

    private func saveToDefaults(accessToken: String, refreshToken: String, expiry: Date, userName: String? = nil) {
        let d = UserDefaults.standard
        d.set(accessToken, forKey: "\(prefix).accessToken")
        if !refreshToken.isEmpty {
            d.set(refreshToken, forKey: "\(prefix).refreshToken")
        }
        d.set(expiry.timeIntervalSince1970, forKey: "\(prefix).tokenExpiry")
        d.set(true, forKey: "\(prefix).connected")
        if let name = userName {
            d.set(name, forKey: "\(prefix).username")
        }
    }

    private func clearDefaults() {
        let d = UserDefaults.standard
        for key in ["accessToken", "refreshToken", "tokenExpiry", "username", "connected"] {
            d.removeObject(forKey: "\(prefix).\(key)")
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
        let id = clientId
        guard !id.isEmpty else {
            print("[\(config.serviceName)] Client ID not configured")
            return
        }
        guard startCallbackServer() else {
            print("[\(config.serviceName)] Failed to start callback server")
            return
        }

        let state = randomState()
        var codeVerifier: String?
        if config.usePKCE {
            codeVerifier = generateCodeVerifier()
        }
        lock.withLock {
            pendingCodeVerifier = codeVerifier
            pendingState = state
        }

        let redirectUri = "http://127.0.0.1:\(callbackPort)/callback"

        var components = URLComponents(string: config.authorizeURL)!
        var queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ]
        if !config.scopes.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: config.scopes))
        }
        if config.usePKCE, let verifier = codeVerifier {
            queryItems.append(URLQueryItem(name: "code_challenge", value: generateCodeChallenge(from: verifier)))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        for (key, value) in config.extraAuthorizeParams {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        guard let authURL = components.url else { return }
        NSWorkspace.shared.open(authURL)
        print("[\(config.serviceName)] Opened browser for sign-in (callback on port \(callbackPort))")
    }

    // MARK: - Callback Server

    private func startCallbackServer() -> Bool {
        stopCallbackServer()
        // Try random ports in ephemeral range
        for _ in 0..<10 {
            let port = UInt16.random(in: 49152...65000)
            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener.stateUpdateHandler = { state in
                    if case .failed(let err) = state {
                        print("[OAuth] Listener failed: \(err)")
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
                self.callbackListener = listener
                self.callbackPort = port
                return true
            } catch {
                continue
            }
        }
        return false
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
        let name = config.serviceName.capitalized
        let title = success ? "\(name) verbunden!" : "Verbindung fehlgeschlagen"
        let msg = success ? "Du bist jetzt mit \(name) verbunden. Du kannst dieses Fenster schliessen." : "Bitte versuche es erneut."
        let color = success ? "#34C759" : "#FF3B30"
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

        guard let url = URL(string: config.tokenURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        if config.acceptJSON {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        var bodyParts = [
            "code=\(code.oauthURLEncoded)",
            "redirect_uri=\(redirectUri.oauthURLEncoded)",
            "grant_type=authorization_code"
        ]

        switch config.tokenExchangeAuth {
        case .body:
            bodyParts.append("client_id=\(clientId.oauthURLEncoded)")
            bodyParts.append("client_secret=\(clientSecret.oauthURLEncoded)")
        case .basicAuth:
            let credentials = "\(clientId):\(clientSecret)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        if config.usePKCE, let verifier = codeVerifier {
            bodyParts.append("code_verifier=\(verifier.oauthURLEncoded)")
        }
        for (key, value) in config.extraTokenParams {
            bodyParts.append("\(key)=\(value.oauthURLEncoded)")
        }

        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[\(config.serviceName)] Token exchange: invalid JSON")
                return
            }

            // Extract access token (supports nested paths like "authed_user.access_token")
            let accessToken: String?
            if let path = config.tokenJsonPath {
                accessToken = resolveJsonPath(json, path: path) as? String
            } else {
                accessToken = json["access_token"] as? String
            }

            guard let token = accessToken, !token.isEmpty else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                print("[\(config.serviceName)] Token exchange failed: \(errBody)")
                return
            }

            let refreshToken = json["refresh_token"] as? String ?? ""
            let expiresIn = json["expires_in"] as? Int ?? 86400
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            setAccessToken(token)
            setRefreshToken(refreshToken)
            setTokenExpiry(expiry)
            setConnected(true)

            saveToDefaults(accessToken: token, refreshToken: refreshToken, expiry: expiry)

            if let userInfoURL = config.userInfoURL {
                await fetchUserInfo(accessToken: token, url: userInfoURL)
            }
            print("[\(config.serviceName)] Sign-in successful")
        } catch {
            print("[\(config.serviceName)] Token exchange error: \(error)")
        }
    }

    // MARK: - Refresh

    func refreshAccessToken() async -> Bool {
        let refreshToken = getRefreshTokenRaw()
        guard !refreshToken.isEmpty else { return false }

        guard let url = URL(string: config.tokenURL) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if config.acceptJSON {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        var bodyParts = [
            "refresh_token=\(refreshToken.oauthURLEncoded)",
            "grant_type=refresh_token"
        ]
        switch config.tokenExchangeAuth {
        case .body:
            bodyParts.append("client_id=\(clientId.oauthURLEncoded)")
            bodyParts.append("client_secret=\(clientSecret.oauthURLEncoded)")
        case .basicAuth:
            let credentials = "\(clientId):\(clientSecret)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else { return false }

            let expiresIn = json["expires_in"] as? Int ?? 86400
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            setAccessToken(accessToken)
            setTokenExpiry(expiry)

            let d = UserDefaults.standard
            d.set(accessToken, forKey: "\(prefix).accessToken")
            d.set(expiry.timeIntervalSince1970, forKey: "\(prefix).tokenExpiry")

            if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
                setRefreshToken(newRefresh)
                d.set(newRefresh, forKey: "\(prefix).refreshToken")
            }
            return true
        } catch {
            print("[\(config.serviceName)] Refresh error: \(error)")
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
        clearDefaults()
        print("[\(config.serviceName)] Signed out")
    }

    // MARK: - User Info

    private func fetchUserInfo(accessToken: String, url urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.setValue("\(config.authHeaderPrefix) \(accessToken)", forHTTPHeaderField: "Authorization")
        if config.acceptJSON {
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = resolveJsonPath(json, path: config.userNameJsonPath) as? String {
                    setUserName(name)
                    UserDefaults.standard.set(name, forKey: "\(prefix).username")
                    print("[\(config.serviceName)] User: \(name)")
                }
            }
        } catch {
            print("[\(config.serviceName)] User info error: \(error)")
        }
    }

    // MARK: - Helpers

    private func resolveJsonPath(_ json: [String: Any], path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        var current: Any = json
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        return current
    }
}

// MARK: - Concrete OAuth Services

final class GitHubOAuth: OAuthManager, @unchecked Sendable {
    static let shared = GitHubOAuth()
    private init() {
        super.init(config: OAuthConfig(
            serviceName: "github",
            authorizeURL: "https://github.com/login/oauth/authorize",
            tokenURL: "https://github.com/login/oauth/access_token",
            userInfoURL: "https://api.github.com/user",
            scopes: "repo read:org read:user",
            usePKCE: false,
            authHeaderPrefix: "token",
            acceptJSON: true,
            userNameJsonPath: "login"
        ))
    }
}

final class MicrosoftOAuth: OAuthManager, @unchecked Sendable {
    static let shared = MicrosoftOAuth()
    private init() {
        super.init(config: OAuthConfig(
            serviceName: "microsoft",
            authorizeURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            userInfoURL: "https://graph.microsoft.com/v1.0/me",
            scopes: "openid profile email Files.ReadWrite Mail.ReadWrite Calendars.ReadWrite Chat.ReadWrite offline_access",
            usePKCE: true,
            extraAuthorizeParams: ["response_mode": "query"],
            userNameJsonPath: "displayName"
        ))
    }
}

final class SlackOAuth: OAuthManager, @unchecked Sendable {
    static let shared = SlackOAuth()
    private init() {
        super.init(config: OAuthConfig(
            serviceName: "slack",
            authorizeURL: "https://slack.com/oauth/v2/authorize",
            tokenURL: "https://slack.com/api/oauth.v2.access",
            userInfoURL: nil,
            scopes: "channels:read channels:history chat:write users:read",
            clientIdKey: "kobold.slack.clientId",
            clientSecretKey: "kobold.slack.clientSecret",
            usePKCE: false,
            tokenJsonPath: "authed_user.access_token",
            userNameJsonPath: "authed_user.id"
        ))
    }

    override init(config: OAuthConfig) {
        super.init(config: config)
    }
}

final class NotionOAuth: OAuthManager, @unchecked Sendable {
    static let shared = NotionOAuth()
    private init() {
        super.init(config: OAuthConfig(
            serviceName: "notion",
            authorizeURL: "https://api.notion.com/v1/oauth/authorize",
            tokenURL: "https://api.notion.com/v1/oauth/token",
            userInfoURL: nil,
            scopes: "",
            usePKCE: false,
            authHeaderPrefix: "Bearer",
            tokenExchangeAuth: .basicAuth,
            extraAuthorizeParams: ["owner": "user"],
            userNameJsonPath: "owner.user.name"
        ))
    }
}

final class WhatsAppOAuth: OAuthManager, @unchecked Sendable {
    static let shared = WhatsAppOAuth()

    var phoneNumberId: String {
        get { UserDefaults.standard.string(forKey: "kobold.whatsapp.phoneNumberId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "kobold.whatsapp.phoneNumberId") }
    }

    private init() {
        super.init(config: OAuthConfig(
            serviceName: "whatsapp",
            authorizeURL: "https://www.facebook.com/v18.0/dialog/oauth",
            tokenURL: "https://graph.facebook.com/v18.0/oauth/access_token",
            userInfoURL: "https://graph.facebook.com/v18.0/me",
            scopes: "whatsapp_business_management whatsapp_business_messaging",
            usePKCE: false,
            userNameJsonPath: "name"
        ))
    }
}

// MARK: - URL Encoding Extension

private extension String {
    var oauthURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
