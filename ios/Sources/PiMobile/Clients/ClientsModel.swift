import Foundation
import Observation

// Native port of the web clients page: saved SSH targets and the device's
// ed25519 keypair. Key installs live in KeyInstallModel, shared with the
// terminal's pre-connection check.

public struct ClientHost: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let target: String

    public init(name: String, target: String) {
        self.name = name
        self.target = target
    }
}

@MainActor
@Observable
public final class ClientsModel {
    public var hosts: [ClientHost] = []
    public var keyExists = false
    public var keyPubkey: String?
    public var message: String?

    private weak var api: BridgeAPI?

    public init() {}

    public func attach(_ api: BridgeAPI) {
        self.api = api
    }

    public func loadAll() async {
        guard let api else { return }
        do {
            let res: [String: Any] = try await api.get("/api/clients")
            if let list = res["clients"] as? [[String: Any]] {
                hosts = list.compactMap { d in
                    guard let name = d["name"] as? String, let target = d["target"] as? String else { return nil }
                    return ClientHost(name: name, target: target)
                }
            }
        } catch {
            message = error.localizedDescription
        }
        await loadKey()
    }

    public func loadKey() async {
        guard let api else { return }
        do {
            let res: [String: Any] = try await api.get("/api/sshkey")
            keyExists = res["exists"] as? Bool ?? false
            keyPubkey = res["pubkey"] as? String
        } catch {
            message = error.localizedDescription
        }
    }

    public func generateKey() async {
        guard let api else { return }
        message = "generating…"
        do {
            let res: [String: Any] = try await api.post("/api/sshkey", body: [:])
            message = res["ok"] as? Bool == true ? "key generated" : "error generating key"
        } catch {
            message = "error generating key"
        }
        await loadKey()
    }

    /// Adds a host; the caller runs the web page's auto-flow (offer the key
    /// install via KeyInstallModel) using the returned host.
    public func addHost(name: String, target: String) async -> ClientHost? {
        guard let api else { return nil }
        do {
            let res: [String: Any] = try await api.post("/api/clients", body: ["name": name, "target": target])
            guard res["ok"] as? Bool == true else { return nil }
            message = "added"
            await loadAll()
            if !keyExists { await generateKey() }
            return hosts.first(where: { $0.target == target })
        } catch {
            message = "error: \(error.localizedDescription)"
            return nil
        }
    }

    public func deleteHost(_ host: ClientHost) async {
        guard let api else { return }
        _ = try? await api.post("/api/clients", body: ["delete": host.name]) as [String: Any]
        await loadAll()
    }
}
