import Foundation
import Observation
import SwiftUI
import UIKit
import os

// AppModel ported and adapted from Terrarium (app/ios/Sources/Shell/AppModel.swift
// & AppModel+Agent.swift), driving AgentViews.swift over pi-mobile's local bridge.

public func displayName(_ path: String) -> String {
    path.isEmpty ? "Untitled" : (path.split(separator: "/").last.map(String.init) ?? path)
}

public func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

@MainActor
public func haptic() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
}

@MainActor
@Observable
public final class AppModel {

    private static let log = Logger(subsystem: "org.pimobile.app", category: "app-model")

    public var agent = AgentMirror()
    public var agentHost = AgentHost()
    public var agentModels: [AgentModelOption] = []
    public var agentAccounts: [AgentAccount] = []
    public var clients = ClientsModel()
    public var keyInstall = KeyInstallModel()
    public var remote = RemoteModel()
    public var spaces = SpacesModel()
    public var spaceCtl = SpaceCtlModel()

    public var agentListShown = false
    public var agentAccountsShown = false
    public var agentLoginError: String?
    public var activeSheet: String? = nil
    public var agentExpandEdits: Bool = false

    public var wide: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    public let api = BridgeAPI()

    @ObservationIgnored private var sseTask: Task<Void, Never>?
    @ObservationIgnored private var urlSession = URLSession(configuration: .default)
    @ObservationIgnored private var currentLiveItemId: String?
    @ObservationIgnored private var pendingUserText: String?

    public init() {}

    deinit {
        sseTask?.cancel()
    }

    // MARK: - Bridge Connection & Event Stream

    public func connect(url: URL) {
        api.configure(url: url)
        clients.attach(api)
        keyInstall.attach(api)
        remote.attach(api)
        remote.attach(keyInstall)
        spaces.attach(api)
        spaceCtl.attach(api)
        startEventStream()
        Task {
            await loadAgentAccounts()
            await loadAgentModels()
            await loadConversations()
            if self.agent.state.model == nil, let first = self.agentModels.first {
                self.agentSetModel(first)
            }
        }
    }

    public func disconnect() {
        sseTask?.cancel()
        sseTask = nil
    }

