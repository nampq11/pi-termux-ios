import AuthenticationServices
import Observation
import UIKit

// Ported from Terrarium (app/ios/Sources/Agent/AgentHost.swift):
// Manages sign-in prompts, OAuth device codes, and browser auth flows.

@MainActor
@Observable
public final class AgentHost: NSObject, ASWebAuthenticationPresentationContextProviding {

    public struct Option: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let detail: String?

        public init(id: String, label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    public struct Prompt: Identifiable, Equatable, Sendable {
        public let id: Int
        public let type: String
        public let message: String
        public let placeholder: String?
        public let options: [Option]

        public init(id: Int = 1, type: String = "secret", message: String, placeholder: String? = nil, options: [Option] = []) {
            self.id = id
            self.type = type
            self.message = message
            self.placeholder = placeholder
            self.options = options
        }
    }

    public struct DeviceCode: Equatable, Sendable {
        public let code: String
        public let uri: String

        public init(code: String, uri: String) {
            self.code = code
            self.uri = uri
        }
    }

    public var loginProvider: String?
    public var prompt: Prompt?
    public var deviceCode: DeviceCode?
    public var progress: [String] = []

    @ObservationIgnored private var promptReply: ((String?) -> Void)?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?

    public override init() {
        super.init()
    }

    public func beginLogin(_ provider: String, prompt: Prompt? = nil, onAnswer: ((String?) -> Void)? = nil) {
        loginProvider = provider
        self.prompt = prompt
        self.promptReply = onAnswer
        deviceCode = nil
        progress = []
    }

    public func endLogin() {
        answerPrompt(nil)
        closeAuthSession()
        loginProvider = nil
        deviceCode = nil
        prompt = nil
    }

    public func answerPrompt(_ answer: String?) {
        guard let reply = promptReply else { return }
        promptReply = nil
        prompt = nil
        reply(answer)
    }

    public func openAuthSession(_ url: URL, callbackScheme: String = "pimobile-auth") -> Bool {
        closeAuthSession()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] _, _ in
            Task { @MainActor in self?.authSession = nil }
        }
        session.presentationContextProvider = self
        authSession = session
        return session.start()
    }

    public func closeAuthSession() {
        authSession?.cancel()
        authSession = nil
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
