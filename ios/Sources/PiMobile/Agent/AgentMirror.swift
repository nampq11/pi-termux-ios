import Foundation
import Observation

// Ported from Terrarium (app/ios/Sources/Shell/AgentMirror.swift):
// A compact transcript of messages, tool calls, and conversations.

public struct AgentItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public let kind: String // user, assistant, tool, error, note, context
    public var text: String
    public var ide: Bool?
    public var thinking: String?
    public var streaming: Bool?
    public var tool: String?
    public var summary: String?
    public var status: String? // pending, running, done, error
    public var output: String?
    public var diff: String?
    public var path: String?
    public var line: Int?
    public var images: Int?

    public init(
        id: String,
        kind: String,
        text: String,
        ide: Bool? = nil,
        thinking: String? = nil,
        streaming: Bool? = nil,
        tool: String? = nil,
        summary: String? = nil,
        status: String? = nil,
        output: String? = nil,
        diff: String? = nil,
        path: String? = nil,
        line: Int? = nil,
        images: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.ide = ide
        self.thinking = thinking
        self.streaming = streaming
        self.tool = tool
        self.summary = summary
        self.status = status
        self.output = output
        self.diff = diff
        self.path = path
        self.line = line
        self.images = images
    }
}

public struct AgentModelRef: Codable, Equatable, Sendable {
    public let provider: String
    public let id: String
    public let name: String

    public init(provider: String, id: String, name: String) {
        self.provider = provider
        self.id = id
        self.name = name
    }
}

/// One of the conversations (the engine's index).
public struct AgentConversation: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String?
    public let project: String
    public let updated: Double
    public let archived: Bool
    public let running: Bool
    public let unread: Bool

    public var displayTitle: String { title ?? "New Conversation" }

    public init(
        id: Int,
        title: String?,
        project: String = "",
        updated: Double = Date().timeIntervalSince1970 * 1000,
        archived: Bool = false,
        running: Bool = false,
        unread: Bool = false
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.updated = updated
        self.archived = archived
        self.running = running
        self.unread = unread
    }
}

public struct AgentState: Codable, Equatable, Sendable {
    public var project: String?
    public var root: String?
    public var conversationId: Int?
    public var conversations: [AgentConversation]?
    public var items: [AgentItem]
    public var busy: Bool
    public var status: String?
    public var error: String?
    public var model: AgentModelRef?
    public var signedIn: Bool

    public static let empty = AgentState(
        project: nil, root: nil, conversationId: nil, conversations: nil,
        items: [], busy: false, status: nil, error: nil, model: nil, signedIn: false
    )

    public var current: AgentConversation? { conversations?.first { $0.id == conversationId } }
    public var othersActive: Bool {
        conversations?.contains { $0.id != conversationId && ($0.running || $0.unread) } ?? false
    }

    public init(
        project: String? = nil,
        root: String? = nil,
        conversationId: Int? = nil,
        conversations: [AgentConversation]? = nil,
        items: [AgentItem] = [],
        busy: Bool = false,
        status: String? = nil,
        error: String? = nil,
        model: AgentModelRef? = nil,
        signedIn: Bool = false
    ) {
        self.project = project
        self.root = root
        self.conversationId = conversationId
        self.conversations = conversations
        self.items = items
        self.busy = busy
        self.status = status
        self.error = error
        self.model = model
        self.signedIn = signedIn
    }
}

public struct AgentAccount: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let featured: Bool
    public let oauthName: String?
    public let oauthLabel: String?
    public let subscription: Bool
    public let apiKeyName: String?
    public var signedIn: String? // "oauth", "api_key"

    public init(
        id: String,
        name: String,
        featured: Bool = false,
        oauthName: String? = nil,
        oauthLabel: String? = nil,
        subscription: Bool = false,
        apiKeyName: String? = nil,
        signedIn: String? = nil
    ) {
        self.id = id
        self.name = name
        self.featured = featured
        self.oauthName = oauthName
        self.oauthLabel = oauthLabel
        self.subscription = subscription
        self.apiKeyName = apiKeyName
        self.signedIn = signedIn
    }
}

public struct AgentModelOption: Identifiable, Hashable, Sendable {
    public var id: String { "\(provider)/\(model)" }
    public let provider: String
    public let providerName: String
    public let model: String
    public let name: String

    public init(provider: String, providerName: String, model: String, name: String) {
        self.provider = provider
        self.providerName = providerName
        self.model = model
        self.name = name
    }
}

@MainActor
@Observable
public final class AgentMirror {
    public var state = AgentState.empty

    public init() {}

    public func apply(_ next: AgentState) {
        var mutableNext = next
        var seen = Set<String>()
        for i in mutableNext.items.indices where !seen.insert(mutableNext.items[i].id).inserted {
            mutableNext.items[i].id += "#\(i)"
            seen.insert(mutableNext.items[i].id)
        }
        if mutableNext != state { state = mutableNext }
    }

    public func apply(_ json: String) {
        guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(AgentState.self, from: data) else { return }
        apply(next)
    }
}