    private func startEventStream() {
        sseTask?.cancel()
        guard let baseURL = api.baseURL else { return }

        sseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    var comps = URLComponents(url: baseURL.appendingPathComponent("api/events"), resolvingAgainstBaseURL: false)
                    comps?.queryItems = [URLQueryItem(name: "token", value: self.api.token)]
                    guard let sseURL = comps?.url else { return }

                    var req = URLRequest(url: sseURL)
                    req.timeoutInterval = 600
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await self.urlSession.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw NSError(domain: "Bridge", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let raw = String(line.dropFirst(6))
                        self.handleRawEvent(raw)
                    }
                } catch {
                    if Task.isCancelled { break }
                    Self.log.error("SSE stream error: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    // MARK: - SSE Event Processing

    private func handleRawEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "bridge_snapshot":
            let convId = (json["sessionId"] as? String).flatMap(Int.init)
            let convName = json["sessionName"] as? String
            if let snap = json["snapshot"] as? [String: Any] {
                applySnapshot(snap, convId: convId, convName: convName)
            }

        case "run_start":
            agent.state.busy = true

        case "run_end":
            agent.state.busy = false
            currentLiveItemId = nil

        case "message_start":
            if let msg = json["message"] as? [String: Any], msg["role"] as? String == "assistant" {
                let id = "asst-\(UUID().uuidString)"
                currentLiveItemId = id
                let text = extractText(from: msg["content"])
                let item = AgentItem(id: id, kind: "assistant", text: text, streaming: true)
                agent.state.items.append(item)
            }

        case "message_update":
            guard let liveId = currentLiveItemId,
                  let idx = agent.state.items.firstIndex(where: { $0.id == liveId }) else { return }
            if let changes = json["changes"] as? [[String: Any]] {
                for change in changes {
                    let changeType = change["type"] as? String
                    if changeType == "text_delta", let delta = change["delta"] as? String {
                        agent.state.items[idx].text += delta
                    } else if changeType == "thinking_delta", let delta = change["delta"] as? String {
                        agent.state.items[idx].thinking = (agent.state.items[idx].thinking ?? "") + delta
                    } else if changeType == "message", let msg = change["message"] as? [String: Any] {
                        agent.state.items[idx].text = extractText(from: msg["content"])
                        if let th = extractThinking(from: msg["content"]) {
                            agent.state.items[idx].thinking = th
                        }
                    }
                }
            }

        case "message_end":
            if let liveId = currentLiveItemId,
               let idx = agent.state.items.firstIndex(where: { $0.id == liveId }) {
                agent.state.items.remove(at: idx)
            }
            currentLiveItemId = nil
            if let entry = json["entry"] as? [String: Any] {
                applyEntry(entry)
            }

        case "submission":
            if let rec = json["record"] as? [String: Any],
               let status = rec["status"] as? String,
               status == "unanswered" {
                let reason = rec["reason"] as? String ?? "unknown"
                let detail = rec["detail"] as? String ?? ""
                agent.state.busy = false
                if reason == "no_model" {
                    agent.state.error = "No model is configured. Please select a model or add an API key under Accounts."
                } else if !detail.isEmpty {
                    agent.state.error = detail
                } else {
                    agent.state.error = "Request unanswered: \(reason)"
                }
            }

        case "entry_appended":
            if let entry = json["entry"] as? [String: Any] {
                applyEntry(entry)
            }

        case "tool_execution_start":
            let callId = json["toolCallId"] as? String ?? UUID().uuidString
            let toolName = json["toolName"] as? String ?? "tool"
            let argsStr = stringify(json["args"])
            let item = AgentItem(
                id: "tool-\(callId)",
                kind: "tool",
                text: "",
                tool: toolName,
                summary: argsStr,
                status: "running"
            )
            agent.state.items.append(item)

        case "tool_execution_update":
            guard let callId = json["toolCallId"] as? String,
                  let idx = agent.state.items.firstIndex(where: { $0.id == "tool-\(callId)" }) else { return }
            if let outDict = json["output"] as? [String: Any] {
                if let setStr = outDict["set"] as? String {
                    agent.state.items[idx].output = setStr
                } else if let appendStr = outDict["append"] as? String {
                    agent.state.items[idx].output = (agent.state.items[idx].output ?? "") + appendStr
                }
            } else if let outStr = json["output"] as? String {
                agent.state.items[idx].output = outStr
            }

        case "tool_execution_end":
            guard let callId = json["toolCallId"] as? String,
                  let idx = agent.state.items.firstIndex(where: { $0.id == "tool-\(callId)" }) else { return }
            let isError = (json["entry"] as? [String: Any])?["isError"] as? Bool ?? false
            agent.state.items[idx].status = isError ? "error" : "done"

        case "agent_update":
            if let ag = json["agent"] as? [String: Any],
               let m = ag["model"] as? [String: Any],
               let p = m["provider"] as? String,
               let mid = m["modelId"] as? String {
                agent.state.model = AgentModelRef(provider: p, id: mid, name: "\(p): \(mid)")
                agent.state.signedIn = true
            }

        default:
            break
        }
    }

    private func applySnapshot(_ snap: [String: Any], convId: Int?, convName: String?) {
        agent.state.conversationId = convId
        agent.state.project = convName ?? "Main"
        agent.state.root = convName ?? "Main"
        agent.state.items = []
        currentLiveItemId = nil

        if let entries = snap["entries"] as? [[String: Any]] {
            for e in entries {
                applyEntry(e)
            }
        }

        if let gen = snap["generation"] as? [String: Any],
           let partial = gen["message"] as? [String: Any] {
            let id = "asst-gen-\(UUID().uuidString)"
            currentLiveItemId = id
            let text = extractText(from: partial["content"])
            let item = AgentItem(id: id, kind: "assistant", text: text, streaming: true)
            agent.state.items.append(item)
        }

        if let ag = snap["agent"] as? [String: Any],
           let m = ag["model"] as? [String: Any],
           let p = m["provider"] as? String,
           let mid = m["modelId"] as? String {
            agent.state.model = AgentModelRef(provider: p, id: mid, name: "\(p): \(mid)")
            agent.state.signedIn = true
        }

        agent.state.busy = (snap["run"] != nil)
    }

