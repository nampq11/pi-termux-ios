import SwiftUI

// Redesigned for PiMobile:
// SSH clients and identity management: Device Key card, remote host inventory,
// key provisioning, and full SSH terminal launcher.

public struct ClientsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var draftName = ""
    @State private var draftTarget = ""
    @State private var terminalTarget: String?
    @State private var copiedKey = false

    public init() {}

    public var body: some View {
        let clients = model.clients
        NavigationStack {
            List {
                keySection(clients)
                hostsSection(clients)
                if let message = clients.message ?? model.keyInstall.notice {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.accentColor)
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Clients & Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        haptic()
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Add remote host")
                }
            }
            .task { await clients.loadAll() }
            .refreshable { await clients.loadAll() }
            .sheet(isPresented: $adding) { addSheet(clients) }
            .navigationDestination(isPresented: Binding(
                get: { terminalTarget != nil },
                set: { if !$0 { terminalTarget = nil } }
            )) {
                if let terminalTarget {
                    TerminalScreen(target: terminalTarget)
                }
            }
        }
    }

    // MARK: - Device Key Section

    private func keySection(_ clients: ClientsModel) -> some View {
        Section("Device Identity") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "key.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH Keypair")
                            .font(.headline)
                        Text("Ed25519 authentication")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusPill(clients.keyExists ? .success : .warning,
                               text: clients.keyExists ? "Active" : "Missing")
                }

                if let pubkey = clients.keyPubkey {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pubkey)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))

                        Button {
                            UIPasteboard.general.string = pubkey
                            haptic()
                            withAnimation(PiTheme.snappySpring) {
                                copiedKey = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                withAnimation(PiTheme.snappySpring) {
                                    copiedKey = false
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: copiedKey ? "checkmark" : "doc.on.doc")
                                Text(copiedKey ? "Copied to Clipboard" : "Copy Public Key")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(copiedKey ? Color.green : Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                } else if !clients.keyExists {
                    Button {
                        haptic()
                        Task { await clients.generateKey() }
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Generate Ed25519 Key")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Hosts Section

    private func hostsSection(_ clients: ClientsModel) -> some View {
        Section("Remote Hosts") {
            if clients.hosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Text("No remote hosts configured")
                        .font(.subheadline.weight(.medium))
                    Text("Add a machine running SSH to execute code, run pi-serverd, or open full terminal sessions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    Button {
                        haptic()
                        adding = true
                    } label: {
                        Label("Add Host", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            ForEach(clients.hosts) { host in
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                            .font(.body.weight(.semibold))
                        Text(host.target)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Quick Actions
                    HStack(spacing: 8) {
                        Button {
                            haptic()
                            terminalTarget = host.target
                        } label: {
                            Image(systemName: "terminal")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open terminal on \(host.name)")

                        Button {
                            haptic()
                            model.keyInstall.begin(target: host.target)
                        } label: {
                            Image(systemName: "key")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 32, height: 32)
                                .background(Color.orange.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Install key on \(host.name)")
                    }
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await clients.deleteHost(host) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        terminalTarget = host.target
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                    }
                    Button {
                        model.keyInstall.begin(target: host.target)
                    } label: {
                        Label("Install Device Key…", systemImage: "key")
                    }
                    Button(role: .destructive) {
                        Task { await clients.deleteHost(host) }
                    } label: {
                        Label("Delete Host", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Add Host Sheet

    private func addSheet(_ clients: ClientsModel) -> some View {
        NavigationStack {
            Form {
                Section("Host Details") {
                    TextField("Friendly Name (e.g. Workstation)", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    TextField("user@host[:port]", text: $draftTarget)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.asciiCapable)
                }

                Section {
                    Text("After adding, PiMobile can automatically install your device key for passwordless SSH access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Remote Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        adding = false
                        draftName = ""; draftTarget = ""
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") {
                        let name = draftName.trimmingCharacters(in: .whitespaces)
                        let target = draftTarget.trimmingCharacters(in: .whitespaces)
                        guard !target.isEmpty else { return }
                        haptic()
                        adding = false
                        draftName = ""; draftTarget = ""
                        Task {
                            if let host = await clients.addHost(name: name, target: target) {
                                model.keyInstall.begin(target: host.target)
                            }
                        }
                    }
                    .font(.body.weight(.semibold))
                    .disabled(draftTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
