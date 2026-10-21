import SwiftUI
import SwiftTerm
import UIKit

// Native port of terminal.html's ssh mode: before connecting, the same
// pre-checks as the web page (auth-status → trust the fingerprint → copy
// auth.json / install the device key), then the /pty stream rendered by
// SwiftTerm. The local pi CLI cannot run on iOS, so every terminal here is
// over ssh.

struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let target: String

    enum Gate: Equatable {
        case checking, trust, copyAuth, installKey, ready
    }

    @State private var gate: Gate = .checking
    @State private var fingerprint = ""
    @State private var session: TerminalSession?

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                TerminalCanvas(session: session)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session?.title ?? target)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reconnect")
            }
        }
        .task {
            session = TerminalSession(target: target, api: model.api)
            await runPrechecks()
        }
        .onDisappear { session?.disconnect() }
        .onChange(of: gate) { _, new in
            if new == .ready { session?.connect() }
        }
        // The shared key-install flow (dialog hosted by MainTabView) finishes
        // here: report the outcome like the web page, then connect regardless.
        .onChange(of: model.keyInstall.running) { wasRunning, running in
            if wasRunning && !running && gate == .installKey {
                session?.feedText(model.keyInstall.installed
                    ? "key installed.\r\n"
                    : "key not installed; use the key button on the Clients page and retry.\r\n")
                gate = .ready
            }
        }
        .alert("Trust \(target)?", isPresented: Binding(
            get: { gate == .trust },
            set: { if !$0, gate == .trust { gate = .ready } } // untrusted: skip ahead, ssh will fail on its own
        )) {
            Button("Trust") { Task { await trustHost() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Host fingerprint:\n\(fingerprint)")
        }
        .alert("Copy credentials to \(target)?", isPresented: Binding(
            get: { gate == .copyAuth },
            set: { if !$0, gate == .copyAuth { gate = .ready } }
        )) {
            Button("Copy") { Task { await copyAuth() } }
            Button("Skip", role: .cancel) {}
        } message: {
            Text("Copies this device's auth.json (model API keys) so the agent works over ssh.")
        }
    }

    // MARK: - Pre-connection checks (the web terminal.js start() chain)

    private func runPrechecks() async {
        guard let session else { return }
        do {
            let st: [String: Any] = try await model.api.post("/api/remote/auth-status", body: ["target": target])
            if st["loginFailed"] as? Bool == true {
                gate = .installKey
                model.keyInstall.begin(target: target)
                return
            }
            if let err = st["error"] as? String {
                session.feedText("[auth check failed: \(err)]\r\n")
                gate = .ready
                return
            }
            if st["needsAuth"] as? Bool == true {
                let trusted = st["trusted"] as? Bool ?? false
                if !trusted, let fp = st["fingerprint"] as? String {
                    fingerprint = fp
                    gate = .trust
                    return
                }
                gate = trusted ? .copyAuth : .ready
                return
            }
            gate = .ready
        } catch {
            session.feedText("[auth check failed: \(error.localizedDescription)]\r\n")
            gate = .ready
        }
    }

    private func trustHost() async {
        guard let session else { return }
        do {
            let r: [String: Any] = try await model.api.post("/api/remote/trust-host", body: ["target": target, "fingerprint": fingerprint])
            if r["ok"] as? Bool == true {
                gate = .copyAuth
            } else {
                session.feedText("[fingerprint confirmation failed: \(r["error"] as? String ?? "unknown error")]\r\n")
                gate = .ready
            }
        } catch {
            session.feedText("[fingerprint confirmation failed: \(error.localizedDescription)]\r\n")
            gate = .ready
        }
    }

    private func copyAuth() async {
        guard let session else { return }
        do {
            let r: [String: Any] = try await model.api.post("/api/remote/copy-auth", body: ["target": target])
            session.feedText(r["ok"] as? Bool == true ? "auth.json copied.\r\n" : "[copy failed: \(r["error"] as? String ?? "unknown error")]\r\n")
        } catch {
            session.feedText("[copy failed: \(error.localizedDescription)]\r\n")
        }
        gate = .ready
    }

    private func reconnect() {
        guard let session else { return }
        session.disconnect()
        session.terminalReset()
        session.connect()
    }
}

/// SwiftTerm's UIKit TerminalView bridged into SwiftUI; the coordinator wires
/// its delegate callbacks into the session.
private struct TerminalCanvas: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.terminalDelegate = context.coordinator
        session.attach(view)
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    // SwiftTerm's delegate protocol predates concurrency annotations; it is
    // called from the view's layout/keyboard/feed paths, all on the main
    // thread, so the coordinator is @MainActor via a preconformance.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: TerminalSession
        init(session: TerminalSession) { self.session = session }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // Only remember the grid: the pre-check gate (above) is what starts
            // the stream. Auto-connecting here would race the trust/copy-auth/
            // install-key decisions and connect regardless of them.
            session.setSize(cols: newCols, rows: newRows)
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session.send(Data(data))
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            session.title = title
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            UIApplication.shared.open(url)
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
