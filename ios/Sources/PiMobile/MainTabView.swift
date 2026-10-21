import SwiftUI

// The app's primary navigation, mirroring the web UI's bottom bar on iOS:
// Chat, Remote, Clients, Spaces, Accounts. The local pi CLI terminal cannot
// run here (child processes are denied), so terminal screens are SSH-only
// and open from Clients. Feature tabs are added as their screens land.

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Tab.chat
    @State private var password = ""

    enum Tab: Hashable { case chat, remote, clients, spaces, accounts }

    var body: some View {
        @Bindable var model = model
        return TabView(selection: $selection) {
            AgentView()
                .tabItem { Label("Chat", systemImage: "message.fill") }
                .tag(Tab.chat)
            RemoteView()
                .tabItem { Label("Remote", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.remote)
            ClientsView()
                .tabItem { Label("Clients", systemImage: "rectangle.connected.to.line.below") }
                .tag(Tab.clients)
            NavigationStack { SpacesView() }
                .tabItem { Label("Spaces", systemImage: "square.3.layers.3d.top.filled") }
                .tag(Tab.spaces)
            NavigationStack { AccountsView() }
                .tabItem { Label("Accounts", systemImage: "key") }
                .tag(Tab.accounts)
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
            Button("Install key") { model.keyInstall.confirm() }
            Button("Cancel", role: .cancel) { model.keyInstall.cancel() }
        } message: {
            Text("The key lets this device sign in to \(model.keyInstall.target ?? "") without a password.")
        }
        .sheet(isPresented: Binding(
            get: { model.keyInstall.phase == .password },
            set: { if !$0, model.keyInstall.phase == .password { model.keyInstall.cancel() } }
        )) {
            passwordSheet
        }
        .alert("Key installation failed",
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
                SecureField("password", text: $password)
                    .onSubmit { submitPassword() }
                if model.keyInstall.passwordRejected {
                    Text("wrong password — try again")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Password for \(model.keyInstall.target ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.keyInstall.cancel()
                        password = ""
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Install key") { submitPassword() }
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
        Task { await model.keyInstall.submit(password: value) }
    }
}
