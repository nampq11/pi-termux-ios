import SwiftUI

// Ported from Terrarium (app/ios/Sources/Shell/AgentViews.swift):
// The coding agent: conversation transcript, conversations list, composer,
// model menu, and accounts sign-in sheet.

public func joinPath(_ a: String, _ b: String) -> String {
    a.isEmpty ? b : (b.isEmpty ? a : "\(a)/\(b)")
}

public struct AgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var renaming: AgentConversation?
    @State private var consent: SharingConsent?
    @FocusState private var composing: Bool

    /// A message held back until the user allows sending to its provider.
    private struct SharingConsent: Identifiable {
        let id = UUID()
        let provider: String
        let providerName: String
        let project: String
        let text: String
    }

    public init() {}

    public var body: some View {
        let state = model.agent.state
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if state.items.isEmpty { intro(state) }
                        ForEach(state.items) { item in
                            AgentItemView(item: item)
                        }
                        if let status = state.status {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let error = state.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .environment(\.openURL, OpenURLAction { url in model.openDocsLink(url) ? .handled : .systemAction })
                .onChange(of: scrollKey(state)) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { composer(state) }
            .navigationTitle(state.current?.displayTitle ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // If presented as a sheet or root, allows dismiss or placeholder
                }
                ToolbarItem(placement: .principal) { titleButton(state) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.agentNewConversation() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation")
                    menu(state)
                }
            }
            .navigationDestination(isPresented: Binding(get: { model.agentAccountsShown }, set: { model.agentAccountsShown = $0 })) {
                AccountsView()
            }
            .navigationDestination(isPresented: Binding(get: { model.agentListShown }, set: { model.agentListShown = $0 })) { ConversationsView() }
            .renameConversation($renaming)
            .alert(consent.map { "Send to \($0.providerName)?" } ?? "",
                   isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } }),
                   presenting: consent) { c in
                Button("Allow") {
                    model.agentAllowSharing(c.provider)
                    draft = ""
                    model.agentSend(c.text)
                }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text("To answer, the agent sends your messages and what it reads to \(c.providerName), the model provider you chose. \(c.providerName)'s terms and privacy policy apply to that data. You can sign out under Accounts at any time.")
            }
        }
        .task { await model.loadAgentModels() }
        .onAppear { model.agentSetVisible(true) }
        .onDisappear { model.agentSetVisible(false) }
        .sheet(isPresented: Binding(get: { model.agentHost.loginProvider != nil }, set: { if !$0 { model.agentCancelLogin() } })) {
            LoginFlowView().environment(model)
        }
    }

    /// The conversation's title; opens the list of conversations.
    private func titleButton(_ state: AgentState) -> some View {
        Button { model.agentListShown = true } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(state.current?.displayTitle ?? "Agent").font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if state.othersActive { Circle().fill(.tint).frame(width: 7, height: 7) }
                }
                Text(state.root.map(displayName) ?? "Main").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: model.wide ? 360 : 190)
        }
        .tint(.primary)
        .accessibilityLabel("Conversations")
    }

    private func scrollKey(_ state: AgentState) -> String {
        "\(state.items.count):\(state.items.last?.text.count ?? 0):\(state.items.last?.status ?? ""):\(state.status ?? ""):\(state.error ?? "")"
    }

    @ViewBuilder
    private func intro(_ state: AgentState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask questions, have pi write code, explain errors, or execute tools on the mobile runtime.")
                .foregroundStyle(.secondary)
            Text("Your messages go to the model provider you configure. Tap Accounts to configure your API keys.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !state.signedIn {
                Button { model.agentAccountsShown = true } label: { Label("Configure Model Provider", systemImage: "person.crop.circle.badge.plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func menu(_ state: AgentState) -> some View {
        Menu {
            if !model.agentModels.isEmpty {
                Menu {
                    let groups = Dictionary(grouping: model.agentModels, by: \.providerName)
                    ForEach(groups.keys.sorted(), id: \.self) { provider in
                        Section(provider) {
                            ForEach(groups[provider] ?? []) { option in
                                Button {
                                    model.agentSetModel(option)
                                } label: {
                                    if state.model?.provider == option.provider && state.model?.id == option.model {
                                        Label(option.name, systemImage: "checkmark")
                                    } else {
                                        Text(option.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(state.model?.name ?? "Model", systemImage: "cpu")
                }
            }
            if let current = state.current, current.title != nil {
                Button { renaming = current } label: { Label("Rename…", systemImage: "pencil") }
                Button { model.agentArchive(current.id, true) } label: { Label("Archive", systemImage: "archivebox") }
            }
            Button { model.agentListShown = true } label: { Label("Conversations", systemImage: "list.bullet") }
            Button { model.agentAccountsShown = true } label: { Label("Accounts…", systemImage: "person.crop.circle") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Agent options")
    }

    private func composer(_ state: AgentState) -> some View {
        VStack(spacing: 4) {
            if let m = state.model, !m.name.isEmpty {
                Text(m.name).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(state.busy ? "Add to the request…" : "Ask the agent…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .submitLabel(.send)
                if state.busy && draft.isEmpty {
                    Button { model.agentStop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .tint(.red)
                    .accessibilityLabel("Stop")
                } else {
                    Button { send() } label: {
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

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let state = model.agent.state
        if let m = state.model, !model.agentSharingAllowed(m.provider) {
            let name = model.agentModels.first { $0.provider == m.provider }?.providerName ?? m.provider
            consent = SharingConsent(provider: m.provider, providerName: name, project: state.project.map(displayName) ?? "this folder", text: text)
            return
        }
        draft = ""
        model.agentSend(text)
    }
}

/// One message, tool call, error or note.
public struct AgentItemView: View {
    public let item: AgentItem
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    public var body: some View {
        switch item.kind {
        case "user":
            VStack(alignment: .trailing, spacing: 4) {
                if let path = item.path {
                    Label(item.line.map { "\(basename(path)) · line \($0)" } ?? basename(path), systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case "assistant":
            VStack(alignment: .leading, spacing: 6) {
                if let thinking = item.thinking, !thinking.isEmpty {
                    DisclosureGroup("Thinking") {
                        Text(thinking).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.footnote)
                }
                if !item.text.isEmpty {
                    Text(Self.markdown(item.text)).textSelection(.enabled)
                } else if item.streaming == true {
                    ProgressView().controlSize(.small)
                }
                if let output = item.output, !output.isEmpty {
                    Label(output, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(item.status == "error" ? .red : .secondary)
                }
            }
            .padding(.trailing, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        case "tool":
            toolView
        case "context":
            Label(item.path.map { p in item.line.map { "Now in \(basename(p)) · line \($0)" } ?? "Now in \(basename(p))" } ?? "No file open",
                  systemImage: "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case "error":
            Label(item.text, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
        default:
            Text(item.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var toolView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.icon(item.tool ?? "")).frame(width: 18).foregroundStyle(.tint)
                    Text(Self.title(item.tool ?? "")).font(.subheadline.weight(.medium))
                    Text(item.summary ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    statusIcon
                }
                .contentShape(Rectangle())
            }
            .tint(.primary)
            if expanded {
                if let diff = item.diff, !diff.isEmpty {
                    DiffView(diff: diff)
                } else if let output = item.output, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output.count > 4000 ? String(output.prefix(4000)) + "\n…" : output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                if let images = item.images, images > 0 {
                    Label("\(images) image\(images == 1 ? "" : "s") shown to the model", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                }
                if let path = item.path, ["read", "write", "edit", "run_python"].contains(item.tool ?? "") {
                    Button {
                        let file = joinPath(model.agent.state.project ?? "", path)
                        model.activeSheet = nil
                        Task { await model.openLocation(file, line: item.line, keepConsole: true) }
                    } label: { Label("Open \(basename(path))", systemImage: "arrow.up.forward.square") }
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { if model.agentExpandEdits && item.tool == "edit" { expanded = true } }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case "running", "pending": ProgressView().controlSize(.small)
        case "error": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default: Image(systemName: "chevron.\(expanded ? "up" : "down")").font(.caption2).foregroundStyle(.secondary)
        }
    }

    public static func icon(_ tool: String) -> String {
        switch tool {
        case "read": "doc.text"
        case "write": "doc.badge.plus"
        case "edit": "pencil"
        case "ls": "folder"
        case "find": "doc.text.magnifyingglass"
        case "grep": "magnifyingglass"
        case "run_python", "bash", "sh": "play.fill"
        case "check": "checkmark.seal"
        case "format": "wand.and.stars"
        default: "wrench.and.screwdriver"
        }
    }

    public static func title(_ tool: String) -> String {
        switch tool {
        case "read": "Read"
        case "write": "Write"
        case "edit": "Edit"
        case "ls": "List"
        case "find": "Find"
        case "grep": "Search"
        case "run_python", "bash", "sh": "Run"
        case "check": "Check"
        case "format": "Format"
        default: tool
        }
    }

    public static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The project's conversations: newest first, archived ones apart.
public struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: AgentConversation?

    public init() {}

    public var body: some View {
        let state = model.agent.state
        let all = state.conversations ?? []
        let archived = all.filter(\.archived)
        List {
            Section {
                ForEach(all.filter { !$0.archived }) { row($0, state) }
            }
            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { row($0, state) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(state.root.map(displayName) ?? "Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.agentNewConversation()
                    dismiss()
                } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
            }
        }
        .renameConversation($renaming)
    }

    private func row(_ c: AgentConversation, _ state: AgentState) -> some View {
        Button {
            model.agentSwitch(c.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.displayTitle).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(Date(timeIntervalSince1970: c.updated / 1000), style: .relative)
                        if c.project != state.root { Text("· \(displayName(c.project))") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if c.running { ProgressView().controlSize(.small) }
                if c.unread { Circle().fill(.tint).frame(width: 9, height: 9).accessibilityLabel("Unread") }
                if c.id == state.conversationId { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .swipeActions {
            if c.archived {
                Button { model.agentArchive(c.id, false) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
            } else {
                Button { model.agentArchive(c.id, true) } label: { Label("Archive", systemImage: "archivebox") }.tint(.indigo)
            }
        }
        .contextMenu {
            Button { renaming = c } label: { Label("Rename…", systemImage: "pencil") }
            if c.archived {
                Button { model.agentArchive(c.id, false) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
            } else {
                Button { model.agentArchive(c.id, true) } label: { Label("Archive", systemImage: "archivebox") }
            }
        }
    }
}

private struct RenameConversation: ViewModifier {
    @Binding var conversation: AgentConversation?
    @Environment(AppModel.self) private var model
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Conversation", isPresented: Binding(get: { conversation != nil }, set: { if !$0 { conversation = nil } })) {
                TextField("Title", text: $title)
                Button("Save") {
                    if let c = conversation, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.agentRename(c.id, title.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    conversation = nil
                }
                Button("Cancel", role: .cancel) { conversation = nil }
            }
            .onChange(of: conversation) { _, c in title = c?.title ?? "" }
    }
}

extension View {
    func renameConversation(_ conversation: Binding<AgentConversation?>) -> some View {
        modifier(RenameConversation(conversation: conversation))
    }
}

/// A diff from edit (numbered +/- lines) or format (a unified patch).
public struct DiffView: View {
    public let diff: String

    public init(diff: String) {
        self.diff = diff
    }

    public var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(200)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.caption.monospaced())
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .padding(8)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func kind(_ line: Substring) -> Character? {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("Index") || line.hasPrefix("===") { return "@" }
        return line.first(where: { $0 != " " && !$0.isNumber }).flatMap { $0 == "+" || $0 == "-" ? $0 : nil }
    }

    private func color(_ line: Substring) -> Color {
        switch kind(line) {
        case "+": .green
        case "-": .red
        case "@": .secondary
        default: .primary
        }
    }

    private func background(_ line: Substring) -> Color {
        switch kind(line) {
        case "+": .green.opacity(0.1)
        case "-": .red.opacity(0.1)
        default: .clear
        }
    }
}

/// Providers: sign in with a subscription, add an API key, sign out.
public struct AccountsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        let featured = model.agentAccounts.filter(\.featured)
        let accounts = model.agentAccounts.filter { !$0.featured }
        List {
            if let error = model.agentLoginError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote) }
            }
            ForEach(featured) { account in
                Section {
                    if account.oauthName != nil { row(account, oauth: true) }
                    if account.apiKeyName != nil { row(account, oauth: false) }
                } header: {
                    Text(account.name)
                }
            }
            Section {
                ForEach(accounts.filter { $0.oauthName != nil && $0.subscription }) { row($0, oauth: true) }
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("Sign in with an existing plan. The sign-in page opens in a browser sheet.")
            }
            Section {
                ForEach(accounts.filter { $0.oauthName != nil && !$0.subscription }) { row($0, oauth: true) }
            } header: {
                Text("Other Sign-Ins")
            }
            Section {
                ForEach(accounts.filter { $0.apiKeyName != nil }) { row($0, oauth: false) }
            } header: {
                Text("API Keys")
            } footer: {
                Text("Keys are sent to their provider.")
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadAgentAccounts() }
        .refreshable { await model.loadAgentAccounts() }
    }

    private func row(_ account: AgentAccount, oauth: Bool) -> some View {
        let type = oauth ? "oauth" : "api_key"
        let signedIn = account.signedIn == type
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                if account.featured {
                    Text(oauth ? "Sign in with \(account.name)" : "API Key")
                } else {
                    Text(oauth ? (account.oauthLabel ?? account.oauthName ?? account.name) : account.name)
                }
                if oauth && !account.featured {
                    Text("\(account.name) · \(account.id)").font(.caption2).foregroundStyle(.secondary)
                }
                if signedIn {
                    Text(oauth ? "Signed in" : "Key saved").font(.caption).foregroundStyle(.green)
                } else if account.signedIn != nil {
                    Text(account.signedIn == "oauth" ? "Signed in with an account" : "Using an API key").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if signedIn {
                Button("Sign Out", role: .destructive) { Task { await model.agentLogout(account.id) } }
                    .buttonStyle(.borderless)
            } else {
                Button(oauth ? "Sign In" : "Add Key") { Task { await model.agentLogin(account.id, type) } }
                    .buttonStyle(.bordered)
                    .disabled(model.agentHost.loginProvider != nil)
            }
        }
    }
}

public struct LoginFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var answer = ""

    public init() {}

    public var body: some View {
        let host = model.agentHost
        NavigationStack {
            Form {
                if let code = host.deviceCode {
                    Section {
                        Text(code.code).font(.system(.largeTitle, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                        Button { UIPasteboard.general.string = code.code } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                    } header: {
                        Text("Your code")
                    }
                    Section {
                        if let url = URL(string: code.uri), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) {
                                Label(Self.displayURL(code.uri), systemImage: "safari").font(.body.monospaced())
                            }
                            .contextMenu {
                                Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
                            }
                        } else {
                            Text(code.uri).font(.body.monospaced()).textSelection(.enabled)
                        }
                    } header: {
                        Text("Enter it at")
                    } footer: {
                        Text("Open this address on any device, or tap it to open it here, and enter the code. This sheet closes by itself when you are done.")
                    }
                }
                if let prompt = host.prompt {
                    Section {
                        if prompt.type == "select" {
                            ForEach(prompt.options) { option in
                                Button {
                                    host.answerPrompt(option.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(option.label)
                                        if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        } else {
                            Group {
                                if prompt.type == "secret" {
                                    SecureField(prompt.placeholder ?? "", text: $answer)
                                } else {
                                    TextField(prompt.placeholder ?? "", text: $answer)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit(submit)
                            Button("Continue", action: submit)
                                .disabled(answer.isEmpty && prompt.type != "text")
                        }
                    } header: {
                        Text(prompt.message)
                    } footer: {
                        if prompt.type == "manual_code" {
                            Text("Usually the sign-in finishes by itself when you return from the browser. If it does not, paste the code or the address the browser ended on.")
                        }
                    }
                    .onChange(of: prompt.id) { _, _ in answer = "" }
                }
                if !host.progress.isEmpty {
                    Section {
                        ForEach(Array(host.progress.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if host.prompt == nil && host.deviceCode == nil {
                    Section { HStack { ProgressView(); Text("Signing in…").foregroundStyle(.secondary) } }
                }
            }
            .navigationTitle(model.agentAccounts.first { $0.id == host.loginProvider }?.name ?? "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.agentCancelLogin() } } }
        }
        .interactiveDismissDisabled()
    }

    /// "https://radius.earendil.com/pair/" -> "radius.earendil.com/pair": short enough to type on another device.
    public static func displayURL(_ uri: String) -> String {
        var text = uri
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func submit() {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = ""
        model.agentHost.answerPrompt(value)
    }
}
