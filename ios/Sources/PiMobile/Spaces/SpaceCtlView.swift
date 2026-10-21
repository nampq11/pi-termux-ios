import SwiftUI

// Native port of spacectl.html: alerts, operations, runs (with the full run
// card action set incl. dry-run-confirmed stop and recovery decisions),
// workers, space create/archive/reactivate/delete, deployment plan/export,
// and the audit log. All German labels match the web page.

struct SpaceCtlView: View {
    @Environment(AppModel.self) private var model
    @State private var sieveRunId = ""
    @State private var sieveStart = "1"
    @State private var sieveEnd = "1001"
    @State private var sieveBlockSize = "128"
    @State private var sieveMembers = ""
    @State private var workerAssignment = ""
    @State private var workerHostId = ""
    @State private var workerKind = "sieve"
    @State private var workerSpace = ""
    @State private var workerRunId = ""
    @State private var workerCount = "1"
    @State private var createHostId = ""
    @State private var createAlias = ""
    @State private var changeHostId = ""
    @State private var changeSpaceId = ""
    @State private var deploymentConfig = ""

    // Pending destructive actions awaiting their confirmation dialog.
    @State private var stopPreview: (run: CtlRun, revision: Int)?
    @State private var recoveryDecision: (run: CtlRun, decision: String)?
    @State private var schedule: (runId: String, kind: String)?
    @State private var scheduleWhen = ""
    @State private var zeroWorkersConfirm = false
    @State private var deleteSpaceConfirm = false

