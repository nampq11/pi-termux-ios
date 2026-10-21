import Foundation
import Observation

// Native port of the web clients page: saved SSH targets and the device's
// ed25519 keypair. Key installs go through the password flow (POST
// /api/ssh-copy-id) because iOS has no PTY for interactive ssh-copy-id.

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

    // The ⇧key flow: confirm dialog, then up to three password attempts.
    public var copyIdHost: ClientHost?
    public var copyIdPhase: CopyIdPhase = .idle
    public var copyIdError: String?
    public var passwordRejected = false

    public enum CopyIdPhase: Equatable { case idle, confirm, password }

    private weak var api: BridgeAPI?
    private var copyIdAttempts = 0

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

    /// Adds a host and runs the web page's auto-flow: ensure the device key
    /// exists, then offer to install it on the new host.
    public func addHost(name: String, target: String) async -> Bool {
        guard let api else { return false }
        do {
            let res: [String: Any] = try await api.post("/api/clients", body: ["name": name, "target": target])
            guard res["ok"] as? Bool == true else { return false }
            message = "added"
            await loadAll()
            if !keyExists { await generateKey() }
            if let host = hosts.first(where: { $0.target == target }) {
                beginInstallKey(host)
            }
            return true
        } catch {
            message = "error: \(error.localizedDescription)"
            return false
        }
    }

    public func deleteHost(_ host: ClientHost) async {
        guard let api else { return }
        _ = try? await api.post("/api/clients", body: ["delete": host.name]) as [String: Any]
        await loadAll()
    }

    // MARK: - Key Install (the web authprompt.js flow)

    public func beginInstallKey(_ host: ClientHost) {
        copyIdHost = host
        copyIdPhase = .confirm
        copyIdAttempts = 0
        passwordRejected = false
    }

    public func confirmInstallKey() {
        copyIdPhase = .password
        passwordRejected = false
    }

    public func cancelInstallKey() {
        copyIdHost = nil
        copyIdPhase = .idle
        passwordRejected = false
    }

    /// One password attempt: success closes the flow, a rejected password
    /// keeps the sheet open for the next attempt (three total, like the web).
    public func submitPassword(_ password: String) async {
        guard let api, let host = copyIdHost else { return }
        copyIdAttempts += 1
        do {
            let res: [String: Any] = try await api.post("/api/ssh-copy-id", body: ["target": host.target, "password": password])
            if res["ok"] as? Bool == true {
                cancelInstallKey()
                message = "key installed on \(host.name)"
                return
            }
            let authFailed = res["authFailed"] as? Bool ?? false
            if authFailed && copyIdAttempts < 3 {
                passwordRejected = true
                return
            }
            cancelInstallKey()
            copyIdError = authFailed ? "password rejected" : (res["error"] as? String ?? "key installation failed")
        } catch {
            cancelInstallKey()
            copyIdError = error.localizedDescription
        }
    }
}
