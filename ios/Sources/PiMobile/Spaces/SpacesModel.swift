import Foundation
import Observation

// Native port of spaces.js: device pairing (prepare, enroll with QR content
// validated against the prepared identity) and space connection (dataHost),
// with every reply shown as pretty JSON like the web result pane. Status and
// error strings stay German like the web page (deliberate there).

@MainActor
@Observable
public final class SpacesModel {
    public var message = ""
    public var result: String?
    public var running = false

    private weak var api: BridgeAPI?

    public init() {}

    public func attach(_ api: BridgeAPI) {
        self.api = api
    }

    /// POST /api/spaces/<action>; on success pretty-prints the reply.
    @discardableResult
    public func call(_ action: String, body: [String: Any] = [:]) async -> [String: Any]? {
        guard let api else { return nil }
        running = true
        message = "Läuft …"
        defer { running = false }
        do {
            let reply: [String: Any] = try await api.post("/api/spaces/\(action)", body: body)
            if let err = reply["error"] as? String {
                message = err
                return nil
            }
            if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                result = text
            }
            message = "Ergebnis empfangen"
            return reply
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Enroll with a raw token, or with the enrollment QR's JSON content:
    /// its endpoint and space must match the prepared identity.
    public func enroll(_ raw: String) async {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var controlSpaceId: String?
        if value.hasPrefix("{") {
            let data = value.data(using: .utf8)
            let qr = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
            guard let qr, let token = qr["token"] as? String else {
                message = "Ungültiges QR-JSON"
                return
            }
            guard let status = await call("status") else { return }
            let profile = status["profile"] as? [String: Any]
            let qrSpace = qr["space"].map { String(describing: $0) }
            guard (qr["v"] as? Int) == 1,
                  qr["endpoint"] as? String == profile?["endpoint"] as? String,
                  profile?["controlSpaceId"] == nil || qrSpace == profile?["controlSpaceId"] as? String else {
                message = "QR-Endpunkt oder Control-Space passt nicht zur vorbereiteten Identität"
                return
            }
            value = token
            controlSpaceId = qrSpace
        }
        var body: [String: Any] = ["token": value]
        if let controlSpaceId { body["controlSpaceId"] = controlSpaceId }
        await call("enroll", body: body)
    }
}