    var body: some View {
        let ctl = model.spaceCtl
        Form {
            Section {
                Text("Aufträge gehen als Admin-Commands an den Koordinator. Erfolg wird erst nach dessen Ergebnis angezeigt; bei Zeitüberschreitung bleibt die Auftrags-ID erhalten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !ctl.message.isEmpty {
                    Text(ctl.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Hinweise") {
                loadButton("Hinweise laden") { await ctl.loadAlerts() }
                if let alerts = ctl.alerts {
                    if alerts.isEmpty {
                        Text("Keine Hinweise. Das ist kein Beweis, dass alles läuft: offline gemeldete Hosts erscheinen erst nach Ablauf ihres Heartbeats.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(alerts) { alert in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(alert.severity == "critical" ? "Kritisch" : "Hinweis") · \(alert.source) · \(alert.subject)")
                                    .font(.subheadline.weight(.medium))
                                Text(alert.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Vorgänge") {
                loadButton("Vorgänge aktualisieren") { await ctl.loadOperations() }
                if let operations = ctl.operations {
                    if operations.isEmpty {
                        Text("Keine Vorgänge auf diesem Gerät.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(operations) { op in
                            OperationRow(op: op)
                        }
                    }
                }
            }
            Section("Läufe") {
                loadButton("Läufe laden") { await ctl.loadRuns() }
                if let runs = ctl.runs {
                    if runs.isEmpty {
                        Text("Keine Läufe.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(runs) { run in
                            RunCard(run: run, ctl: ctl, stopPreview: $stopPreview,
                                    recoveryDecision: $recoveryDecision, schedule: $schedule)
                        }
                    }
                }
            }
            sieveForm(ctl)
            Section("Worker") {
                loadButton("Worker laden") { await ctl.loadWorkers() }
                if let assignments = ctl.assignments {
                    if assignments.isEmpty {
                        Text("Keine Zuweisungen.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(assignments) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(a.id) · \(a.kind) · gewünscht \(a.count)")
                                    .font(.subheadline.weight(.medium))
                                Text("Host \(a.hostId) · Space \(a.targetSpace)\(a.runId.map { " · Lauf \($0)" } ?? "") · Generation \(a.generation)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(a.report).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            workersForm(ctl)
            Section("Spaces") {
                TextField("Host-ID", text: $createHostId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Alias", text: $createAlias)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Space anlegen oder vorhandenen wiederverwenden") {
                    Task { await ctl.createSpace(hostId: createHostId, alias: createAlias) }
                }
                .disabled(createHostId.isEmpty || createAlias.isEmpty)
                TextField("Host-ID", text: $changeHostId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Space-ID", text: $changeSpaceId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Button("Archivieren") {
                        Task { await ctl.spaceChange(kind: "archiveSpace", hostId: changeHostId, spaceId: changeSpaceId) }
                    }
                    Button("Reaktivieren") {
                        Task { await ctl.spaceChange(kind: "reactivateSpace", hostId: changeHostId, spaceId: changeSpaceId) }
                    }
                    Button("Löschen", role: .destructive) { deleteSpaceConfirm = true }
                }
                .buttonStyle(.borderless)
                .disabled(changeHostId.isEmpty || changeSpaceId.isEmpty)
            }
            Section("Deployment") {
                TextField("Deployment-Config (JSON, ohne Geheimnisse)", text: $deploymentConfig, axis: .vertical)
                    .lineLimit(4...8)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Button("Plan anzeigen") { Task { await ctl.planDeployment(configText: deploymentConfig) } }
                    Button("Angewendeten Stand exportieren") { Task { await ctl.exportDeployment(configText: deploymentConfig) } }
                }
                .buttonStyle(.borderless)
                .disabled(deploymentConfig.isEmpty)
                if let result = ctl.deploymentResult {
                    switch result {
                    case .plan(let ready, let steps):
                        Text(ready ? "Plan bereit" : "Plan blockiert")
                            .font(.subheadline.weight(.medium))
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    case .json(let text):
                        Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section("Audit") {
                loadButton("Letzte Admin-Aufträge laden") { await ctl.loadAudit() }
                if let audit = ctl.audit {
                    ForEach(audit) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.kind) · \(entry.state) · \(entry.requestedBy)")
                                .font(.subheadline.weight(.medium))
                            Text("\(entry.at?.formatted(date: .abbreviated, time: .shortened) ?? "") · \(entry.commandId)\(entry.error.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // Like the web page, every button disables while a command runs.
        .disabled(ctl.running)
        .navigationTitle("Steuerung")
        .navigationBarTitleDisplayMode(.inline)
        .task { await ctl.loadOperations() }
        .alert("Lauf \(stopPreview?.run.id ?? "") endgültig stoppen?",
               isPresented: Binding(
                   get: { stopPreview != nil },
                   set: { if !$0 { stopPreview = nil } }
               )) {
            Button("Lauf stoppen", role: .destructive) {
                if let preview = stopPreview {
                    Task { await ctl.stopRun(runId: preview.run.id) }
                }
                stopPreview = nil
            }
            Button("Abbrechen", role: .cancel) { stopPreview = nil }
        } message: {
            Text("Revision \(stopPreview?.revision ?? 0)? Er kann nicht wieder gestartet werden.")
        }
        .confirmationDialog("Alle Worker von \(workerAssignment) nach ihrem laufenden Task stoppen?",
                            isPresented: $zeroWorkersConfirm, titleVisibility: .visible) {
            Button("Anzahl setzen (0)") { submitWorkers(ctl) }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Space \(changeSpaceId) löschen?",
                            isPresented: $deleteSpaceConfirm, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task { await ctl.spaceChange(kind: "deleteSpace", hostId: changeHostId, spaceId: changeSpaceId) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Nur ein archivierter, leerer Space ohne Mitgliedschaft wird gelöscht; die ID bleibt reserviert.")
        }
        .confirmationDialog("Recovery-Entscheidung „\(recoveryDecision?.decision ?? "")“ für \(recoveryDecision?.run.id ?? "") an den geprüften Stand binden?",
                            isPresented: Binding(
                                get: { recoveryDecision != nil },
                                set: { if !$0 { recoveryDecision = nil } }
                            ), titleVisibility: .visible) {
            Button("Binden") {
                if let pending = recoveryDecision {
                    Task { await ctl.resolveRecovery(runId: pending.run.id, expectedViewHash: pending.run.reviewViewHash ?? "", decision: pending.decision) }
                }
                recoveryDecision = nil
            }
            Button("Abbrechen", role: .cancel) { recoveryDecision = nil }
        }
        .alert("Zeitpunkt (JJJJ-MM-TT HH:MM, lokale Zeit)",
               isPresented: Binding(
                   get: { schedule != nil },
                   set: { if !$0 { schedule = nil } }
               )) {
            TextField("JJJJ-MM-TT HH:MM", text: $scheduleWhen)
            Button("Planen") {
                if let pending = schedule, !scheduleWhen.isEmpty {
                    Task { await ctl.scheduleRun(runId: pending.runId, kind: pending.kind, when: scheduleWhen) }
                }
                schedule = nil
            }
            Button("Abbrechen", role: .cancel) { schedule = nil }
        }
    }

    private func loadButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
    }

    private func sieveForm(_ ctl: SpaceCtlModel) -> some View {
        Section("Primzahlsieb") {
            TextField("Lauf-ID", text: $sieveRunId)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Start", text: $sieveStart)
                .keyboardType(.numberPad)
            TextField("Exklusive Obergrenze", text: $sieveEnd)
                .keyboardType(.numberPad)
            TextField("Blockgröße", text: $sieveBlockSize)
                .keyboardType(.numberPad)
            TextField("Space-IDs der Members (kommagetrennt)", text: $sieveMembers)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Primzahlsieb starten") {
                Task {
                    await ctl.startSieve(
                        runId: sieveRunId,
                        start: Int(sieveStart) ?? 0,
                        end: Int(sieveEnd) ?? 0,
                        blockSize: Int(sieveBlockSize) ?? 0,
                        members: sieveMembers
                    )
                }
            }
            .disabled(sieveRunId.isEmpty || sieveMembers.isEmpty)
        }
    }

    private func workersForm(_ ctl: SpaceCtlModel) -> some View {
        Section("Anzahl setzen") {
            TextField("Zuweisung", text: $workerAssignment)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Host-ID", text: $workerHostId)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Workerart", text: $workerKind)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Ziel-Space-ID", text: $workerSpace)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Lauf-ID (optional)", text: $workerRunId)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Anzahl (0 stoppt nach dem laufenden Task)", text: $workerCount)
                .keyboardType(.numberPad)
            Button("Anzahl setzen") {
                if Int(workerCount) == 0 {
                    zeroWorkersConfirm = true
                } else {
                    submitWorkers(ctl)
                }
            }
            .disabled(workerAssignment.isEmpty || workerHostId.isEmpty || workerKind.isEmpty || workerSpace.isEmpty)
        }
    }

    private func submitWorkers(_ ctl: SpaceCtlModel) {
        Task {
            await ctl.setWorkers(
                assignmentId: workerAssignment,
                hostId: workerHostId,
                kind: workerKind,
                targetSpace: workerSpace,
                runId: workerRunId,
                count: Int(workerCount) ?? 0
            )
        }
    }
}

// MARK: - Rows

/// One operation from the device's queue: state line, error, resend button.
private struct OperationRow: View {
    let op: CtlOperation
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(op.kind) · \(op.state)").font(.subheadline.weight(.medium))
            Text("\(op.id) · \(op.at?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if let error = op.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !op.final {
                Button("Gleichen Auftrag erneut senden") {
                    Task { await model.spaceCtl.resend(op) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }
}

/// One run with its state-dependent actions, mirroring runCard in spacectl.js.
private struct RunCard: View {
    let run: CtlRun
    let ctl: SpaceCtlModel
    @Binding var stopPreview: (run: CtlRun, revision: Int)?
    @Binding var recoveryDecision: (run: CtlRun, decision: String)?
    @Binding var schedule: (runId: String, kind: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(run.id) · \(run.state) · Revision \(run.revision)")
                .font(.subheadline.weight(.medium))
            Text("Members: \(run.members.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            if let pending = run.pendingText {
                Text(pending).font(.caption).foregroundStyle(.secondary)
            }
            if let recovery = run.recoveryText {
                Text(recovery).font(.caption).foregroundStyle(.secondary)
            }
            if run.state == "needsReview", let hash = run.reviewViewHash {
                Text("Geprüfter Stand \(hash.prefix(12))…: \(run.reviewText ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([("Als pausiert festlegen", "pause"), ("Endgültig stoppen", "stop"), ("Fortsetzen (nach Pause-Barriere)", "resume")], id: \.1) { label, decision in
                    Button(label) {
                        recoveryDecision = (run, decision)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            if let export = run.exportText {
                Text(export).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(actions, id: \.kind) { action in
                Button(action.label) {
                    Task { await ctl.runAction(action.kind, runId: run.id) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            Button("Ergebnis ansehen") {
                Task { await ctl.exportRun(runId: run.id) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            if run.state == "running" || run.state == "paused" {
                Button(run.state == "running" ? "Pause planen" : "Fortsetzen planen") {
                    schedule = (run.id, run.state == "running" ? "pause" : "resume")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            if ["running", "paused", "preparing"].contains(run.state) {
                // Plan preview first: the coordinator says whether the stop
                // is accepted now and with which revision.
                Button("Lauf stoppen", role: .destructive) {
                    Task {
                        if let preview = await ctl.stopRunPreview(runId: run.id) {
                            if !preview.allowed {
                                ctl.message = "Nicht möglich: \(preview.reason)"
                            } else {
                                stopPreview = (run, preview.revision)
                            }
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    /// The plain state actions (stop/resume/status), excluding the special
    /// flows handled above.
    private var actions: [(label: String, kind: String)] {
        var list: [(String, String)] = []
        if run.state == "running" { list.append(("Pausieren", "pauseRun")) }
        if run.state == "paused" { list.append(("Fortsetzen", "resumeRun")) }
        if ["pauseIncomplete", "pausing", "resuming"].contains(run.state) {
            list.append(("Status abfragen", "runStatus"))
        }
        return list
    }
}
