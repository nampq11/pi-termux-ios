import Foundation
import Observation

// Shared access to the in-process bridge: the base URL, the session token,
// and the JSON request/response handling every native screen uses. AppModel
// owns the one instance and configures it from the bridge URL; the paths
// mirror the web UI's constants.js.

@MainActor
@Observable
public final class BridgeAPI {
    public private(set) var baseURL: URL?
    public private(set) var token: String = ""

    @ObservationIgnored private var urlSession = URLSession(configuration: .default)

    public init() {}

    public func configure(url: URL) {
        let port = url.port ?? 41943
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = url.host ?? "127.0.0.1"
        comps.port = port
        guard let base = comps.url else { return }

        let queryToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value ?? ""

        self.baseURL = base
        self.token = queryToken
    }

    // MARK: - HTTP Helpers

    /// A ws(s):// URL for a bridge path (the /pty terminal stream); the
    /// session token is always appended.
    public func webSocketURL(path: String, query: [URLQueryItem] = []) -> URL? {
        guard let baseURL,
              var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.queryItems = query + [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    public func request(path: String, method: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL else {
            throw NSError(domain: "Bridge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Bridge not ready"])
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = query + [URLQueryItem(name: "token", value: token)]
        guard let url = comps?.url else {
            throw NSError(domain: "Bridge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    public func get<T>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(try request(path: path, method: "GET", query: query))
    }

    public func post<T>(_ path: String, body: [String: Any]) async throws -> T {
        try await send(try request(path: path, method: "POST", body: body))
    }

    /// POST with the web client's retry semantics (api.js postJson): retries
    /// 503 reconnecting responses and network failures with backoff. Safe for
    /// calls that carry a requestId or are idempotent.
    public func postWithRetry<T>(_ path: String, body: [String: Any], retries: Int) async throws -> T {
        var attempt = 0
        while true {
            let req = try request(path: path, method: "POST", body: body)
            do {
                return try await send(req)
            } catch let error as NSError {
                guard attempt < retries else { throw error }
                if error.domain == "Bridge" {
                    // An HTTP error: retry only the tunnel's 503 reconnecting.
                    let reconnecting = (error.userInfo["body"] as? [String: Any])?["reconnecting"] as? Bool == true
                    guard error.code == 503, reconnecting else { throw error }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                } else {
                    // A network failure.
                    try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
                }
                attempt += 1
            }
        }
    }

    private func send<T>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            // Routes report failures as {"error": ...}; surface that text, not
            // the raw JSON, and keep the parsed body for retry decisions.
            var str = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
            var info: [String: Any] = [NSLocalizedDescriptionKey: str]
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = obj["error"] as? String { str = err }
                info[NSLocalizedDescriptionKey] = str
                info["body"] = obj
            }
            throw NSError(domain: "Bridge", code: code, userInfo: info)
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? T else {
            throw NSError(domain: "Bridge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        return result
    }
}
