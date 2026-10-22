import Foundation
import Observation

// Native port of remote.js + transcript.js: connect to a pi on another
// machine through the bridge's ssh tunnel, provision pi-serverd, attach to a
// durable session, and mirror its transcript through the history + events
// contract (epoch/cursor positions, reset → reload).

public struct RemoteModelOption: Identifiable, Hashable, Sendable {
    public var id: String { "\(provider)/\(modelId)" }
    public let provider: String
    public let modelId: String

    public init(provider: String, modelId: String) {
        self.provider = provider
        self.modelId = modelId
    }
}

public struct RemoteSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let cwd: String?

    public init(id: String, name: String? = nil, cwd: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
    }

    public var label: String {
        let base = name ?? id
        return cwd.map { "\(base) (\($0))" } ?? base
    }
}

public struct RemoteItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case user, pendingUser, failedUser, assistant, liveAssistant, tool, sys }

    public let id: String
    public var kind: Kind
    public var text: String
    public var output: String?
    public var isError = false

    public init(id: String, kind: Kind, text: String, output: String? = nil, isError: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.output = output
        self.isError = isError
    }
}

@MainActor
@Observable
public final class RemoteModel {

    /// A question the connect loop is waiting on (alerts in the view).
    public enum Dialog: Equatable {
        case trust(String)
        case copyAuth
        case serverUpdate(installed: String, available: String)
    }

    public var items: [RemoteItem] = []
    public var sessions: [RemoteSession] = []
    public var attachedId: String?
    public var models: [RemoteModelOption] = []
    public var activeModel: RemoteModelOption?
    public var busy = false
    public var usage = ""
    public var draft = "" // composer text; model-level so env switches keep it
    public var connected = false
    public var connecting = false
    /// Host of the live connection; nil whenever `connected` is false. Lets
    /// environment switches keep a live session instead of reconnecting.
    public private(set) var connectedTarget: String?
    /// Host an in-flight connect is establishing; nil whenever `connecting`
    /// is false. Same job as connectedTarget for the handshake window.
    public private(set) var connectingTarget: String?
    public var link = "disconnected"
    public var dialog: Dialog?
    public var connectError: String?

    private weak var api: BridgeAPI?

    // transcript bookkeeping (the Transcript.js port's sets/maps)
    private var seen = Set<String>()
    private var pending: [(text: String, itemId: String)] = []
    private var tools: [String: String] = [:] // toolCallId -> item id
    private var liveId: String?
    private var pos: (epoch: String?, cursor: Int) = (nil, -1)
    private var pollGeneration = 0
    private var connectGeneration = 0
    private var provisionTask: Task<Void, Never>?
    private var dialogContinuation: CheckedContinuation<Bool, Never>?

    public init() {}

    public func attach(_ api: BridgeAPI) {
        self.api = api
    }

    // MARK: - Transcript (Transcript.js port)

    private func sys(_ text: String) {
        items.append(RemoteItem(id: "sys-\(UUID().uuidString)", kind: .sys, text: text))
    }

    public func clear() {
        items = []
        seen = []
        pending = []
        tools = [:]
        liveId = nil
    }

    @discardableResult
    public func addPendingUser(_ text: String) -> String {
        let id = "pending-\(UUID().uuidString)"
        items.append(RemoteItem(id: id, kind: .pendingUser, text: text))
        pending.append((text, id))
        return id
    }

