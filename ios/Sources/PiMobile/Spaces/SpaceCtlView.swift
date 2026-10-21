import SwiftUI

// Native port of spacectl.html: alerts, operations, runs (with the full run
// card action set incl. dry-run-confirmed stop and recovery decisions),
// workers, space create/archive/reactivate/delete, deployment plan/export,
// and the audit log. The web page's labels are German; the native app uses
// English throughout.

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
                Text("Commands go to the coordinator as admin commands. Success is only shown once its result arrives; on timeout the command ID is kept.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !ctl.message.isEmpty {
                    Text(ctl.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Alerts") {
                loadButton("Load alerts") { await ctl.loadAlerts() }
                if let alerts = ctl.alerts {
                    if alerts.isEmpty {
                        Text("No alerts. That is no proof that everything runs: hosts reported offline only appear after their heartbeat expires.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(alerts) { alert in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(alert.severity == "critical" ? "Critical" : "Notice") · \(alert.source) · \(alert.subject)")
                                    .font(.subheadline.weight(.medium))
                                Text(alert.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Operations") {
                loadButton("Refresh operations") { await ctl.loadOperations() }
                if let operations = ctl.operations {
                    if operations.isEmpty {
                        Text("No operations on this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(operations) { op in
                            OperationRow(op: op)
                        }
                    }
                }
            }
            Section("Runs") {
                loadButton("Load runs") { await ctl.loadRuns() }
                if let runs = ctl.runs {
                    if runs.isEmpty {
                        Text("No runs.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(runs) { run in
                            RunCard(run: run, ctl: ctl, stopPreview: $stopPreview,
                                    recoveryDecision: $recoveryDecision, schedule: $schedule)
                        }
                    }
                }
            }
            sieveForm(ctl)
            Section("Workers") {
                loadButton("Load workers") { await ctl.loadWorkers() }
                if let assignments = ctl.assignments {
                    if assignments.isEmpty {
                        Text("No assignments.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(assignments) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(a.id) · \(a.kind) · wanted \(a.count)")
                                    .font(.subheadline.weight(.medium))
                                Text("Host \(a.hostId) · Space \(a.targetSpace)\(a.runId.map { " · Run \($0)" } ?? "") · Generation \(a.generation)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(a.report).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            workersForm(ctl)
            Section("Spaces") {
                TextField("Host ID", text: $createHostId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Alias", text: $createAlias)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Create space or reuse existing") {
                    Task { await ctl.createSpace(hostId: createHostId, alias: createAlias) }
                }
                .disabled(createHostId.isEmpty || createAlias.isEmpty)
                TextField("Host ID", text: $changeHostId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Space ID", text: $changeSpaceId)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Button("Archive") {
                        Task { await ctl.spaceChange(kind: "archiveSpace", hostId: changeHostId, spaceId: changeSpaceId) }
                    }
                    Button("Reactivate") {
                        Task { await ctl.spaceChange(kind: "reactivateSpace", hostId: changeHostId, spaceId: changeSpaceId) }
                    }
                    Button("Delete", role: .destructive) { deleteSpaceConfirm = true }
                }
                .buttonStyle(.borderless)
                .disabled(changeHostId.isEmpty || changeSpaceId.isEmpty)
            }
            Section("Deployment") {
                TextField("Deployment config (JSON, no secrets)", text: $deploymentConfig, axis: .vertical)
                    .lineLimit(4...8)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Button("Show plan") { Task { await ctl.planDeployment(configText: deploymentConfig) } }
                    Button("Export applied state") { Task { await ctl.exportDeployment(configText: deploymentConfig) } }
                }
                .buttonStyle(.borderless)
                .disabled(deploymentConfig.isEmpty)
                if let result = ctl.deploymentResult {
                    switch result {
                    case .plan(let ready, let steps):
                        Text(ready ? "Plan ready" : "Plan blocked")
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
                loadButton("Load recent admin commands") { await ctl.loadAudit() }
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
        .navigationTitle("Control")
        .navigationBarTitleDisplayMode(.inline)
        .task { await ctl.loadOperations() }
        .alert("Stop run \(stopPreview?.run.id ?? "") permanently?",
               isPresented: Binding(
                   get: { stopPreview != nil },
                   set: { if !$0 { stopPreview = nil } }
               )) {
            Button("Stop run", role: .destructive) {
                if let preview = stopPreview {
                    Task { await ctl.stopRun(runId: preview.run.id) }
                }
                stopPreview = nil
            }
            Button("Cancel", role: .cancel) { stopPreview = nil }
        } message: {
            Text("Revision \(stopPreview?.revision ?? 0)? It cannot be restarted.")
        }
        .confirmationDialog("Stop all workers of \(workerAssignment) after their current task?",
                            isPresented: $zeroWorkersConfirm, titleVisibility: .visible) {
            Button("Set count (0)") { submitWorkers(ctl) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete space \(changeSpaceId)?",
                            isPresented: $deleteSpaceConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await ctl.spaceChange(kind: "deleteSpace", hostId: changeHostId, spaceId: changeSpaceId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only an archived, empty space without membership is deleted; the ID stays reserved.")
        }
        .confirmationDialog("Bind recovery decision \"\(recoveryDecision?.decision ?? "")\" for \(recoveryDecision?.run.id ?? "") to the reviewed state?",
                            isPresented: Binding(
                                get: { recoveryDecision != nil },
                                set: { if !$0 { recoveryDecision = nil } }
                            ), titleVisibility: .visible) {
            Button("Bind") {
                if let pending = recoveryDecision {
                    Task { await ctl.resolveRecovery(runId: pending.run.id, expectedViewHash: pending.run.reviewViewHash ?? "", decision: pending.decision) }
                }
                recoveryDecision = nil
            }
            Button("Cancel", role: .cancel) { recoveryDecision = nil }
        }
        .alert("Time (YYYY-MM-DD HH:MM, local time)",
               isPresented: Binding(
                   get: { schedule != nil },
                   set: { if !$0 { schedule = nil } }
               )) {
            TextField("YYYY-MM-DD HH:MM", text: $scheduleWhen)
            Button("Schedule") {
                if let pending = schedule, !scheduleWhen.isEmpty {
                    Task { await ctl.scheduleRun(runId: pending.runId, kind: pending.kind, when: scheduleWhen) }
                }
                schedule = nil
            }
            Button("Cancel", role: .cancel) { schedule = nil }
        }
    }

    private func loadButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
    }

    private func sieveForm(_ ctl: SpaceCtlModel) -> some View {
        Section("Prime sieve") {
            TextField("Run ID", text: $sieveRunId)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Start", text: $sieveStart)
                .keyboardType(.numberPad)
            TextField("Exclusive upper bound", text: $sieveEnd)
                .keyboardType(.numberPad)
            TextField("Block size", text: $sieveBlockSize)
                .keyboardType(.numberPad)
            TextField("Member space IDs (comma-separated)", text: $sieveMembers)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Start prime sieve") {
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
        Section("Set count") {
            TextField("Assignment", text: $workerAssignment)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Host ID", text: $workerHostId)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Worker kind", text: $workerKind)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Target space ID", text: $workerSpace)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Run ID (optional)", text: $workerRunId)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Count (0 stops after the current task)", text: $workerCount)
                .keyboardType(.numberPad)
            Button("Set count") {
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
                Button("Resend same command") {
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
                Text("Reviewed state \(hash.prefix(12))…: \(run.reviewText ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([("Set as paused", "pause"), ("Stop permanently", "stop"), ("Resume (after pause barrier)", "resume")], id: \.1) { label, decision in
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
            Button("View result") {
                Task { await ctl.exportRun(runId: run.id) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            if run.state == "running" || run.state == "paused" {
                Button(run.state == "running" ? "Schedule pause" : "Schedule resume") {
                    schedule = (run.id, run.state == "running" ? "pause" : "resume")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            if ["running", "paused", "preparing"].contains(run.state) {
                // Plan preview first: the coordinator says whether the stop
                // is accepted now and with which revision.
                Button("Stop run", role: .destructive) {
                    Task {
                        if let preview = await ctl.stopRunPreview(runId: run.id) {
                            if !preview.allowed {
                                ctl.message = "Not possible: \(preview.reason)"
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

    /// The plain state actions (pause/resume/status), excluding the special
    /// flows handled above.
    private var actions: [(label: String, kind: String)] {
        var list: [(String, String)] = []
        if run.state == "running" { list.append(("Pause", "pauseRun")) }
        if run.state == "paused" { list.append(("Resume", "resumeRun")) }
        if ["pauseIncomplete", "pausing", "resuming"].contains(run.state) {
            list.append(("Query status", "runStatus"))
        }
        return list
    }
}
