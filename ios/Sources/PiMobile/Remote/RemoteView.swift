import SwiftUI

// Redesigned for PiMobile:
// Remote agent interface: connects over SSH tunnel to remote pi-serverd instances.
// Delivers a cohesive, fluid Apple experience matching the local Agent screen.

struct RemoteView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTarget: String?
    @State private var draft = ""
    @State private var steer = false
    @State private var renaming: RemoteSession?
    @State private var renameText = ""
    @State private var stopConfirm = false

    var body: some View {
        let remote = model.remote
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !remote.connected {
                            disconnectedHero(remote)
                        } else if remote.items.isEmpty {
                            connectedEmptyState(remote)
                        } else {
                            ForEach(remote.items) { item in
                                RemoteItemRow(item: item)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: remote.items.count) { _, _ in
                    withAnimation(PiTheme.snappySpring) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                if remote.connected && remote.attachedId != nil {
                    composer(remote)
                }
            }
            .navigationTitle("Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    hostTitleButton(remote)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if remote.connected || remote.connecting {
                        Button {
                            haptic()
                            Task {
                                if remote.connected || remote.connecting {
                                    await remote.disconnectHost()
                                } else if let selectedTarget {
                                    await remote.connectHost(selectedTarget)
                                }
                            }
                        } label: {
                            Text(remote.connecting ? "Cancel" : "Disconnect")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(remote.connected ? .red : .primary)
                        }
                    }
                    sessionMenu(remote)
                }
            }
            .task {
                await model.clients.loadAll()
                if selectedTarget == nil { selectedTarget = model.clients.hosts.first?.target }
            }
            .alert(alertTitle,
                   isPresented: Binding(
                       get: { remote.dialog != nil },
                       set: { if !$0 { remote.answerDialog(false) } }
                   )) {
                Button(affirmLabel) { remote.answerDialog(true) }
                Button(negLabel, role: .cancel) { remote.answerDialog(false) }
            } message: {
                Text(alertMessage)
            }
            .alert("Rename session", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await remote.renameSession(renaming.id, to: renameText.trimmingCharacters(in: .whitespaces)) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Stop pi-serverd on \(selectedTarget ?? "")?",
                                isPresented: $stopConfirm, titleVisibility: .visible) {
                Button("Stop server", role: .destructive) {
                    if let selectedTarget { Task { await remote.stopServer(selectedTarget) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Running work on that host is aborted. It is started (and updated if needed) again on the next connect.")
            }
        }
    }

    // MARK: - Hero & Empty States

    private func disconnectedHero(_ remote: RemoteModel) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "server.rack")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.blue)
                }
                .padding(.top, 20)

                Text("Remote Workspace")
                    .font(.title3.weight(.bold))

                Text("Connect to a host running pi-serverd over an encrypted SSH tunnel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            // Connection card
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Target Host")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Menu {
                            ForEach(model.clients.hosts) { host in
                                Button {
                                    haptic()
                                    selectedTarget = host.target
                                } label: {
                                    if host.target == selectedTarget {
                                        Label(host.name, systemImage: "checkmark")
                                    } else {
                                        Text(host.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedTarget.map(basename) ?? "No host selected")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    StatusPill(remote.connecting ? .running : .idle, text: remote.connecting ? "Connecting" : "Offline")
                }

                if let target = selectedTarget {
                    Text(target)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    haptic()
                    Task {
                        if let selectedTarget {
                            await remote.connectHost(selectedTarget)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if remote.connecting {
                            ProgressView()
                                .tint(.white)
                                .controlSize(.small)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(remote.connecting ? "Connecting to host…" : "Connect to Host")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTarget == nil || remote.connecting)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(PiTheme.subtleBorder, lineWidth: 0.8))
        }
        .padding(.vertical, 12)
    }

    private func connectedEmptyState(_ remote: RemoteModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
                .padding(.top, 32)
            Text("Connected to \(selectedTarget.map(basename) ?? "host")")
                .font(.headline)
            Text("Start messaging to run commands, edit files, or execute tools on the remote machine.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Navigation Bar Elements

    private func hostTitleButton(_ remote: RemoteModel) -> some View {
        Menu {
            ForEach(model.clients.hosts) { host in
                Button {
                    if remote.connected || remote.connecting {
                        Task { await remote.disconnectHost() }
                    }
                    selectedTarget = host.target
                } label: {
                    if host.target == selectedTarget {
                        Label(host.name, systemImage: "checkmark")
                    } else {
                        Text(host.name)
                    }
                }
            }
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(selectedTarget.map(basename) ?? "Host")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    if remote.connected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                    }
                }
                if let attachedId = remote.attachedId {
                    Text("Session \(attachedId)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 200)
        }
        .tint(.primary)
        .accessibilityLabel("Select remote host")
    }

    private func sessionMenu(_ remote: RemoteModel) -> some View {
        Menu {
            Section("Sessions") {
                ForEach(remote.sessions) { session in
                    Button {
                        Task { await remote.attachSession(session.id) }
                    } label: {
                        if session.id == remote.attachedId {
                            Label(session.label, systemImage: "checkmark")
                        } else {
                            Text(session.label)
                        }
                    }
                }
                Button {
                    Task { await remote.newSession() }
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
            }
            if remote.attachedId != nil {
                Section("Manage Active Session") {
                    Button {
                        if let id = remote.attachedId {
                            renaming = remote.sessions.first { $0.id == id }
                            renameText = renaming?.name ?? ""
                        }
                    } label: {
                        Label("Rename Session…", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if let id = remote.attachedId { Task { await remote.deleteSession(id) } }
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                }
            }
            if !remote.models.isEmpty {
                Section("Remote Models") {
                    ForEach(remote.models) { option in
                        Button {
                            Task { await remote.selectModel(option) }
                        } label: {
                            if option == remote.activeModel {
                                Label("\(option.provider)/\(option.modelId)", systemImage: "checkmark")
                            } else {
                                Text("\(option.provider)/\(option.modelId)")
                            }
                        }
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    stopConfirm = true
                } label: {
                    Label("Stop Server Daemon…", systemImage: "stop.circle")
                }
                .disabled(selectedTarget == nil || remote.connecting)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Session options")
    }

    // MARK: - Composer

    private func composer(_ remote: RemoteModel) -> some View {
        VStack(spacing: 8) {
            // Header status row: connection link, usage, steer toggle, compact
            HStack(spacing: 8) {
                StatusPill(remote.link == "reconnecting" ? .warning : remote.busy ? .running : .success,
                           text: remote.link == "reconnecting" ? "Reconnecting" : remote.busy ? "Running" : "Idle")

                if !remote.usage.isEmpty {
                    Text(remote.usage)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if remote.busy {
                    Toggle(isOn: $steer) {
                        Text("Steer")
                            .font(.caption2.weight(.medium))
                    }
                    .toggleStyle(.button)
                    .tint(.purple)
                }

                Button {
                    haptic()
                    Task { await remote.compact() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .accessibilityLabel("Compact context")
            }
            .padding(.horizontal, 4)

            // Text input and Send/Stop morphing button
            HStack(alignment: .bottom, spacing: 8) {
                TextField(remote.busy ? "Steer running request…" : "Message remote pi…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .submitLabel(.send)
                    .onSubmit { send(remote) }

                if remote.busy && draft.isEmpty {
                    Button {
                        haptic()
                        Task { await remote.abort() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Abort generation")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        send(remote)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.accentColor : Color.secondary.opacity(0.3))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(PiTheme.subtleBorder, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func send(_ remote: RemoteModel) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        haptic()
        draft = ""
        Task { await remote.sendPrompt(text, steer: steer) }
    }

    // MARK: - Connect-loop dialogs

    private var alertTitle: String {
        switch model.remote.dialog {
        case .trust: "Trust the host?"
        case .copyAuth: "Copy credentials?"
        case .serverUpdate: "Update the remote server?"
        case nil: ""
        }
    }

    private var affirmLabel: String {
        switch model.remote.dialog {
        case .trust: "Trust"
        case .copyAuth: "Copy"
        case .serverUpdate: "Yes, update"
        case nil: "OK"
        }
    }

    private var negLabel: String {
        switch model.remote.dialog {
        case .trust: "Don't trust"
        case .copyAuth: "Skip"
        case .serverUpdate: "Keep old version"
        case nil: "Cancel"
        }
    }

    private var alertMessage: String {
        let target = selectedTarget ?? "the host"
        return switch model.remote.dialog {
        case .trust(let fingerprint):
            "Host fingerprint of \(target):\n\(fingerprint)"
        case .copyAuth:
            "Copy this device's auth.json (model API keys) to \(target) so the agent works over ssh."
        case .serverUpdate(let installed, let available):
            "pi-serverd on \(target) is outdated (\(installed) → \(available)). Running work is interrupted; durable sessions resume afterwards."
        case nil:
            ""
        }
    }
}

/// One transcript item: user bubble, assistant text, tool call, or sys line.
struct RemoteItemRow: View {
    let item: RemoteItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user, .pendingUser, .failedUser:
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        bubbleColor,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .opacity(item.kind == .pendingUser ? 0.7 : 1)
                    .textSelection(.enabled)
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant, .liveAssistant:
            VStack(alignment: .leading, spacing: 6) {
                if !item.text.isEmpty {
                    Text(AgentItemView.markdown(item.text))
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else if item.kind == .liveAssistant {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .sys:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)

        case .tool:
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    haptic()
                    withAnimation(PiTheme.snappySpring) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(item.isError ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                                .frame(width: 28, height: 28)
                            Image(systemName: "terminal")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(item.isError ? Color.red : Color.green)
                        }

                        Text(item.text)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .foregroundStyle(item.isError ? Color.red : Color.primary)

                        Spacer(minLength: 4)

                        Image(systemName: "chevron." + (expanded ? "up" : "down"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded, let output = item.output, !output.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button {
                            UIPasteboard.general.string = output
                            haptic()
                        } label: {
                            Label("Copy Output", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)

                        ScrollView(.horizontal) {
                            Text(output.count > 4000 ? String(output.prefix(4000)) + "\n…" : output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PiTheme.subtleBorder, lineWidth: 0.8))
        }
    }

    private var bubbleColor: Color {
        switch item.kind {
        case .failedUser: Color.red.opacity(0.8)
        case .pendingUser: Color.accentColor.opacity(0.5)
        default: Color.accentColor
        }
    }
}
