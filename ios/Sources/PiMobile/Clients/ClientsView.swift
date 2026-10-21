import SwiftUI

// Native port of the web clients page: the device key section, the saved
// hosts, and the ⇧key password flow for installing the key on a host.

public struct ClientsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var draftName = ""
    @State private var draftTarget = ""
    @State private var password = ""

    public init() {}

    public var body: some View {
        let clients = model.clients
        NavigationStack {
            List {
                keySection(clients)
                hostsSection(clients)
                if let message = clients.message {
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
            .confirmationDialog(
                "Install the device key on \(clients.copyIdHost?.name ?? "")?",
                isPresented: copyIdBinding(clients, .confirm),
                titleVisibility: .visible
            ) {
                Button("Install key") { clients.confirmInstallKey() }
                Button("Cancel", role: .cancel) { clients.cancelInstallKey() }
            } message: {
                Text("The key lets this device sign in to \(clients.copyIdHost?.target ?? "") without a password.")
            }
            .sheet(isPresented: copyIdBinding(clients, .password)) { passwordSheet(clients) }
            .alert("Key installation failed",
                   isPresented: Binding(get: { clients.copyIdError != nil }, set: { if !$0 { clients.copyIdError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clients.copyIdError ?? "")
            }
        }
    }

    private func copyIdBinding(_ clients: ClientsModel, _ phase: ClientsModel.CopyIdPhase) -> Binding<Bool> {
        Binding(
            get: { clients.copyIdPhase == phase && clients.copyIdHost != nil },
            set: { if !$0 && clients.copyIdPhase == phase { clients.cancelInstallKey() } }
        )
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
                        clients.beginInstallKey(host)
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
                    Button { clients.beginInstallKey(host) } label: { Label("Copy key…", systemImage: "key") }
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
                        Task { _ = await clients.addHost(name: name, target: target) }
                    }
                    .disabled(draftTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func passwordSheet(_ clients: ClientsModel) -> some View {
        NavigationStack {
            Form {
                SecureField("password", text: $password)
                    .onSubmit { submitPassword(clients) }
                if clients.passwordRejected {
                    Text("wrong password — try again")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Password for \(clients.copyIdHost?.target ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        clients.cancelInstallKey()
                        password = ""
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Install key") { submitPassword(clients) }
                        .disabled(password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: clients.passwordRejected) { _, rejected in
            if rejected { password = "" }
        }
    }

    private func submitPassword(_ clients: ClientsModel) {
        let value = password
        password = ""
        Task { await clients.submitPassword(value) }
    }
}
