import SwiftUI

// Ported and redesigned for PiMobile:
// Modern Apple-grade coding agent interface: fluid spring motion, translucent
// materials, collapsible tool cards, syntax-highlighted diffs, and an ergonomic
// floating composer.

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
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if state.items.isEmpty {
                            intro(state)
                        }
                        ForEach(state.items) { item in
                            AgentItemView(item: item)
                        }
                        if let status = state.status {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(status)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                        if let error = state.error {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            .padding(10)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .environment(\.openURL, OpenURLAction { url in model.openDocsLink(url) ? .handled : .systemAction })
                .onChange(of: scrollKey(state)) { _, _ in
                    withAnimation(PiTheme.snappySpring) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                composer(state)
            }
            .navigationTitle(state.current?.displayTitle ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        haptic()
                        model.showSidebar = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Open workspaces drawer")
                }
                // Static environment badge + conversation title. Switching
                // environments lives in the ☰ drawer, conversation actions in
                // the ⋯ menu — one home per concern, no duplicate tap targets.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("📱 Local")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        Text(state.current?.displayTitle ?? "Agent")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: model.wide ? 360 : 220)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        haptic()
                        model.agentNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("New conversation")

                    menu(state)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { model.agentAccountsShown },
                set: { model.agentAccountsShown = $0 }
            )) {
                AccountsView()
            }
            .navigationDestination(isPresented: Binding(
                get: { model.agentListShown },
                set: { model.agentListShown = $0 }
            )) {
                ConversationsView()
            }
            .renameConversation($renaming)
            .alert(
                consent.map { "Send to \($0.providerName)?" } ?? "",
                isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } }),
                presenting: consent
            ) { c in
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
        .sheet(isPresented: Binding(
            get: { model.agentHost.loginProvider != nil },
            set: { if !$0 { model.agentCancelLogin() } }
        )) {
            LoginFlowView().environment(model)
        }
    }

    private func scrollKey(_ state: AgentState) -> String {
        "\(state.items.count):\(state.items.last?.text.count ?? 0):\(state.items.last?.status ?? ""):\(state.status ?? ""):\(state.error ?? "")"
    }

    private func intro(_ state: AgentState) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.top, 24)

                Text("How can I help you?")
                    .font(.title3.weight(.bold))

                Text("Ask questions, inspect files, or let pi assist with code on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if !state.signedIn {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                        Text("No Model Provider Configured")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    Text("Add your API key or sign in under Accounts to start talking to models.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        haptic()
                        model.agentAccountsShown = true
                    } label: {
                        Text("Configure Accounts")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    suggestionChip("What tools are available?")
                    suggestionChip("Explore this workspace structure")
                    suggestionChip("Check git status")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            haptic()
            draft = text
        } label: {
            HStack {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PiTheme.subtleBorder, lineWidth: 0.8))
        }
    }

    private func menu(_ state: AgentState) -> some View {
        Menu {
            if let current = state.current, current.title != nil {
                Button { renaming = current } label: { Label("Rename…", systemImage: "pencil") }
                Button { model.agentArchive(current.id, true) } label: { Label("Archive", systemImage: "archivebox") }
            }
            Button { model.agentListShown = true } label: { Label("Conversations", systemImage: "list.bullet") }
            Button { model.agentAccountsShown = true } label: { Label("Accounts…", systemImage: "person.crop.circle") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Agent options")
    }

    /// Floating bottom composer capsule
    private func composer(_ state: AgentState) -> some View {
        VStack(spacing: 8) {
            // Context header row: the model picker's single home (the ⋯ menu
            // no longer duplicates it). Shown whenever models are configured;
            // "Model" placeholder when none is selected so the entry point
            // never disappears.
            HStack(spacing: 8) {
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
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.caption2)
                            Text(state.model.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "Model")
                                .font(.caption2.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            // Text input and morphing action button
            HStack(alignment: .bottom, spacing: 8) {
                TextField(state.busy ? "Add instructions while running…" : "Message pi…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .submitLabel(.send)

                if state.busy && draft.isEmpty {
                    Button {
                        haptic()
                        model.agentStop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop generation")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.3))
                    }
                    .disabled(!canSend)
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

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        haptic()
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
            VStack(alignment: .trailing, spacing: 6) {
                if let path = item.path {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(item.line.map { "\(basename(path)):\($0)" } ?? basename(path))
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        PiTheme.userBubbleGradient,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .textSelection(.enabled)
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)

        case "assistant":
            VStack(alignment: .leading, spacing: 8) {
                if let thinking = item.thinking, !thinking.isEmpty {
                    thinkingView(thinking)
                }
                if !item.text.isEmpty {
                    Text(Self.markdown(item.text))
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else if item.streaming == true {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if let output = item.output, !output.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(item.status == "error" ? .red : .orange)
                        Text(output)
                            .font(.footnote)
                            .foregroundStyle(item.status == "error" ? .red : .secondary)
                    }
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)

        case "tool":
            toolView

        case "context":
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(item.path.map { p in item.line.map { "Now in \(basename(p)):\($0)" } ?? "Now in \(basename(p))" } ?? "No file open")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04), in: Capsule())
            .frame(maxWidth: .infinity)

        case "error":
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(item.text)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            .padding(10)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        default:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func thinkingView(_ thinking: String) -> some View {
        DisclosureGroup(
            isExpanded: $expanded,
            content: {
                Text(thinking)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.indigo)
                    Text("Thinking Process")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        )
        .padding(10)
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.indigo.opacity(0.15), lineWidth: 0.8))
    }

    private var toolView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                haptic()
                withAnimation(PiTheme.snappySpring) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(toolColor(item.tool ?? "").opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: Self.icon(item.tool ?? ""))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(toolColor(item.tool ?? ""))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(item.tool ?? ""))
                            .font(.subheadline.weight(.semibold))
                        if let summary = item.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    statusBadge
                }
                .contentShape(Rectangle())
            }
            .tint(.primary)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let diff = item.diff, !diff.isEmpty {
                        DiffView(diff: diff)
                    } else if let output = item.output, !output.isEmpty {
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
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if let images = item.images, images > 0 {
                        Label("\(images) image\(images == 1 ? "" : "s") shown to the model", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let path = item.path, ["read", "write", "edit", "run_python"].contains(item.tool ?? "") {
                        Button {
                            let file = joinPath(model.agent.state.project ?? "", path)
                            model.activeSheet = nil
                            Task { await model.openLocation(file, line: item.line, keepConsole: true) }
                        } label: {
                            Label("Open \(basename(path))", systemImage: "arrow.up.forward.square")
                        }
                        .font(.caption.weight(.medium))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PiTheme.subtleBorder, lineWidth: 0.8))
        .onAppear {
            if model.agentExpandEdits && item.tool == "edit" { expanded = true }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case "running", "pending":
            StatusPill(.running, text: "Running")
        case "error":
            StatusPill(.error, text: "Failed")
        default:
            Image(systemName: "chevron." + (expanded ? "up" : "down"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    private func toolColor(_ tool: String) -> Color {
        switch tool {
        case "read", "find", "grep", "ls": .blue
        case "write", "edit": .orange
        case "run_python", "bash", "sh": .green
        case "format", "check": .purple
        default: .gray
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
        case "run_python", "bash", "sh": "terminal"
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
        case "run_python", "bash", "sh": "Execute"
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
                    haptic()
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
            haptic()
            model.agentSwitch(c.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.displayTitle)
                        .font(.body.weight(c.id == state.conversationId ? .semibold : .regular))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(Date(timeIntervalSince1970: c.updated / 1000), style: .relative)
                        if c.project != state.root { Text("· \(displayName(c.project))") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if c.running { ProgressView().controlSize(.small) }
                if c.unread { Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                if c.id == state.conversationId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
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
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .padding(10)
        }
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PiTheme.subtleBorder, lineWidth: 0.8))
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
        case "+": .green.opacity(0.12)
        case "-": .red.opacity(0.12)
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
            Section("Runtime version") {
                if let v = model.piVersion {
                    HStack {
                        Text(v.installed).font(.callout.monospaced())
                        if v.updateAvailable {
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(v.canUpdate ? v.latest : "\(v.latest) — ships with next release")
                                .font(.callout.monospaced())
                        } else {
                            Spacer()
                            Label("up to date", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.loadAgentAccounts()
            await model.loadPiVersion()
        }
        .refreshable { await model.loadAgentAccounts() }
    }

    private func row(_ account: AgentAccount, oauth: Bool) -> some View {
        let type = oauth ? "oauth" : "api_key"
        let signedIn = account.signedIn == type
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                if account.featured {
                    Text(oauth ? "Sign in with \(account.name)" : "API Key")
                        .font(.body.weight(.medium))
                } else {
                    Text(oauth ? (account.oauthLabel ?? account.oauthName ?? account.name) : account.name)
                        .font(.body.weight(.medium))
                }
                if oauth && !account.featured {
                    Text("\(account.name) · \(account.id)").font(.caption2).foregroundStyle(.secondary)
                }
                if signedIn {
                    Text(oauth ? "Signed in" : "Key saved").font(.caption).foregroundStyle(.green)
                } else if account.signedIn != nil {
                    Text(account.signedIn == "oauth" ? "Signed in with account" : "Using API key").font(.caption).foregroundStyle(.secondary)
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
        .padding(.vertical, 2)
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
                        Button {
                            UIPasteboard.general.string = code.code
                            haptic()
                        } label: { Label("Copy Code", systemImage: "doc.on.doc") }
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
