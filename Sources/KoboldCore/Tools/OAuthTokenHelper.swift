import Foundation

// MARK: - OAuthTokenHelper
/// Generic OAuth2 token refresh helper for API tools.
/// Reads credentials from UserDefaults (same keys as OAuthManager in UI layer).
/// Tools in KoboldCore can't import OAuthManager (KoboldOSControlPanel), so this
/// helper replicates the refresh logic using the shared UserDefaults storage.
public struct OAuthTokenHelper: Sendable {

    public let prefix: String        // e.g. "kobold.microsoft"
    public let tokenURL: String      // e.g. "https://login.microsoftonline.com/.../token"
    public let useBasicAuth: Bool    // Notion = true, default = false
    public let acceptJSON: Bool      // GitHub = true, default = false

    public init(prefix: String, tokenURL: String, useBasicAuth: Bool = false, acceptJSON: Bool = false) {
        self.prefix = prefix
        self.tokenURL = tokenURL
        self.useBasicAuth = useBasicAuth
        self.acceptJSON = acceptJSON
    }

    // MARK: - Get Valid Token

    /// Returns a valid access token, auto-refreshing if expired.
    /// Returns nil if no token exists or refresh fails.
    public func getValidToken() async -> String? {
        let d = UserDefaults.standard
        guard let token = d.string(forKey: "\(prefix).accessToken"), !token.isEmpty else { return nil }

        let expiry = d.double(forKey: "\(prefix).tokenExpiry")
        if expiry > 0 && Date(timeIntervalSince1970: expiry) < Date() {
            // Token expired — try refresh
            return await refreshToken()
        }
        return token
    }

    // MARK: - Refresh Token

    /// Refresh the access token using the stored refresh_token + client credentials.
    /// Updates UserDefaults on success. Returns new token or nil.
    public func refreshToken() async -> String? {
        let d = UserDefaults.standard
        guard let rt = d.string(forKey: "\(prefix).refreshToken"), !rt.isEmpty else { return nil }
        let clientId = d.string(forKey: "\(prefix).clientId") ?? ""
        let clientSecret = d.string(forKey: "\(prefix).clientSecret") ?? ""
        guard !clientId.isEmpty else { return nil }

        guard let url = URL(string: tokenURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        if acceptJSON {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        var bodyParts = [
            "refresh_token=\(rt.oauthEncoded)",
            "grant_type=refresh_token"
        ]

        if useBasicAuth {
            let credentials = "\(clientId):\(clientSecret)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        } else {
            bodyParts.append("client_id=\(clientId.oauthEncoded)")
            if !clientSecret.isEmpty {
                bodyParts.append("client_secret=\(clientSecret.oauthEncoded)")
            }
        }

        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["access_token"] as? String, !newToken.isEmpty else {
                return nil
            }

            let expiresIn = json["expires_in"] as? Int ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            d.set(newToken, forKey: "\(prefix).accessToken")
            d.set(expiry.timeIntervalSince1970, forKey: "\(prefix).tokenExpiry")

            // Some providers rotate refresh tokens
            if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
                d.set(newRefresh, forKey: "\(prefix).refreshToken")
            }

            return newToken
        } catch {
            return nil
        }
    }
}

// MARK: - URL Encoding Helper

private extension String {
    var oauthEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
