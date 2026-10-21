import Foundation
import Observation
import SwiftTerm

// One live SSH terminal: the /pty WebSocket plus the SwiftTerm view it feeds.
// The screen runs the auth pre-checks; this owns the byte stream, the
// \x01-prefixed resize control frames, and the connection state.

@MainActor
@Observable
public final class TerminalSession {
    public enum State: Equatable {
        case idle, connecting, open, closed(String?)
    }

    public let target: String
    public private(set) var state: State = .idle
    public var title: String?

    private let api: BridgeAPI
    private var ws: URLSessionWebSocketTask?
    private weak var terminal: SwiftTerm.TerminalView?
    private var cols = 80
    private var rows = 24

    public init(target: String, api: BridgeAPI) {
        self.target = target
        self.api = api
    }

    public func attach(_ terminal: SwiftTerm.TerminalView) {
        self.terminal = terminal
        cols = terminal.getTerminal().cols
        rows = terminal.getTerminal().rows
    }

    public func connect() {
        guard state == .idle || isClosed else { return }
        guard let url = api.webSocketURL(path: "pty", query: [
            URLQueryItem(name: "cols", value: String(cols)),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "ssh", value: target),
        ]) else {
            state = .closed("bridge not ready")
            return
        }
        state = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop(on: task)
        // The ping doubles as the handshake signal: once it comes back the
        // socket is open and outgoing keystrokes will not be dropped.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.ws === task, self.state == .connecting else { return }
                self.state = error == nil ? .open : .closed(error?.localizedDescription ?? "connection failed")
            }
        }
    }

    public func disconnect() {
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
    }

    /// Clears the screen for a fresh session (the web's term.reset()).
    public func terminalReset() {
        terminal?.getTerminal().resetToInitialState()
    }

    /// The terminal settled on a new grid size; remember it (it seeds the
    /// connect URL) and push it to the live pty as a control frame.
    public func setSize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if state == .open || state == .connecting {
            send(Data("\u{01}{\"resize\":{\"cols\":\(cols),\"rows\":\(rows)}}".utf8))
        }
    }

    public func send(_ data: Data) {
        guard state == .open || state == .connecting else { return }
        ws?.send(.data(data)) { [weak self] error in
            if let error {
                Task { @MainActor in self?.finish(error.localizedDescription) }
            }
        }
    }

    public func feedText(_ text: String) {
        feed(Array(text.utf8))
    }

    // MARK: - Stream

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.ws === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data): self.feed(Array(data))
                    case .string(let text): self.feed(Array(text.utf8))
                    @unknown default: break
                    }
                    self.receiveLoop(on: task)
                case .failure(let error):
                    self.finish(error.localizedDescription)
                }
            }
        }
    }

    private func feed(_ bytes: [UInt8]) {
        terminal?.feed(byteArray: bytes[...])
    }

    private func finish(_ reason: String) {
        state = .closed(reason)
        ws = nil
        feedText("\r\n\r\n[disconnected — tap ↻ to reconnect]\r\n")
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }
}
