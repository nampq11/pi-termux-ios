import SwiftUI

// The app's primary navigation, mirroring the web UI's bottom bar on iOS:
// Chat, Remote, Clients, Spaces, Accounts. The local pi CLI terminal cannot
// run here (child processes are denied), so terminal screens are SSH-only
// and open from Clients. Feature tabs are added as their screens land.

struct MainTabView: View {
    @State private var selection = Tab.chat

    enum Tab: Hashable { case chat, clients, accounts }

    var body: some View {
        TabView(selection: $selection) {
            AgentView()
                .tabItem { Label("Chat", systemImage: "message.fill") }
                .tag(Tab.chat)
            ClientsView()
                .tabItem { Label("Clients", systemImage: "rectangle.connected.to.line.below") }
                .tag(Tab.clients)
            NavigationStack { AccountsView() }
                .tabItem { Label("Accounts", systemImage: "key") }
                .tag(Tab.accounts)
        }
    }
}
