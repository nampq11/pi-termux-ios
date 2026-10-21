import SwiftUI

// The app's primary navigation on iOS:
// Chat, Remote, Clients, Spaces, Accounts.
// Features Apple-style tab iconography, haptic feedback, and the shared
// key-install modal flow.

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Tab.chat
    @State private var password = ""

    enum Tab: Hashable { case chat, remote, clients, spaces, accounts }

    var body: some View {
        @Bindable var model = model
        return TabView(selection: $selection) {
            AgentView()
                .tabItem { Label("Chat", systemImage: "sparkles") }
                .tag(Tab.chat)

            RemoteView()
                .tabItem { Label("Remote", systemImage: "server.rack") }
                .tag(Tab.remote)

            ClientsView()
                .tabItem { Label("Clients", systemImage: "desktopcomputer") }
                .tag(Tab.clients)

            NavigationStack { SpacesView() }
                .tabItem { Label("Spaces", systemImage: "square.3.layers.3d.top.filled") }
                .tag(Tab.spaces)

            NavigationStack { AccountsView() }
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)
        }
        .onChange(of: selection) { _, _ in
            haptic()
        }
        // The shared key-install flow, hosted once so Clients and the
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
