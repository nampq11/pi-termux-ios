import Foundation
import Observation

// Native port of spacectl.js: runs, workers and operations through admin
// commands. The bridge serves one space operation at a time, so all buttons
// disable while a command runs; a sent command keeps its ID and is polled
// for its result (up to 30 s), after which the ID stays usable under
// Vorgänge. Unlike the web page there is no visibility short-circuit —
// polling simply continues; the coordinator keeps the command either way.

// MARK: - Display structs (parsed once, prebuilt text like the web cards)

public struct CtlOperation: Identifiable {
    public let id: String
    let kind: String
    let state: String
    let at: Date?
    let error: String?
    let args: [String: Any]
    var final: Bool { ["completed", "failed", "duplicate"].contains(state) }

    init?(_ dict: [String: Any]) {
        guard let id = dict["commandId"] as? String else { return nil }
        self.id = id
        kind = dict["kind"] as? String ?? "?"
        state = dict["state"] as? String ?? "?"
        at = (dict["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let result = dict["result"] as? [String: Any]
        error = (result?["error"] as? String) ?? ((result?["result"] as? [String: Any])?["error"] as? String)
        args = dict["args"] as? [String: Any] ?? [:]
    }
}

public struct CtlRun: Identifiable {
    public let id: String
    let state: String
    let revision: Int
    let members: [String]
    let pendingText: String?
    let recoveryText: String?
    let reviewViewHash: String?
    let reviewText: String?
    var exportText: String?

    init?(dict: [String: Any]) {
        guard let id = dict["runId"] as? String else { return nil }
        self.id = id
        state = dict["state"] as? String ?? "?"
        revision = dict["revision"] as? Int ?? 0
        members = dict["members"] as? [String] ?? []
        if let pending = dict["pending"] as? [String: Any] {
            var text = "Offen: \(pending["kind"] as? String ?? "?") r\(pending["revision"] as? Int ?? 0); bestätigt \((pending["applied"] as? [Any])?.count ?? 0)/\(members.count)"
            if let missing = pending["missing"] as? [String], !missing.isEmpty {
                text += ", fehlend: " + missing.joined(separator: ", ")
            }
            pendingText = text
        } else {
            pendingText = nil
        }
        guard let recovery = dict["recovery"] as? [String: Any] else {
            recoveryText = nil
            reviewViewHash = nil
            reviewText = nil
            return
        }
        var text = "Recovery \(recovery["id"] as? String ?? "?"): \(recovery["stage"] as? String ?? "?")"
        if let abandoned = recovery["abandoned"] as? [String: Any] {
            text += ", geparkt: \(abandoned["kind"] as? String ?? "?") r\(abandoned["revision"] as? Int ?? 0)"
        }
        recoveryText = text
        reviewViewHash = recovery["viewHash"] as? String
        if let views = recovery["views"] as? [String: [String: Any]] {
            let parts = views.map { member, view -> String in
                let gate = (view["gate"] as? [String: Any])?["state"] as? String ?? "fehlt"
                var part = "\(member): \(gate)"
                if let fence = (view["fence"] as? [String: Any])?["kind"] as? String {
                    part += " (offen \(fence))"
                }
                if view["stopped"] as? Bool == true { part += ", gestoppt" }
                return part
            }.sorted()
            reviewText = parts.isEmpty ? nil : parts.joined(separator: "; ")
        } else {
            reviewText = nil
        }
    }
}

public struct CtlAssignment: Identifiable {
    public let id: String
    let kind: String
    let count: Int
    let hostId: String
    let targetSpace: String
    let runId: String?
    let generation: Int
    let report: String
}

public struct CtlAlert: Identifiable {
    public let id: String
    let severity: String
    let source: String
    let subject: String
    let message: String

    init?(_ dict: [String: Any]) {
        source = dict["source"] as? String ?? "?"
        subject = dict["subject"] as? String ?? "?"
        id = "\(source)/\(subject)"
        severity = dict["severity"] as? String ?? ""
        message = dict["message"] as? String ?? ""
    }
}

public struct CtlAudit: Identifiable {
    public let id: String
    let kind: String
    let state: String
    let requestedBy: String
    let at: Date?
    let commandId: String
    let error: String?

    init?(_ dict: [String: Any]) {
        commandId = dict["commandId"] as? String ?? UUID().uuidString
        id = commandId
        kind = dict["kind"] as? String ?? "?"
        state = dict["state"] as? String ?? "?"
        requestedBy = dict["requestedBy"] as? String ?? "?"
        at = (dict["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        error = dict["error"] as? String
    }
}

// MARK: - Model

@MainActor
@Observable
public final class SpaceCtlModel {
    public var message = ""
    public var running = false
    public var operations: [CtlOperation]?
    public var runs: [CtlRun]?
    public var assignments: [CtlAssignment]?
    public var alerts: [CtlAlert]?
    public var audit: [CtlAudit]?

    public enum DeploymentResult {
        case plan(ready: Bool, steps: [String])
        case json(String)
    }
    public var deploymentResult: DeploymentResult?

    private weak var api: BridgeAPI?

    private static let whenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    public init() {}

    public func attach(_ api: BridgeAPI) {
        self.api = api
    }

    /// Sends one admin command (or resends a known one) and polls for its
    /// result; returns the command's payload, or nil on rejection/error.
    @discardableResult
    public func command(_ kind: String, args: [String: Any] = [:], commandId: String? = nil) async -> Any? {
        guard let api else { return nil }
        running = true
        message = "Auftrag wird gesendet …"
        defer { running = false }
        do {
            var body: [String: Any] = ["kind": kind, "args": args]
            if let commandId { body["commandId"] = commandId }
            let sent: [String: Any] = try await api.post("/api/spaces/admin", body: body)
            if let err = sent["error"] as? String {
                message = err
                return nil
            }
            let id = (sent["operation"] as? [String: Any])?["commandId"] as? String ?? commandId ?? "?"
            var result = sent["result"] as? [String: Any]
            message = "Auftrag \(id) angenommen, Ergebnis ausstehend …"
            for _ in 0..<30 where result == nil {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let poll: [String: Any] = try await api.post("/api/spaces/result", body: ["commandId": id])
                result = poll["result"] as? [String: Any]
            }
            guard let result else {
                message = "Ausgang wird geprüft (\(id)). Bitte nicht neu starten, sondern unter Vorgängen erneut abfragen."
                return nil
            }
            let payload = result["result"]
            let failed = (result["state"] as? String) != "completed"
                || (payload as? [String: Any])?["phase"] as? String == "failed"
            if failed {
                let detail = (result["error"] as? String)
                    ?? (payload as? [String: Any])?["error"] as? String
                    ?? (result["state"] as? String ?? "?")
                message = "Abgelehnt: \(detail)"
                return nil
            }
            message = "Erledigt (\(id))"
            return payload
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    // MARK: List loads

    public func loadOperations() async {
        guard let api else { return }
        do {
            let reply: [String: Any] = try await api.post("/api/spaces/operations", body: [:])
            if let err = reply["error"] as? String {
                message = err
                return
            }
            operations = (reply["operations"] as? [[String: Any]])?.compactMap(CtlOperation.init) ?? []
        } catch {
            message = error.localizedDescription
        }
    }

    public func loadAlerts() async {
        if let list = await command("listAlerts") as? [[String: Any]] {
            alerts = list.compactMap(CtlAlert.init)
        }
    }

    public func loadAudit() async {
        if let list = await command("auditLog", args: ["limit": 50]) as? [[String: Any]] {
            audit = list.compactMap(CtlAudit.init)
        }
    }

    public func loadRuns() async {
        if let list = await command("listRuns", args: ["limit": 50]) as? [[String: Any]] {
            runs = list.compactMap(CtlRun.init)
        }
    }

    public func loadWorkers() async {
        guard let data = await command("listWorkers") as? [String: Any] else { return }
        let applied = data["applied"] as? [String: [String: Any]] ?? [:]
        assignments = (data["assignments"] as? [[String: Any]])?.compactMap { a in
            CtlAssignment(
                id: a["assignmentId"] as? String ?? UUID().uuidString,
                kind: a["kind"] as? String ?? "?",
                count: a["count"] as? Int ?? 0,
                hostId: a["hostId"] as? String ?? "?",
                targetSpace: a["targetSpace"] as? String ?? "?",
                runId: a["runId"] as? String,
                generation: a["generation"] as? Int ?? 0,
                report: workerReport(a, applied: applied)
            )
        } ?? []
    }

    /// The host's last report line, or the warning that no report exists.
    private func workerReport(_ a: [String: Any], applied: [String: [String: Any]]) -> String {
        guard let host = applied[a["hostId"] as? String ?? ""], let workers = host["workers"] as? [String: Any] else {
            return "Kein Bericht des Hosts; „offline“ beweist nicht, dass Worker beendet sind."
        }
        let state = (workers["assignments"] as? [String: [String: Any]])?[a["assignmentId"] as? String ?? ""]
        var text = "Gemeldet \(Date(timeIntervalSince1970: (host["at"] as? Double ?? 0) / 1000).formatted(date: .omitted, time: .shortened)): aktiv \(state?["active"] as? Int ?? 0), beendend \(state?["stopping"] as? Int ?? 0), Tasks \(state?["tasks"] as? Int ?? 0)"
        if let rejected = state?["rejected"] as? String {
            text += ", abgelehnt: \(rejected)"
        }
        if (workers["generation"] as? Int ?? 0) < (a["generation"] as? Int ?? 0) {
            text += " (Änderung noch nicht übernommen)"
        }
        return text
    }

    // MARK: Forms

    public func startSieve(runId: String, start: Int, end: Int, blockSize: Int, members raw: String) async {
        let members = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let config: [String: Any] = ["runId": runId, "start": start, "end": end, "blockSize": blockSize]
        if await command("startRun", args: ["runId": runId, "kind": "sieve", "config": config, "members": members]) != nil {
            await loadRuns()
        }
    }

    public func setWorkers(assignmentId: String, hostId: String, kind: String, targetSpace: String, runId: String?, count: Int) async {
        var args: [String: Any] = ["assignmentId": assignmentId, "hostId": hostId, "kind": kind, "targetSpace": targetSpace, "count": count]
        if let runId, !runId.isEmpty { args["runId"] = runId }
        if await command("setWorkers", args: args) != nil {
            await loadWorkers()
        }
    }

    public func createSpace(hostId: String, alias: String) async {
        if let r = await command("createSpace", args: ["hostId": hostId, "alias": alias]) as? [String: Any] {
            let reused = r["existed"] as? Bool ?? false
            message = "\(reused ? "Wiederverwendet" : "Angelegt"): \(r["alias"] as? String ?? alias) = \(r["spaceId"] as? String ?? "?")"
        }
    }

    public func spaceChange(kind: String, hostId: String, spaceId: String) async {
        if let r = await command(kind, args: ["hostId": hostId, "spaceId": spaceId]) as? [String: Any] {
            message = "\(r["alias"] as? String ?? "?"): \(r["state"] as? String ?? "?")"
        }
    }

    /// Parses the config JSON; nil (with message set) when invalid.
    private func parseConfig(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) else {
            message = "Config ist kein gültiges JSON"
            return nil
        }
        return config
    }

    public func planDeployment(configText: String) async {
        guard let config = parseConfig(configText) else { return }
        if let r = await command("planDeployment", args: ["config": config]) as? [String: Any] {
            let steps = (r["steps"] as? [[String: Any]])?.map { "\($0["status"] as? String ?? "?") · \($0["key"] as? String ?? "?") · \($0["detail"] as? String ?? "")" } ?? []
            deploymentResult = .plan(ready: r["ready"] as? Bool ?? false, steps: steps)
        }
    }

    public func exportDeployment(configText: String) async {
        guard let config = parseConfig(configText) else { return }
        let deployment = (config as? [String: Any])?["deployment"] ?? NSNull()
        if let r = await command("exportDeployment", args: ["deployment": deployment]) {
            if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                deploymentResult = .json(text)
            }
        }
    }

    // MARK: Run card actions

    /// Plan preview for a stop: the coordinator says whether it is accepted
    /// now and at which revision.
    public func stopRunPreview(runId: String) async -> (allowed: Bool, reason: String, revision: Int)? {
        guard let r = await command("stopRun", args: ["runId": runId, "dryRun": true]) as? [String: Any] else { return nil }
        return (allowed: r["allowed"] as? Bool ?? false, reason: r["reason"] as? String ?? "?", revision: r["revision"] as? Int ?? 0)
    }

    public func stopRun(runId: String) async {
        if await command("stopRun", args: ["runId": runId]) != nil {
            await loadRuns()
        }
    }

    public func runAction(_ kind: String, runId: String) async {
        if await command(kind, args: ["runId": runId]) != nil {
            await loadRuns()
        }
    }

    public func exportRun(runId: String) async {
        guard let r = await command("exportRun", args: ["runId": runId]) as? [String: Any],
              let idx = runs?.firstIndex(where: { $0.id == runId }) else { return }
        let complete = r["complete"] as? Bool ?? false
        var text = "\(complete ? "Vollständig" : "TEILRESULTAT"): \(r["found"] as? Int ?? 0)/\(r["expected"] as? Int ?? 0) Teile"
        if let missing = r["missing"] as? [String], !missing.isEmpty {
            text += ", fehlend z. B. " + missing.prefix(3).joined(separator: ", ")
        }
        if let summary = r["summary"],
           let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            text += " · \(str)"
        }
        text += " · Manifest \((r["manifestHash"] as? String ?? "").prefix(12))… · Ergebnis \((r["resultHash"] as? String ?? "").prefix(12))…"
        runs?[idx].exportText = text
    }

    /// Schedules a pause/resume from "JJJJ-MM-TT HH:MM" local time.
    public func scheduleRun(runId: String, kind: String, when: String) async {
        guard let date = Self.whenFormatter.date(from: when.replacingOccurrences(of: " ", with: "T")) else {
            message = "Ungültiger Zeitpunkt"
            return
        }
        if let r = await command("scheduleRun", args: ["runId": runId, "kind": kind, "at": date.timeIntervalSince1970 * 1000]) as? [String: Any],
           let schedules = r["schedules"] as? [[String: Any]] {
            let text = schedules.map { s -> String in
                let at = Date(timeIntervalSince1970: (s["at"] as? Double ?? 0) / 1000)
                return "\(s["kind"] as? String ?? "?") \(at.formatted(date: .abbreviated, time: .shortened))"
            }.joined(separator: ", ")
            message = "Geplant: \(text)"
        }
    }

    public func resolveRecovery(runId: String, expectedViewHash: String, decision: String) async {
        if await command("resolveRunRecovery", args: ["runId": runId, "expectedViewHash": expectedViewHash, "decision": decision]) != nil {
            await loadRuns()
        }
    }

    /// Resends a known command (with its original args) from the operations
    /// list, then refreshes it.
    public func resend(_ op: CtlOperation) async {
        if await command(op.kind, args: op.args, commandId: op.id) != nil {
            await loadOperations()
        }
    }
}
