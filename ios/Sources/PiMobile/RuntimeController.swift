import Foundation
import os

/// Drives the boot sequence and publishes bridge state to the UI:
/// install payload → start Node engine → wait for the port/token handshake →
/// hand the WebView `http://127.0.0.1:<port>/?token=<token>`.
///
/// The same handshake files are used as on Android
/// ($HOME/.pi-mobile/port and token), written by server.mjs. A `fatal` file
/// next to them reports boot failures that must not exit the process on iOS
/// (the engine cannot be restarted, and process.exit would kill the app).
@MainActor
final class RuntimeController: ObservableObject {

    private static let log = Logger(subsystem: "org.pimobile.app", category: "controller")

    enum Phase: Equatable {
        case preparing
        case starting
        case ready(URL)
        case failed(String)
    }

    @Published var phase: Phase = .preparing

    private var booting = false
    private var reloadAttempts = 0
    /// Loopback-only, chosen once so the bridge stays reachable for USB
    /// debugging (`iproxy 41943:41943` + curl from the host) — the port file
    /// handshake stays identical to Android regardless.
    static let bridgePort = 41_943

    private var root: URL { RuntimeInstaller.rootDirectory() }
    private var stateDir: URL { root.appendingPathComponent("home/.pi-mobile", isDirectory: true) }

    func boot() {
        guard !booting else { return }
        booting = true
        phase = .preparing

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runBoot()
        }
    }

    /// A provisional navigation failure usually means the bridge restarted on
    /// a new port (or the phone woke up while the engine was suspended):
    /// re-run the handshake and reload when the URL changed.
    func bridgeLoadFailed() {
        guard case .ready = phase, reloadAttempts < 5 else { return }
        reloadAttempts += 1
        Task.detached(priority: .utility) { [weak self] in
            await self?.awaitBridge(maxSeconds: 120) { _ in }
        }
    }

    private func runBoot() async {
        do {
            try RuntimeInstaller.installIfNeeded()
        } catch {
            Self.log.error("boot: install failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed("runtime install failed: \(error.localizedDescription)")
            return
        }

        // a stale port file would make the UI load a dead bridge address
        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("port"))
        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("fatal"))

        phase = .starting
        Self.log.info("boot: starting node engine")
        NodeEngine.launch(
            script: root.appendingPathComponent("runtime/server.mjs").path,
            environment: environment())

        let ready = await awaitBridge(maxSeconds: 600) { [weak self] url in
            Task { @MainActor in self?.phase = .ready(url) }
        }
        if !ready {
            if case .failed = phase {} else {
                Self.log.error("boot: bridge never came up")
                phase = .failed("runtime failed to start — relaunch the app")
            }
        }
    }

    /// Environment for the bridge (fixed loopback port, in-process engine).
    private func environment() -> [String: String] {
        [
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PI_WORKDIR": root.appendingPathComponent("work").path,
            "PI_PORT": String(Self.bridgePort),
            "PI_PLATFORM": "ios",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
        ]
    }

    /// Polls the handshake files; returns the bridge URL once, or nil on
    /// timeout / fatal boot error.
    private func awaitBridge(maxSeconds: Int, onReady: @escaping (URL) -> Void) async -> Bool {
        let portFile = stateDir.appendingPathComponent("port")
        let tokenFile = stateDir.appendingPathComponent("token")
        let fatalFile = stateDir.appendingPathComponent("fatal")
        for _ in 0..<(maxSeconds * 2) {
            if let fatal = try? String(contentsOf: fatalFile, encoding: .utf8), !fatal.isEmpty {
                let message = fatal.trimmingCharacters(in: .whitespacesAndNewlines)
                Self.log.error("bridge: fatal boot file: \(message, privacy: .public)")
                Task { @MainActor in self.phase = .failed("runtime error: \(message)") }
                return false
            }
            if let port = try? String(contentsOf: portFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty,
               let token = try? String(contentsOf: tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                var components = URLComponents()
                components.scheme = "http"
                components.host = "127.0.0.1"
                components.port = Int(port)
                components.queryItems = [URLQueryItem(name: "token", value: token)]
                if let url = components.url {
                    reloadAttempts = 0
                    Self.log.info("bridge: handshake complete on port \(port, privacy: .public)")
                    onReady(url)
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
