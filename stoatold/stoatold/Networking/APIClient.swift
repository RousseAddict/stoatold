import Foundation

struct APIClient {

    static let defaultBaseURL = "https://stoat.chat/api"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "baseURL") ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "baseURL") }
    }

    static var sessionToken: String? {
        get { UserDefaults.standard.string(forKey: "sessionToken") }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: "sessionToken") }
            else                { UserDefaults.standard.removeObject(forKey: "sessionToken") }
        }
    }


    // Derive WebSocket URL from base API URL (mirrors React config.ts defaults)
    static var wsURL: String {
        var url = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        if url.hasSuffix("/api") { url = String(url.dropLast(4)) + "/events" }
        else                     { url += "/events" }
        return url
    }

    static var isLoggedIn: Bool { return sessionToken != nil }

    // MARK: - Auth

    // completion: (token?, errorMessage?)
    static func login(email: String, password: String,
                      completion: @escaping (String?, String?) -> Void) {
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["email": email, "password": password]) else {
            completion(nil, "Failed to encode request")
            return
        }
        HTTPClient.request("\(baseURL)/auth/session/login", method: "POST", body: body) { data, status, error in
            if let error = error { completion(nil, error.localizedDescription); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, "Invalid server response")
                return
            }
            if let token = json["token"] as? String {
                completion(token, nil)
            } else {
                let msg = (json["description"] as? String)
                       ?? (json["error"]       as? String)
                       ?? "Login failed (HTTP \(status))"
                completion(nil, msg)
            }
        }
    }

    // Validate saved token — mirrors React AuthContext startup check
    static func validateSession(completion: @escaping (Bool) -> Void) {
        guard let token = sessionToken else { completion(false); return }
        HTTPClient.request("\(baseURL)/users/@me",
                           headers: ["x-session-token": token]) { _, status, error in
            completion(error == nil && status == 200)
        }
    }

    // Server-side logout then clear local state — mirrors React apiLogout()
    static func logout(completion: (() -> Void)? = nil) {
        if let token = sessionToken {
            HTTPClient.request("\(baseURL)/auth/session/logout", method: "DELETE",
                               headers: ["x-session-token": token]) { _, _, _ in }
        }
        sessionToken = nil
        completion?()
    }

    // MARK: - Authenticated GET

    static func get(_ path: String, completion: @escaping (Any?, String?) -> Void) {
        guard let token = sessionToken else { completion(nil, "Not logged in"); return }
        HTTPClient.request("\(baseURL)\(path)",
                           headers: ["x-session-token": token]) { data, status, error in
            if let error = error { completion(nil, error.localizedDescription); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                completion(nil, "Invalid response (HTTP \(status))")
                return
            }
            completion(json, nil)
        }
    }
}
