import Foundation
import Observation

// The ssh-copy-id password flow (the web authprompt.js installKeyWithPassword):
// confirm, then up to three password attempts against POST /api/ssh-copy-id.
// iOS has no PTY for the interactive binary, so this is the only path. Shared
// by the Clients screen and the terminal's pre-connection check; the dialogs
// are hosted once, at the tab shell level.

@MainActor
@Observable
public final class KeyInstallModel {
    public enum Phase: Equatable { case idle, confirm, password }

    public var target: String?
    public var phase: Phase = .idle
    public var passwordRejected = false
    public var error: String?
    /// Outcome of the last completed flow, shown by whichever screen began it.
    public var notice: String?
    public private(set) var running = false

    public private(set) var installed = false
    private weak var api: BridgeAPI?
    private var attempts = 0
    @ObservationIgnored private var onFinished: (@MainActor (Bool) -> Void)?

    public init() {}

    public func attach(_ api: BridgeAPI) {
        self.api = api
    }

    /// `onFinished` reports whether the key was installed once the flow ends
    /// (by success, failure, or the user cancelling); the remote connect loop
    /// uses it to retry the connect after an install.
    public func begin(target: String, onFinished: (@MainActor (Bool) -> Void)? = nil) {
        self.target = target
        phase = .confirm
        attempts = 0
        passwordRejected = false
        error = nil
        notice = nil
        installed = false
        running = true
        self.onFinished = onFinished
    }

    public func confirm() {
        guard running else { return }
        phase = .password
        passwordRejected = false
    }

    public func cancel() {
        finish(installed: false)
    }

    private func finish(installed: Bool) {
        guard running else { return }
        if installed {
            self.installed = true
            notice = "key installed on \(target ?? "")"
        }
        target = nil
        phase = .idle
        passwordRejected = false
        running = false
        let callback = onFinished
        onFinished = nil
        callback?(installed)
    }

    /// One password attempt: success closes the flow, a rejected password
    /// keeps the sheet open for the next attempt (three total, like the web).
    public func submit(password: String) async {
        guard let api, let target else { return }
        attempts += 1
        do {
            let res: [String: Any] = try await api.post("/api/ssh-copy-id", body: ["target": target, "password": password])
            if res["ok"] as? Bool == true {
                finish(installed: true)
                return
            }
            let authFailed = res["authFailed"] as? Bool ?? false
            if authFailed && attempts < 3 {
                passwordRejected = true
                return
            }
            error = authFailed ? "password rejected" : (res["error"] as? String ?? "key installation failed")
            notice = "key not installed on \(target)"
            finish(installed: false)
        } catch {
            self.error = error.localizedDescription
            notice = "key not installed on \(target)"
            finish(installed: false)
        }
    }
}
