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

    public func request(path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let baseURL else {
            throw NSError(domain: "Bridge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Bridge not ready"])
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "token", value: token)]
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

    public func get<T>(_ path: String) async throws -> T {
        try await send(try request(path: path, method: "GET"))
    }

    public func post<T>(_ path: String, body: [String: Any]) async throws -> T {
        try await send(try request(path: path, method: "POST", body: body))
    }

    private func send<T>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            // Routes report failures as {"error": ...}; surface that text, not the raw JSON.
            var str = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String {
                str = err
            }
            throw NSError(domain: "Bridge", code: code, userInfo: [NSLocalizedDescriptionKey: str])
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? T else {
            throw NSError(domain: "Bridge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        return result
    }
}