    public func failPending(_ id: String, error: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].kind = .failedUser }
        pending.removeAll { $0.itemId == id }
        sys("error: \(error)")
    }

    private static func messageText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return "" }
        return arr.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private func renderEntry(_ entry: [String: Any]) {
        let entryKey: String? = entry["id"].map { String(describing: $0) }
        if let entryKey {
            if seen.contains(entryKey) { return }
            seen.insert(entryKey)
        }
        let kind = entry["kind"] as? String
        if kind == "pi.reset" { sys("— context reset —"); return }
        if kind == "pi.compaction" { sys("— earlier messages compacted —"); return }

        guard let messages = entry["model"] as? [[String: Any]] else { return }
        for (mIdx, m) in messages.enumerated() {
            let role = m["role"] as? String ?? ""
            let base = "entry-\(entryKey ?? UUID().uuidString)-\(mIdx)"

            if role == "user" {
                let text = Self.messageText(m["content"])
                if let i = pending.firstIndex(where: { $0.text == text }) {
                    let itemId = pending[i].itemId
                    if let idx = items.firstIndex(where: { $0.id == itemId }) { items[idx].kind = .user }
                    pending.remove(at: i)
                } else if !text.isEmpty {
                    items.append(RemoteItem(id: "\(base)-u", kind: .user, text: text))
                }

            } else if role == "assistant" {
                let text = Self.messageText(m["content"])
                if !text.isEmpty {
                    items.append(RemoteItem(id: "\(base)-a", kind: .assistant, text: text))
                }
                if let content = m["content"] as? [[String: Any]] {
                    for c in content where (c["type"] as? String) == "toolCall" {
                        toolStart(callId: c["id"], name: c["name"], args: c["arguments"])
                    }
                }
                if m["stopReason"] as? String == "aborted" { sys("(interrupted)") }
                if m["stopReason"] as? String == "error", let msg = m["errorMessage"] as? String {
                    sys("error: \(msg)")
                }

            } else if role == "toolResult" {
                let callKey = m["toolCallId"].map { String(describing: $0) }
                let itemId = callKey.flatMap { tools[$0] }
                if let itemId, let idx = items.firstIndex(where: { $0.id == itemId }) {
                    markSubagent(itemId: itemId, details: m["details"])
                    items[idx].isError = (m["isError"] as? Bool ?? false)
                } else {
                    items.append(RemoteItem(id: "\(base)-tr", kind: .tool,
                                            text: "⚙ \(m["toolName"] as? String ?? "tool")",
                                            isError: m["isError"] as? Bool ?? false))
                }
            }
        }
    }

    private func toolStart(callId: Any?, name: Any?, args: Any?) {
        let key = callId.map { String(describing: $0) }
        if let key, tools[key] != nil { return }
        let brief = Self.toolBrief(args)
        let display = "⚙ \(name as? String ?? "tool")\(brief.isEmpty ? "" : "  \(brief)")"
        let itemId = "tool-\(key ?? UUID().uuidString)"
        items.append(RemoteItem(id: itemId, kind: .tool, text: display))
        if let key { tools[key] = itemId }
    }

    /// The one-line argument summary from the web toolStart.
    private static func toolBrief(_ args: Any?) -> String {
        guard let dict = args as? [String: Any] else { return "" }
        for k in ["command", "path", "pattern", "task"] {
            if let v = dict[k] { return String(describing: v).prefix(200).description }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return String(str.prefix(80))
        }
        return ""
    }

    private func markSubagent(itemId: String, details: Any?) {
        guard let details = details as? [String: Any],
              let child = details["conversationId"] else { return }
        if let idx = items.firstIndex(where: { $0.id == itemId }),
           !items[idx].text.contains("→ subagent") {
            items[idx].text += "  → subagent #\(child)"
        }
    }

    /// watchEvents snapshot (also the lag `snapshot` event).
    public func renderSnapshot(_ snap: [String: Any]) {
        clear()
        for e in snap["entries"] as? [[String: Any]] ?? [] { renderEntry(e) }
        if let gen = snap["generation"] as? [String: Any],
           let partial = gen["message"] as? [String: Any] {
            startLive(Self.messageText(partial["content"]))
        }
        for t in snap["tools"] as? [[String: Any]] ?? [] {
            guard let callId = t["callId"].map({ String(describing: $0) }),
                  tools[callId] == nil, (t["status"] as? String) != "done" else { continue }
            toolStart(callId: callId, name: t["name"], args: nil)
            guard let itemId = tools[callId] else { continue }
            if let output = t["output"] as? String { setToolOutput(itemId: itemId, output: output) }
            markSubagent(itemId: itemId, details: t["details"])
        }
        if let agent = snap["agent"] as? [String: Any] { setActiveModel(agent["model"]) }
        if let usage = snap["usage"] { self.usage = Self.usageText(usage) }
        busy = snap["run"] != nil
    }

    private func startLive(_ text: String) {
        let id = "live-\(UUID().uuidString)"
        items.append(RemoteItem(id: id, kind: .liveAssistant, text: text))
        liveId = id
    }

    private func endLive() {
        if let liveId, let idx = items.firstIndex(where: { $0.id == liveId }) {
            items.remove(at: idx)
        }
        liveId = nil
    }

    private func setToolOutput(itemId: String, output: String) {
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx].output = output
        }
    }

    public func handleEvent(_ ev: [String: Any]) {
        switch ev["type"] as? String ?? "" {
        case "snapshot": renderSnapshot(ev)
        case "run_start": busy = true
        case "run_end": endLive(); busy = false
        case "message_start":
            if (ev["message"] as? [String: Any])?["role"] as? String == "assistant" {
                endLive()
                startLive(Self.messageText((ev["message"] as? [String: Any])?["content"]))
            }
        case "message_update":
            if liveId == nil { startLive("") }
            if let idx = liveId.flatMap({ liveId in items.firstIndex(where: { $0.id == liveId }) }) {
                for c in ev["changes"] as? [[String: Any]] ?? [] {
                    if (c["type"] as? String) == "text_delta", let delta = c["delta"] as? String {
                        items[idx].text += delta
                    } else if (c["type"] as? String) == "message" {
                        items[idx].text = Self.messageText(c["message"])
                    }
                }
            }
        case "message_end":
            let isAssistant = ((ev["entry"] as? [String: Any])?["model"] as? [[String: Any]])?.first?["role"] as? String == "assistant"
            if isAssistant { endLive() }
            if let entry = ev["entry"] as? [String: Any] { renderEntry(entry) }
        case "entry_appended":
            if let entry = ev["entry"] as? [String: Any] { renderEntry(entry) }
        case "tool_execution_start":
            toolStart(callId: ev["toolCallId"], name: ev["toolName"], args: ev["args"])
        case "tool_execution_update":
            guard let key = ev["toolCallId"].map({ String(describing: $0) }),
                  let itemId = tools[key] else { break }
            if let out = ev["output"] as? [String: Any] {
                if let set = out["set"] as? String {
                    setToolOutput(itemId: itemId, output: set)
                } else {
                    var output = items.first(where: { $0.id == itemId })?.output ?? ""
                    if let trim = out["trimStart"] as? Int { output = String(output.dropFirst(trim)) }
                    if let append = out["append"] as? String { output += append }
                    setToolOutput(itemId: itemId, output: output)
                }
            }
            markSubagent(itemId: itemId, details: ev["details"])
        case "tool_execution_end":
            let entry = ev["entry"] as? [String: Any]
            let failed = entry == nil || ((entry?["model"] as? [[String: Any]])?.first?["isError"] as? Bool ?? false)
            if let key = ev["toolCallId"].map({ String(describing: $0) }),
               let itemId = tools[key], let idx = items.firstIndex(where: { $0.id == itemId }) {
                items[idx].isError = failed
            }
            // The tool already rendered live; skip its committed entry later.
            if let entry, let id = entry["id"] { seen.insert(String(describing: id)) }
        case "agent_changed": setActiveModel((ev["agent"] as? [String: Any])?["model"])
        case "usage_changed": usage = Self.usageText(ev["usage"])
        case "compaction_start": sys("compacting…")
        case "compaction_end": sys("compaction finished")
        case "auto_retry_start": sys("retry \(ev["attempt"] ?? ""): \(ev["errorMessage"] as? String ?? "")")
        case "task_failed": sys("error (\(ev["kind"] ?? "")): \(ev["message"] ?? "")")
        case "submission":
            if let record = ev["record"] as? [String: Any], record["status"] as? String == "unanswered" {
                let reason = (record["reason"] as? String) ?? (record["reason"] as? [String: Any])?["type"] as? String ?? "failed"
                sys("not answered: \(reason)")
            }
        default:
            break
        }
    }

    private func setActiveModel(_ model: Any?) {
        guard let m = model as? [String: Any],
              let p = m["provider"] as? String, let id = m["modelId"] as? String else { return }
        activeModel = RemoteModelOption(provider: p, modelId: id)
    }

    private static func usageText(_ usage: Any?) -> String {
        guard let u = usage as? [String: Any], let models = u["models"] as? [String: Any] else { return "" }
        var tokens = 0
        var cost = 0.0
        for v in models.values {
            guard let m = v as? [String: Any] else { continue }
            tokens += (m["totalTokens"] as? Int) ?? 0
            if let c = m["cost"] as? [String: Any] { cost += (c["total"] as? Double) ?? 0 }
        }
        guard tokens > 0 else { return "" }
        return cost != 0 ? "\(tokens.formatted()) tok · $\(String(format: "%.3f", cost))" : "\(tokens.formatted()) tok"
    }

    // MARK: - Host connect flow (remote.js connectHost)

    public func resetUi() {
        pollGeneration += 1
        attachedId = nil
        link = "disconnected"
        connected = false
        connectedTarget = nil
        clear()
        sessions = []
        models = []
        activeModel = nil
        usage = ""
        busy = false
    }

    public func disconnectHost() async {
        connectGeneration += 1
        connecting = false
        connectingTarget = nil
        cancelDialog()
        resetUi()
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/disconnect", body: [:])
            if let err = r["error"] as? String { sys("error: \(err)") } else { sys("disconnected") }
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    /// Switch to `target`, keeping a live or in-flight session on it. Every
    /// environment switch funnels through here — main-actor serialization
    /// instead of racing fire-and-forget connects: a repeat tap on the host
    /// being connected to is a no-op, a different host tears down first.
    public func switchHost(_ target: String) async {
        if (connected && connectedTarget == target) || (connecting && connectingTarget == target) { return }
        if connected || connecting { await disconnectHost() }
        await connectHost(target)
    }

    public func connectHost(_ target: String) async {
        guard let api, !connecting else { return }
        connecting = true
        connectingTarget = target
        connectError = nil
        connectGeneration += 1
        let generation = connectGeneration
        resetUi()
        sys("connecting \(target)…")
        startProvisionLogPoll(generation)
        defer {
            provisionTask?.cancel()
            if generation == connectGeneration {
                connecting = false
                connectingTarget = nil
                cancelDialog()
            }
        }

        // The bridge answers needsTrust / needsAuth / needsUpdate until the
        // user decided; each answer is sent along (like the web loop).
        var body: [String: Any] = ["target": target]
        var r: [String: Any] = [:]
        do {
            for _ in 0..<4 {
                r = try await api.post("/api/remote/connect", body: body)
                if generation != connectGeneration { return }
                if r["needsTrust"] != nil, let fp = r["fingerprint"] as? String {
                    if await askDialog(.trust(fp)) {
                        let trust: [String: Any] = try await api.post("/api/remote/trust-host",
                                                                      body: ["target": target, "fingerprint": fp])
                        if trust["ok"] as? Bool != true { r = trust; break }
                    } else {
                        body["copyAuth"] = false
                    }
                } else if r["needsAuth"] != nil {
                    body["copyAuth"] = await askDialog(.copyAuth)
                } else if r["needsUpdate"] != nil {
                    let installed = r["installed"] as? String ?? "unknown"
                    let available = r["available"] as? String ?? ""
                    body["allowUpdate"] = await askDialog(.serverUpdate(installed: installed, available: available))
                } else {
                    break
                }
            }
            if generation != connectGeneration { return }

            if r["loginFailed"] as? Bool == true, await runKeyInstall(target),
               generation == connectGeneration {
                r = try await api.post("/api/remote/connect", body: ["target": target])
            }
            if generation != connectGeneration { return }

            if r["ok"] as? Bool != true {
                let err = r["error"] as? String ?? "could not connect"
                connectError = err
                sys("error: \(err)")
                return
            }
            connected = true
            connectedTarget = target
            var line = "connected: \(r["serverId"] as? String ?? "")"
            if let hostKey = r["hostKey"] as? String { line += " · host key \(hostKey)" }
            sys(line)

            var list = ((r["sessions"] as? [String: Any])?["sessions"] as? [[String: Any]]) ?? []
            // A fresh host has no durable conversations yet; create one so
            // Remote always opens a session of the newly selected host.
            if list.isEmpty {
                let created: [String: Any] = try await api.post("/api/remote/create", body: [:])
                guard let newId = created["id"].map({ String(describing: $0) }) else {
                    sys("error: \(created["error"] as? String ?? "could not create session")")
                    return
                }
                list = [["id": newId]]
            }
            await showSessions(list.map(Self.parseSession), attachFirst: true)
        } catch {
            if generation == connectGeneration {
                connectError = error.localizedDescription
                sys("error: \(error.localizedDescription)")
            }
        }
    }

    private static func parseSession(_ d: [String: Any]) -> RemoteSession {
        RemoteSession(id: String(describing: d["id"] ?? ""),
                      name: d["name"] as? String,
                      cwd: d["cwd"] as? String)
    }

    /// Provisioning (install/start of pi-serverd) can take minutes: poll its
    /// log and surface new lines while the connect runs.
    private func startProvisionLogPoll(_ generation: Int) {
        provisionTask?.cancel()
        var shown = 0
        provisionTask = Task { [weak self] in
            while !Task.isCancelled, let self, generation == self.connectGeneration {
                guard let api = self.api else { return }
                if let st: [String: Any] = try? await api.get("/api/remote/status") {
                    let log = st["log"] as? [String] ?? []
                    for line in log.dropFirst(shown) { self.sys(line) }
                    shown = max(shown, log.count)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - Dialog plumbing (alerts in the view resume the connect loop)

    private func askDialog(_ d: Dialog) async -> Bool {
        await withCheckedContinuation { cont in
            dialogContinuation?.resume(returning: false) // superseded by a newer question
            dialogContinuation = cont
            dialog = d
        }
    }

    public func answerDialog(_ answer: Bool) {
        dialog = nil
        dialogContinuation?.resume(returning: answer)
        dialogContinuation = nil
    }

    private func cancelDialog() {
        dialog = nil
        dialogContinuation?.resume(returning: false)
        dialogContinuation = nil
    }

    // MARK: - Key install (the shared KeyInstallModel flow)

    private func runKeyInstall(_ target: String) async -> Bool {
        guard let keyInstall else { return false }
        return await withCheckedContinuation { cont in
            keyInstall.begin(target: target) { installed in
                cont.resume(returning: installed)
            }
        }
    }

    private weak var keyInstall: KeyInstallModel?

    public func attach(_ keyInstall: KeyInstallModel) {
        self.keyInstall = keyInstall
    }

    // MARK: - Sessions, events, composer (remote.js ports)

    public func showSessions(_ list: [RemoteSession], attachFirst: Bool) async {
        sessions = list
        // A one-session host must still attach: the picker does not fire on
        // its initial selection, so do it explicitly like the web page.
        if attachFirst, let first = list.first {
            await attachSession(first.id)
        }
    }

    public func attachSession(_ id: String) async {
        guard let api else { return }
        pollGeneration += 1
        do {
            let r: [String: Any] = try await api.postWithRetry("/api/remote/attach", body: ["id": id], retries: 2)
            if r["ok"] as? Bool != true {
                sys("error: \(r["error"] as? String ?? "could not attach")")
                return
            }
            attachedId = id
            link = "connected"
            await loadRemoteModels()
            await reloadHistory()
            pollLoop(pollGeneration)
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func loadRemoteModels() async {
        guard let api else { return }
        do {
            let res: [String: Any] = try await api.get("/api/remote/models")
            if let list = res["models"] as? [[String: Any]] {
                models = list.compactMap { d in
                    guard let p = d["provider"] as? String, let m = d["modelId"] as? String else { return nil }
                    return RemoteModelOption(provider: p, modelId: m)
                }
            }
        } catch {}
    }

    public func reloadHistory() async -> Bool {
        guard let api else { return false }
        do {
            let history: [String: Any] = try await api.get("/api/remote/history")
            if history["error"] != nil { return false }
            clear()
            for e in history["entries"] as? [[String: Any]] ?? [] { renderEntry(e) }
            pos = (history["epoch"].map { String(describing: $0) }, (history["cursor"] as? Int) ?? -1)
            if let state: [String: Any] = try? await api.get("/api/remote/state"), state["error"] == nil {
                busy = state["busy"] as? Bool ?? false
                let docs = state["docs"] as? [String: Any]
                setActiveModel((docs?["pi.agent"] as? [String: Any])?["model"])
                if let u = docs?["pi.usage"] { usage = Self.usageText(u) }
            }
            return true
        } catch {
            return false
        }
    }

    private func pollLoop(_ generation: Int) {
        Task { [weak self] in
            while generation == self?.pollGeneration, let self, let api = self.api {
                do {
                    var query = [URLQueryItem(name: "after", value: String(self.pos.cursor))]
                    if let epoch = self.pos.epoch {
                        query.append(URLQueryItem(name: "epoch", value: epoch))
                    }
                    let r: [String: Any] = try await api.get("/api/remote/events", query: query)
                    if generation != self.pollGeneration { return }
                    if let err = r["error"] as? String {
                        if r["reconnecting"] as? Bool == true { self.link = "reconnecting" }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if r["reconnecting"] == nil { await self.checkLink() }
                        continue
                    }
                    self.link = "connected"
                    if r["reset"] as? Bool == true {
                        await self.reloadHistory()
                        continue
                    }
                    for ev in r["events"] as? [[String: Any]] ?? [] { self.handleEvent(ev) }
                    self.pos = (r["epoch"].map { String(describing: $0) }, (r["cursor"] as? Int) ?? -1)
                } catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self.checkLink()
                }
            }
        }
    }

    public func checkLink() async {
        guard let api else { return }
        if let s: [String: Any] = try? await api.get("/api/remote/status") {
            link = (s["status"] as? String) ?? "disconnected"
        }
    }

    public func newSession() async {
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/create", body: [:])
            guard let id = r["id"].map({ String(describing: $0) }) else {
                sys("error: \(r["error"] as? String ?? "could not create session")")
                return
            }
            let session = RemoteSession(id: id, name: r["name"] as? String)
            sessions.insert(session, at: 0)
            await attachSession(id)
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func renameSession(_ id: String, to name: String) async {
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/rename", body: ["id": id, "name": name])
            if r["ok"] as? Bool != true {
                sys("error: \(r["error"] as? String ?? "rename failed")")
                return
            }
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx] = RemoteSession(id: id, name: name, cwd: sessions[idx].cwd)
            }
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func deleteSession(_ id: String) async {
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/delete", body: ["id": id])
            if r["ok"] as? Bool != true {
                sys("error: \(r["error"] as? String ?? "could not remove session")")
                return
            }
            pollGeneration += 1
            attachedId = nil
            clear()
            let list: [String: Any] = try await api.get("/api/remote/sessions")
            await showSessions((list["sessions"] as? [[String: Any]] ?? []).map(Self.parseSession), attachFirst: true)
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func selectModel(_ option: RemoteModelOption) async {
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/model", body: ["provider": option.provider, "modelId": option.modelId])
            if r["ok"] as? Bool != true { sys("error: \(r["error"] as? String ?? "could not change model")") }
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func abort() async {
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/abort", body: [:])
            if let err = r["error"] as? String { sys("error: \(err)") }
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func compact() async {
        guard let api else { return }
        do {
            let r: [String: Any] = try await api.post("/api/remote/compact", body: [:])
            if let err = r["error"] as? String { sys("error: \(err)") }
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    public func stopServer(_ target: String) async {
        guard let api, !connecting else { return }
        connectGeneration += 1
        resetUi()
        sys("stopping server on \(target)…")
        do {
            let r: [String: Any] = try await api.post("/api/remote/stop", body: ["target": target])
            if let err = r["error"] as? String {
                sys("error: \(err)")
            } else {
                sys(r["stopped"] as? Bool == true ? "remote server stopped" : "remote server was not running")
            }
        } catch {
            sys("error: \(error.localizedDescription)")
        }
    }

    /// The composer: optimistic bubble, one requestId across retries (the ssh
    /// tunnel can drop mid-prompt; retries stay exactly-once), steer while busy.
    public func sendPrompt(_ text: String, steer: Bool) async {
        guard let api else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pendingId = addPendingUser(trimmed)
        var body: [String: Any] = ["message": trimmed, "requestId": UUID().uuidString]
        if busy && steer { body["whenBusy"] = "steer" }
        do {
            let r: [String: Any] = try await api.postWithRetry("/api/remote/prompt", body: body, retries: 10)
            if let err = r["error"] as? String { failPending(pendingId, error: err) }
        } catch {
            failPending(pendingId, error: error.localizedDescription)
        }
    }
}