    private func applyEntry(_ entry: [String: Any]) {
        let entryId = String(describing: entry["id"] ?? UUID().uuidString)
        let kind = entry["kind"] as? String

        if kind == "pi.reset" {
            agent.state.items.append(AgentItem(id: "reset-\(entryId)", kind: "note", text: "— Context reset —"))
            return
        }
        if kind == "pi.compaction" {
            agent.state.items.append(AgentItem(id: "compact-\(entryId)", kind: "note", text: "— Earlier messages compacted —"))
            return
        }

        guard let models = entry["model"] as? [[String: Any]] else { return }

        for (mIdx, m) in models.enumerated() {
            let role = m["role"] as? String ?? ""
            let id = "entry-\(entryId)-\(mIdx)"

            switch role {
            case "user":
                let text = extractText(from: m["content"])
                if let pText = pendingUserText, pText == text {
                    pendingUserText = nil
                }
                if !agent.state.items.contains(where: { $0.id == id || ($0.kind == "user" && $0.text == text) }) {
                    agent.state.items.append(AgentItem(id: id, kind: "user", text: text))
                }

            case "assistant":
                let text = extractText(from: m["content"])
                let thinking = extractThinking(from: m["content"])
                let stopReason = m["stopReason"] as? String
                let errMsg = m["errorMessage"] as? String

                if !agent.state.items.contains(where: { $0.id == id }) {
                    agent.state.items.append(AgentItem(
                        id: id,
                        kind: "assistant",
                        text: text,
                        thinking: thinking,
                        streaming: false,
                        status: stopReason == "error" ? "error" : "done",
                        output: errMsg
                    ))
                }

            default:
                break
            }
        }
    }

    // MARK: - Agent Actions (API calls)

    public func agentSend(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Optimistically add to items
        pendingUserText = trimmed
        let tempId = "user-\(UUID().uuidString)"
        agent.state.items.append(AgentItem(id: tempId, kind: "user", text: trimmed))
        agent.state.busy = true

        Task {
            do {
                let res: [String: Any] = try await api.post("/api/prompt", body: [
                    "message": trimmed,
                    "requestId": UUID().uuidString
                ])
                if let err = res["error"] as? String {
                    agent.state.error = err
                    agent.state.busy = false
                }
            } catch {
                agent.state.error = error.localizedDescription
                agent.state.busy = false
            }
        }
    }

    public func agentStop() {
        haptic()
        agent.state.busy = false
        Task { _ = try? await api.post("/api/abort", body: [:]) as [String: Any] }
    }

