import SwiftUI

// Redesigned for PiMobile:
// Chat-Centric Architecture: The persistent bottom tab bar has been completely
// removed. The app's single core is the full-screen Chat workspace, with instant
// switching between Local and Remote environments, plus a slide-over Sidebar
// and Settings modal for configuration and tools.

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.currentEnvironment {
            case .local:
                AgentView()
                    .transition(.opacity)
            case .remote:
                RemoteView()
                    .transition(.opacity)
            }
        }
        .animation(PiTheme.snappySpring, value: model.currentEnvironment)
        .sheet(isPresented: $model.showSidebar) {
            SidebarDrawerView()
                .environment(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheetView()
                .environment(model)
        }
        // The shared key-install flow, hosted at root so Clients and the
        // terminal screen can both trigger it.
        .confirmationDialog(
            "Install the device key on \(model.keyInstall.target ?? "")?",
            isPresented: Binding(
                get: { model.keyInstall.phase == .confirm },
                set: { if !$0, model.keyInstall.phase == .confirm { model.keyInstall.cancel() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Install Key") { model.keyInstall.confirm() }
            Button("Cancel", role: .cancel) { model.keyInstall.cancel() }
        } message: {
            Text("The Ed25519 key lets this device sign in to \(model.keyInstall.target ?? "") without a password.")
        }
        .sheet(isPresented: Binding(
            get: { model.keyInstall.phase == .password },
            set: { if !$0, model.keyInstall.phase == .password { model.keyInstall.cancel() } }
        )) {
            passwordSheet
        }
        .alert("Key Installation Failed",
               isPresented: Binding(
                   get: { model.keyInstall.error != nil },
                   set: { if !$0 { model.keyInstall.error = nil } }
               )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.keyInstall.error ?? "")
        }
    }

    private var passwordSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("SSH Account Password", text: $password)
                        .onSubmit { submitPassword() }
                    if model.keyInstall.passwordRejected {
                        Text("Incorrect password — please try again.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Your password is used once to append the device key to ~/.ssh/authorized_keys and is never stored.")
                }
            }
            .navigationTitle("Authenticate for \(model.keyInstall.target ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.keyInstall.cancel()
                        password = ""
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Install Key") { submitPassword() }
                        .font(.body.weight(.semibold))
                        .disabled(password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: model.keyInstall.passwordRejected) { _, rejected in
            if rejected { password = "" }
        }
    }

    private func submitPassword() {
        let value = password
        password = ""
        haptic()
        Task { await model.keyInstall.submit(password: value) }
    }
}

// MARK: - Slide-out Sidebar Drawer

struct SidebarDrawerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Environments") {
                    Button {
                        model.switchEnvironment(.local)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "iphone")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.accentColor)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("On-Device (Local)")
                                    .font(.body.weight(.medium))
                                Text("In-process Node 24 engine")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.currentEnvironment.isLocal {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .tint(.primary)

                    ForEach(model.clients.hosts) { host in
                        Button {
                            model.switchEnvironment(.remote(target: host.target))
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.blue.opacity(0.12))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.blue)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.body.weight(.medium))
                                    Text(host.target)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if case .remote(let target) = model.currentEnvironment, target == host.target {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }

                Section("Recent Conversations") {
                    Button {
                        haptic()
                        if model.currentEnvironment.isLocal {
                            model.agentNewConversation()
                        } else {
                            Task { await model.remote.newSession() }
                        }
                        dismiss()
                    } label: {
                        Label("New Conversation", systemImage: "plus.circle.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    if model.currentEnvironment.isLocal {
                        let convs = (model.agent.state.conversations ?? []).filter { !$0.archived }
                        if convs.isEmpty {
                            Text("No conversations yet")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(convs) { conv in
                            Button {
                                haptic()
                                model.agentSwitch(conv.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conv.displayTitle)
                                            .font(.body)
                                            .lineLimit(1)
                                        Text(Date(timeIntervalSince1970: conv.updated / 1000), style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if conv.id == model.agent.state.conversationId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    } else {
                        if model.remote.sessions.isEmpty {
                            Text("No remote sessions")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.remote.sessions) { session in
                            Button {
                                haptic()
                                Task { await model.remote.attachSession(session.id) }
                                dismiss()
                            } label: {
                                HStack {
                                    Text(session.label)
                                        .lineLimit(1)
                                    Spacer()
                                    if session.id == model.remote.attachedId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        haptic()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Settings & Tools Modal Sheet

struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Preferences & Keys") {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Model Accounts & API Keys")
                                    .font(.body.weight(.medium))
                                Text("Anthropic, OpenAI, provider subscriptions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    NavigationLink {
                        ClientsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SSH Hosts & Device Key")
                                    .font(.body.weight(.medium))
                                Text("Manage remote machines & Ed25519 identity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Section("Distributed Spaces") {
                    NavigationLink {
                        SpacesView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spaces Pairing")
                                    .font(.body.weight(.medium))
                                Text("NetBird peer pairing & key enrollment")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "square.3.layers.3d.top.filled")
                                .foregroundStyle(.purple)
                        }
                    }

                    NavigationLink {
                        SpaceCtlView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Space Control Center")
                                    .font(.body.weight(.medium))
                                Text("Operations, distributed runs, workers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.indigo)
                        }
                    }
                }

                Section("System") {
                    HStack {
                        Text("Node Engine")
                        Spacer()
                        Text("24 LTS (Mobile)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let version = model.piVersion {
                        HStack {
                            Text("Pi Version")
                            Spacer()
                            Text(version.installed)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings & Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        haptic()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
    }
}
