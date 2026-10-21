import SwiftUI

// Native port of the web clients page: the device key section, the saved
// hosts, and their two actions — open a pi CLI terminal over ssh, and
// install the device key (the dialogs live in MainTabView, shared with the
// terminal screen).

public struct ClientsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var draftName = ""
    @State private var draftTarget = ""
    @State private var terminalTarget: String?

    public init() {}

    public var body: some View {
        let clients = model.clients
        NavigationStack {
            List {
                keySection(clients)
                hostsSection(clients)
                if let message = clients.message ?? model.keyInstall.notice {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Clients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add host")
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

    private func keySection(_ clients: ClientsModel) -> some View {
        Section("Device key") {
            HStack {
                Text(clients.keyExists ? "key exists (ed25519)" : "no key yet")
                    .foregroundStyle(clients.keyExists ? .primary : .secondary)
                Spacer()
                if !clients.keyExists {
                    Button("Generate key") { Task { await clients.generateKey() } }
                }
            }
            if let pubkey = clients.keyPubkey {
                Text(pubkey)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func hostsSection(_ clients: ClientsModel) -> some View {
        Section("Hosts") {
            if clients.hosts.isEmpty {
                Text("no hosts yet — add one with +")
                    .foregroundStyle(.secondary)
            }
            ForEach(clients.hosts) { host in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                        Text(host.target).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        terminalTarget = host.target
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open pi CLI on \(host.name)")
                    Button {
                        model.keyInstall.begin(target: host.target)
                    } label: {
                        Image(systemName: "key")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy key to \(host.name)")
                }
                .swipeActions {
                    Button(role: .destructive) { Task { await clients.deleteHost(host) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button { terminalTarget = host.target } label: { Label("Open terminal", systemImage: "terminal") }
                    Button { model.keyInstall.begin(target: host.target) } label: { Label("Copy key…", systemImage: "key") }
                    Button(role: .destructive) { Task { await clients.deleteHost(host) } } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    private func addSheet(_ clients: ClientsModel) -> some View {
        NavigationStack {
            Form {
                TextField("Name (optional)", text: $draftName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("user@host[:port]", text: $draftTarget)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .keyboardType(.asciiCapable)
            }
            .navigationTitle("Add host")
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
                        adding = false
                        draftName = ""; draftTarget = ""
                        Task {
                            // Web auto-flow: ensure the key exists, then offer the install.
                            if let host = await clients.addHost(name: name, target: target) {
                                model.keyInstall.begin(target: host.target)
                            }
                        }
                    }
                    .disabled(draftTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