    public func agentNewConversation() {
        Task {
            do {
                let res: [String: Any] = try await api.post("/api/sessions/new", body: [:])
                if let newId = (res["activeId"] as? String).flatMap(Int.init) {
                    agent.state.conversationId = newId
                }
                await loadConversations()
            } catch {
                Self.log.error("newConversation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func agentSwitch(_ id: Int) {
        Task {
            do {
                _ = try await api.post("/api/sessions/select", body: ["id": String(id)]) as [String: Any]
                agent.state.conversationId = id
                await loadConversations()
            } catch {
                Self.log.error("switch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func agentRename(_ id: Int, _ title: String) {
        Task {
            do {
                _ = try await api.post("/api/sessions/rename", body: ["id": String(id), "name": title]) as [String: Any]
                await loadConversations()
            } catch {
                Self.log.error("rename failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func agentArchive(_ id: Int, _ archived: Bool) {
        Task {
            do {
                _ = try await api.post("/api/sessions/delete", body: ["id": String(id)]) as [String: Any]
                await loadConversations()
            } catch {
                Self.log.error("archive/delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func agentSetModel(_ option: AgentModelOption) {
        UserDefaults.standard.set(["provider": option.provider, "modelId": option.model], forKey: "agent.model")
        Task {
            do {
                _ = try await api.post("/api/model", body: ["provider": option.provider, "modelId": option.model]) as [String: Any]
                agent.state.model = AgentModelRef(provider: option.provider, id: option.model, name: option.name)
            } catch {
                Self.log.error("setModel failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func loadConversations() async {
        do {
            let res: [String: Any] = try await api.get("/api/sessions")
            let activeId = (res["activeId"] as? String).flatMap(Int.init)
            if let list = res["sessions"] as? [[String: Any]] {
                agent.state.conversations = list.compactMap { d in
                    guard let idNum = d["id"], let idInt = Int(String(describing: idNum)) else { return nil }
                    let name = (d["name"] as? String) ?? "Session \(idInt)"
                    return AgentConversation(id: idInt, title: name)
                }
            }
            if let activeId { agent.state.conversationId = activeId }
        } catch {
            Self.log.error("loadConversations failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadAgentModels() async {
        do {
            let res: [String: Any] = try await api.get("/api/models")
            if let list = res["models"] as? [[String: Any]] {
                self.agentModels = list.compactMap { d in
                    guard let p = d["provider"] as? String, let m = d["modelId"] as? String else { return nil }
                    return AgentModelOption(provider: p, providerName: p.capitalized, model: m, name: "\(p): \(m)")
                }
            }
        } catch {
            Self.log.error("loadAgentModels failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadAgentAccounts() async {
        let defaultProviders = [
            ("zai", "Z.AI (Global / z.ai)", true),
            ("zai-coding-cn", "Z.AI (BigModel CN / bigmodel.cn)", true),
            ("anthropic", "Anthropic Claude", true),
            ("openai", "OpenAI", true),
            ("openrouter", "OpenRouter", false),
            ("google", "Google Gemini", false),
            ("deepseek", "DeepSeek", false),
            ("groq", "Groq", false),
            ("mistral", "Mistral", false),
            ("xai", "xAI (Grok)", false),
            ("minimax", "MiniMax", false)
        ]

        var savedKeys = Set<String>()
        do {
            let res: [String: Any] = try await api.get("/api/providers")
            if let list = res["providers"] as? [[String: Any]] {
                for p in list {
                    if let id = p["provider"] as? String { savedKeys.insert(id) }
                }
            }
        } catch {}

        if !savedKeys.isEmpty {
            agent.state.signedIn = true
        }

        agentAccounts = defaultProviders.map { id, name, featured in
            AgentAccount(
                id: id,
                name: name,
                featured: featured,
                apiKeyName: "\(name) API Key",
                signedIn: savedKeys.contains(id) ? "api_key" : nil
            )
        }
    }
    public func agentLogin(_ provider: String, _ type: String) async {
        agentLoginError = nil
        let prompt = AgentHost.Prompt(
            id: 1,
            type: "secret",
            message: "Enter your \(provider.capitalized) API Key:",
            placeholder: "sk-..."
        )
        agentHost.beginLogin(provider, prompt: prompt) { [weak self] answer in
            guard let self, let answer else { return }
            let cleanKey = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanKey.isEmpty else { return }
            Task {
                do {
                    _ = try await self.api.post("/api/auth", body: ["provider": provider, "key": cleanKey]) as [String: Any]
                    await self.loadAgentAccounts()
                    await self.loadAgentModels()
                    if let first = self.agentModels.first(where: { $0.provider == provider }) ?? self.agentModels.first {
                        self.agentSetModel(first)
                    }
                } catch {
                    self.agentLoginError = error.localizedDescription
                }
                self.agentHost.endLogin()
            }
        }
    }

    public func agentCancelLogin() {
        agentHost.endLogin()
    }

    public func agentLogout(_ provider: String) async {
        _ = try? await api.post("/api/auth", body: ["provider": provider, "delete": true]) as [String: Any]
        await loadAgentAccounts()
        await loadAgentModels()
    }

    public func agentSharingAllowed(_ provider: String) -> Bool {
        true
    }

    public func agentAllowSharing(_ provider: String) {}

    public func agentSetVisible(_ visible: Bool) {}

    public func openDocsLink(_ url: URL) -> Bool {
        UIApplication.shared.open(url)
        return true
    }

    public func openLocation(_ path: String, line: Int? = nil, pane: Int? = nil, keepConsole: Bool = true) async {}

    // MARK: - Content Helpers

    private func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
        return ""
    }

    private func extractThinking(from content: Any?) -> String? {
        guard let arr = content as? [[String: Any]] else { return nil }
        let thinking = arr.filter { ($0["type"] as? String) == "thinking" }
            .compactMap { $0["thinking"] as? String }
            .joined(separator: "\n")
        return thinking.isEmpty ? nil : thinking
    }

    private func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }
}
