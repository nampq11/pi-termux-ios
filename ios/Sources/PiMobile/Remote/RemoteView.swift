import SwiftUI

// Native port of remote.html: host picker, connect/disconnect, session and
// model menus, the transcript (sys/user/assistant/tool items), and the
// composer with steer/abort/compact.

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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(remote.items) { item in
                            RemoteItemRow(item: item)
                        }
                        if remote.items.isEmpty {
                            intro
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: remote.items.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { composer(remote) }
            .navigationTitle("Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { hostMenu(remote) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task {
                            if remote.connected || remote.connecting {
                                await remote.disconnectHost()
                            } else if let selectedTarget {
                                await remote.connectHost(selectedTarget)
                            }
                        }
                    } label: {
                        Text(remote.connecting ? "cancel" : remote.connected ? "disconnect" : "connect")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(remote.connecting ? false : selectedTarget == nil)
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Work with a pi running on another machine over ssh.")
                .foregroundStyle(.secondary)
            Text("Pick a host above and tap connect. Hosts are managed under Clients.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func hostMenu(_ remote: RemoteModel) -> some View {
        Menu {
            ForEach(model.clients.hosts) { host in
                Button {
                    // Host change resets the UI; the user connects explicitly.
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
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(selectedTarget.map(basename) ?? "Host").font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let attachedId = remote.attachedId {
                    Text("session \(attachedId)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 190)
        }
        .tint(.primary)
        .accessibilityLabel("Host")
    }

    private func sessionMenu(_ remote: RemoteModel) -> some View {
        Menu {
            Section {
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
            }
            Section {
                Button { Task { await remote.newSession() } } label: { Label("New session", systemImage: "square.and.pencil") }
                Button { if let id = remote.attachedId { renaming = remote.sessions.first { $0.id == id }; renameText = renaming?.name ?? "" } }
                    label: { Label("Rename…", systemImage: "pencil") }
                    .disabled(remote.attachedId == nil)
                Button(role: .destructive) {
                    if let id = remote.attachedId { Task { await remote.deleteSession(id) } }
                } label: { Label("Delete session", systemImage: "trash") }
                    .disabled(remote.attachedId == nil)
                Button(role: .destructive) { stopConfirm = true } label: { Label("Stop server…", systemImage: "stop.circle") }
                    .disabled(selectedTarget == nil || remote.connecting)
            }
            if !remote.models.isEmpty {
                Section {
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
                } header: {
                    Text("Model")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Session options")
    }

    private func composer(_ remote: RemoteModel) -> some View {
        VStack(spacing: 4) {
            if remote.attachedId != nil {
                HStack(spacing: 12) {
                    Text(remote.link == "reconnecting" ? "reconnecting…" : remote.busy ? "running…" : "idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !remote.usage.isEmpty {
                        Text(remote.usage).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if remote.busy {
                        Toggle(isOn: $steer) { Text("steer").font(.caption2) }
                            .toggleStyle(.button)
                    }
                    Button { Task { await remote.abort() } } label: { Image(systemName: "stop.circle") }
                        .accessibilityLabel("Abort")
                    Button { Task { await remote.compact() } } label: { Image(systemName: "arrow.down.square") }
                        .accessibilityLabel("Compact")
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(remote.busy ? "Steer the request…" : "Message the remote agent…", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .submitLabel(.send)
                        .onSubmit { send(remote) }
                    Button { send(remote) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ remote: RemoteModel) {
        let text = draft
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
            Text(item.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(item.kind == .pendingUser ? 0.6 : 1)
                .foregroundStyle(item.kind == .failedUser ? .red : .primary)
                .textSelection(.enabled)
                .padding(.leading, 40)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant, .liveAssistant:
            HStack(alignment: .top, spacing: 4) {
                Text(item.text.isEmpty ? " " : item.text).textSelection(.enabled)
                if item.kind == .liveAssistant && item.text.isEmpty { ProgressView().controlSize(.small) }
            }
            .padding(.trailing, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .sys:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack {
                        Text(item.text).font(.caption.monospaced())
                        Spacer(minLength: 4)
                        Image(systemName: "chevron." + (expanded ? "up" : "down")).font(.caption2)
                    }
                    .foregroundStyle(item.isError ? .red : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded, let output = item.output, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output.count > 4000 ? String(output.prefix(4000)) + "\n…" : output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var bubbleColor: Color {
        switch item.kind {
        case .failedUser: Color.red.opacity(0.12)
        case .pendingUser: Color.accentColor.opacity(0.08)
        default: Color.accentColor.opacity(0.15)
        }
    }
}
