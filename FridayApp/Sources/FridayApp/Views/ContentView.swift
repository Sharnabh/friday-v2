import SwiftUI
import FridayCore

enum DesktopTheme {
    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.051, green: 0.067, blue: 0.090) : .white
    }

    static func sidebar(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.004, green: 0.016, blue: 0.035)
                        : Color(red: 0.965, green: 0.973, blue: 0.98)
    }

    static func field(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.086, green: 0.106, blue: 0.133) : .white
    }

    static func userBubble(for scheme: ColorScheme) -> Color {
        accent.opacity(scheme == .dark ? 0.2 : 0.075)
    }

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.290, green: 0.518, blue: 0.996, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.325, blue: 0.992, alpha: 1)
    })
}

func avatarInitials(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(separator: " ")
    if words.count >= 2 {
        return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
    }
    return String(trimmed.prefix(2)).uppercased()
}

func avatarColor(for name: String) -> Color {
    let palette: [Color] = [
        Color(red: 0.0, green: 0.659, blue: 0.518),   // Emerald Green
        Color(red: 0.180, green: 0.596, blue: 0.859), // Ocean Blue
        Color(red: 0.918, green: 0.412, blue: 0.122), // Coral Orange
        Color(red: 0.608, green: 0.349, blue: 0.714), // Royal Purple
        Color(red: 0.906, green: 0.298, blue: 0.235), // Ruby Red
        Color(red: 0.086, green: 0.627, blue: 0.522)  // Dark Teal
    ]
    let hash = abs(name.hashValue)
    return palette[hash % palette.count]
}

// MARK: - Main ContentView

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("friday.setupVisited") private var setupVisited = false
    @State private var showCreateBot = false
    @State private var showCreateGroup = false
    @State private var newBotName = ""
    @State private var newBotInstructions = ""
    @State private var newBotVoice = ""
    @State private var newBotRole: BotRolePreset = .auto
    @State private var newGroupName = ""
    @State private var selectedGroupMembers = Set<String>()
    @State private var searchChatQuery = ""

    private func workspaceLink(_ title: String, icon: String, tab: Int) -> some View {
        Button { state.selectedTab = tab } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.selectedTab == tab ? DesktopTheme.accent : Color.primary)
        .accessibilityAddTraits(state.selectedTab == tab ? .isSelected : [])
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesktopTheme.accent)
                            .frame(width: 36, height: 36)
                        Image(systemName: "waveform")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }

                    Text("FRIDAY")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        showCreateBot = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Custom Bot")

                    Button {
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Multi-Bot Group")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(DesktopTheme.sidebar(for: colorScheme))

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    TextField("Find bots and groups", text: $searchChatQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DesktopTheme.field(for: colorScheme))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // Contact & Group Chat List
                List(selection: $state.activeBotId) {
                    Section("Assistant") {
                        NavigationLink(value: "") {
                            ConversationRow(
                                name: state.fridayName,
                                subtitle: state.latestSnippet(for: ""),
                                isGroup: false,
                                isCore: true
                            )
                        }
                        .contextMenu {
                            Button {
                                state.openPersonaEditor(for: "")
                            } label: {
                                Label("Edit Persona & Instructions…", systemImage: "slider.horizontal.3")
                            }
                        }
                    }

                    if !filteredBots.isEmpty {
                        Section("Bots") {
                            ForEach(filteredBots) { bot in
                                NavigationLink(value: bot.id) {
                                    ConversationRow(
                                        name: bot.name,
                                        subtitle: state.latestSnippet(for: bot.id),
                                        isGroup: false,
                                        isCore: false
                                    )
                                }
                                .contextMenu {
                                    Button {
                                        state.openPersonaEditor(for: bot.id)
                                    } label: {
                                        Label("Edit Persona & Instructions…", systemImage: "slider.horizontal.3")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        state.deleteBot(id: bot.id)
                                    } label: {
                                        Label("Delete Bot", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    if !filteredGroups.isEmpty {
                        Section("Groups") {
                            ForEach(filteredGroups) { group in
                                NavigationLink(value: group.id) {
                                    ConversationRow(
                                        name: group.name,
                                        subtitle: "\(group.members.count) members",
                                        isGroup: true,
                                        isCore: false
                                    )
                                }
                                .contextMenu {
                                    Button {
                                        state.openGroupEditor(groupId: group.id)
                                    } label: {
                                        Label("Manage Group Members…", systemImage: "person.2.badge.gearshape")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        state.deleteGroup(id: group.id)
                                    } label: {
                                        Label("Delete Group", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    Section("Workspaces") {
                        workspaceLink("Chat", icon: "bubble.left.and.bubble.right", tab: 0)
                        workspaceLink("Memory Vault", icon: "brain.head.profile", tab: 1)
                        workspaceLink("Reminders & Tasks", icon: "clock.badge.checkmark", tab: 2)
                        workspaceLink("Tools & workspaces", icon: "wrench.and.screwdriver", tab: 3)
                        workspaceLink("Settings", icon: "gearshape", tab: 4)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .disabled(state.isBusy)
            }
            .background(DesktopTheme.sidebar(for: colorScheme))
            .navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 290)
            .navigationTitle("")
        } detail: {
            Group {
                switch state.selectedTab {
                case 4: SettingsWorkspace()
                case 3: ToolsWorkspace()
                case 1:
                    MemoryView()
                case 2:
                    RemindersView()
                default:
                    ChatView()
                }
            }
        }
        .onAppear {
            if !setupVisited {
                setupVisited = true
                state.selectedTab = 4
            }
        }
        .sheet(isPresented: $state.showScreenPermissionHelp) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Allow screen capture").font(.headline)
                Text("Open Screen Recording settings, then drag FRIDAY into the list and enable it.")
                Label("FRIDAY", systemImage: "app.dashed")
                    .padding(10)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                HStack {
                    Button("Open Screen Recording settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Done") { state.showScreenPermissionHelp = false }
                }
            }.padding(20).frame(width: 370)
        }
        .sheet(isPresented: $showCreateBot) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Create Assistant Bot")
                    .font(.headline)
                TextField("Bot Name", text: $newBotName)
                    .textFieldStyle(.roundedBorder)
                TextField("System Instructions", text: $newBotInstructions, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Voice", selection: $newBotVoice) {
                        ForEach(HeyGenTTSCatalog.voices) { v in
                            Text(v.label).tag(v.id)
                        }
                    }
                    Button("Preview") {
                        state.previewVoice(newBotVoice, botName: newBotName)
                    }
                }
                Picker("Task Role", selection: $newBotRole) {
                    ForEach(BotRolePreset.allCases) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showCreateBot = false }
                    Button("Create") {
                        if !newBotName.isEmpty {
                            state.createBot(name: newBotName, instructions: newBotInstructions, voice: newBotVoice, role: newBotRole)
                            newBotName = ""
                            newBotInstructions = ""
                            newBotVoice = ""
                            newBotRole = .auto
                            showCreateBot = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 420)
        }
        .sheet(isPresented: $showCreateGroup) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Create Multi-Bot Group")
                    .font(.headline)
                TextField("Group Name", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)

                Text("Select participating bots:")
                    .font(.subheadline)
                List {
                    ForEach([""] + state.bots.map { $0.id }, id: \.self) { botId in
                        let name = botId.isEmpty ? state.fridayName : (state.bots.first(where: { $0.id == botId })?.name ?? "FRIDAY")
                        Toggle(name, isOn: Binding(
                            get: { selectedGroupMembers.contains(botId) },
                            set: { on in
                                if on { selectedGroupMembers.insert(botId) }
                                else { selectedGroupMembers.remove(botId) }
                            }
                        ))
                    }
                }
                .frame(height: 140)

                HStack {
                    Spacer()
                    Button("Cancel") { showCreateGroup = false }
                    Button("Create Group") {
                        if !newGroupName.isEmpty && selectedGroupMembers.count >= 2 {
                            state.createGroup(name: newGroupName, memberIds: Array(selectedGroupMembers))
                            newGroupName = ""
                            selectedGroupMembers.removeAll()
                            showCreateGroup = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newGroupName.isEmpty || selectedGroupMembers.count < 2)
                }
            }
            .padding()
            .frame(width: 420)
        }
        .sheet(isPresented: $state.showEditPersonaModal) {
            PersonaEditorView()
        }
        .sheet(isPresented: $state.showEditGroupModal) {
            EditGroupModalView()
        }
    }

    private var filteredBots: [BotProfile] {
        if searchChatQuery.isEmpty { return state.bots }
        return state.bots.filter { $0.name.localizedCaseInsensitiveContains(searchChatQuery) }
    }

    private var filteredGroups: [BotGroup] {
        if searchChatQuery.isEmpty { return state.groups }
        return state.groups.filter { $0.name.localizedCaseInsensitiveContains(searchChatQuery) }
    }
}


struct ConversationRow: View {
    let name: String
    let subtitle: String
    let isGroup: Bool
    let isCore: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCore ? DesktopTheme.accent : avatarColor(for: name))
                    .frame(width: 30, height: 30)

                if isGroup {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                } else if isCore {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                } else {
                    Text(avatarInitials(for: name))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}


struct ChatView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var showSettingsBar = false
    @State private var composerHeight: CGFloat = 22
    @State private var composerFocusTrigger: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Contact Avatar
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(state.activeBotId.isEmpty ? DesktopTheme.accent : avatarColor(for: state.currentBotDisplayName))
                        .frame(width: 40, height: 40)

                    if state.isGroupSelected {
                        Image(systemName: "person.3.sequence.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                    } else if state.activeBotId.isEmpty {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    } else {
                        Text(avatarInitials(for: state.currentBotDisplayName))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                // Contact Title & Status
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.currentBotDisplayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    if let task=state.controlTask {Button("Stop action"){task.cancel()}}
                    if state.isBusy || state.statusMessage != "Ready" {
                        Text(state.statusMessage)
                            .lineLimit(2)
                            .help(state.statusMessage)
                            .font(.system(size: 12))
                            .foregroundColor(DesktopTheme.accent)
                    } else if state.isGroupSelected {
                        Button {
                            state.openGroupEditor(groupId: state.activeBotId)
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(state.groupMembers.count) participants")
                                Image(systemName: "pencil.circle")
                                    .font(.system(size: 11))
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Manage Group Members")
                    } else {
                        Text(state.model.isEmpty ? "Hermes default" : state.model)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Session Picker
                if !state.savedSessions.isEmpty {
                    Picker("", selection: $state.currentSessionId) {
                        ForEach(state.savedSessions) { sess in
                            Text(sess.title).tag(sess.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(state.isBusy)
                    .frame(maxWidth: 160)
                    .onChange(of: state.currentSessionId) { _, newId in
                        state.selectSession(newId)
                    }
                }

                // Edit Persona or Manage Group Action
                if state.isGroupSelected {
                    Button {
                        state.openGroupEditor(groupId: state.activeBotId)
                    } label: {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Manage Group Members & Settings")
                } else {
                    Button {
                        state.openPersonaEditor()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit Persona & Instructions")
                }

                // New Chat Button
                Button {
                    state.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
                .keyboardShortcut("n", modifiers: .command)
                .help("New Conversation")

                // Auto-Speak (TTS) Toggle
                Button {
                    state.isTTSEnabled.toggle()
                } label: {
                    Image(systemName: state.isTTSEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 15))
                        .foregroundColor(state.isTTSEnabled ? DesktopTheme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(state.isWakeEnabled)
                .help(state.isWakeEnabled ? "Voice replies stay on while Hey Friday is active" : (state.isTTSEnabled ? "Disable Auto Voice Replies" : "Enable Auto Voice Replies"))

                // Settings Bar Toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsBar.toggle()
                    }
                } label: {
                    Image(systemName: showSettingsBar ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 15))
                        .foregroundColor(showSettingsBar ? DesktopTheme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .help("Audio & Model Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DesktopTheme.sidebar(for: colorScheme))

            if showSettingsBar {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Conversation settings").font(.headline)
                        Spacer()
                        Button("All settings") { state.selectedTab = 4 }
                    }
                    if !state.availableMics.isEmpty {
                        Picker("Mic", selection: $state.selectedMic) {
                            ForEach(state.availableMics, id: \.self) { mic in
                                Text(mic).tag(mic)
                            }
                        }
                        .frame(maxWidth: 140)
                    }

                    HStack(spacing: 14) {
                    Toggle("Hey Friday", isOn: $state.isWakeEnabled)
                        .toggleStyle(.switch)

                    Toggle("Speak Replies", isOn: $state.isTTSEnabled)
                        .toggleStyle(.switch)
                        .disabled(state.isWakeEnabled)
                        .help(state.isWakeEnabled ? "Always on when Hey Friday is enabled" : "Toggle automatic voice replies")

                    Button {
                        AssistantService.shared.stopSpeaking()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .help("Stop Current Speech")
                    }
                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.electron.wispr-flow") != nil {
                        Button("Wispr Flow"){
                            state.isWakeEnabled=false
                            if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.electron.wispr-flow") {
                                let config=NSWorkspace.OpenConfiguration();config.activates=false
                                NSWorkspace.shared.openApplication(at:url,configuration:config){_,_ in}
                            }
                            composerFocusTrigger += 1
                            state.statusMessage="Use your Flow dictation shortcut, then review the message."
                        }
                    }

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(DesktopTheme.sidebar(for: colorScheme).opacity(0.85))
                Divider()
            }

            if state.audioLevel > 0.05 {
                ProgressView(value: state.audioLevel)
                    .progressViewStyle(.linear)
                    .tint(DesktopTheme.accent)
                    .padding(.horizontal)
            }

            ZStack(alignment: .top) {
                DesktopTheme.canvas(for: colorScheme)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    let botNames = state.mentionableBots.map(\.name)
                    let lastIndex = state.currentTranscript.indices.last
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(state.currentTranscript.enumerated()), id: \.offset) { index, turn in
                                ChatBubble(
                                    text: turn,
                                    botNames: botNames,
                                    isStreamingTurn: state.isBusy && index == lastIndex
                                )
                                .id(index)
                            }
                        }
                        .frame(maxWidth: 780)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: state.currentTranscript.count) { _, _ in
                        if let last = state.currentTranscript.indices.last {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: state.currentTranscript.last) { _, _ in
                        if let last = state.currentTranscript.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }

                // ChatGPT/Gemini-Style Floating Memory Notification Pill
                if state.showMemoryToast, let notice = state.lastMemoryUpdateNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(DesktopTheme.accent)
                            .font(.system(size: 13, weight: .semibold))

                        Text("Memory updated:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)

                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Button {
                            state.selectedTab = 1
                            state.showMemoryToast = false
                        } label: {
                            Text("Manage")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(DesktopTheme.accent)
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                state.showMemoryToast = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(DesktopTheme.field(for: colorScheme))
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
                    .overlay(Capsule().stroke(DesktopTheme.accent.opacity(0.4), lineWidth: 1))
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                }
            }

            // Mention Suggestions Popup (Floating above input bar)
            if state.currentMentionQuery != nil && !state.matchingMentionBots.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Mention a Bot")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("tap to select")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    Divider().padding(.horizontal, 8)

                    ForEach(state.matchingMentionBots) { bot in
                        Button {
                            state.insertMention(bot)
                        } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(bot.id.isEmpty ? DesktopTheme.accent : avatarColor(for: bot.name))
                                        .frame(width: 24, height: 24)
                                    Text(avatarInitials(for: bot.name))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                Text("@\(bot.name)")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(bot.role)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(DesktopTheme.sidebar(for: colorScheme))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Attachment Button
                Button {
                    withAnimation { showSettingsBar.toggle() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Quick Settings")

                HStack {
                    MessageComposer(
                        text: $state.inputMessage,
                        dynamicHeight: $composerHeight,
                        isDisabled: state.isBusy,
                        focusTrigger: composerFocusTrigger,
                        onSubmit: { state.sendMessage() }
                    )
                    .frame(height: composerHeight)
                }
                .padding(.vertical, 7)

                if state.inputMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        state.toggleVoiceRecording()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(state.isVoiceActive ? Color.red : Color.secondary.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: state.isVoiceActive ? "waveform" : "mic.fill")
                                .font(.system(size: 16))
                                .foregroundColor(state.isVoiceActive ? .white : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Record Voice Message")
                } else {
                    Button {
                        state.sendMessage()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(DesktopTheme.accent)
                                .frame(width: 36, height: 36)
                            if state.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .colorInvert()
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isBusy)
                    .help("Send Message")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 780)
            .background(DesktopTheme.field(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.28)))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(DesktopTheme.canvas(for: colorScheme))
        }
    }
}

// MARK: - Markdown Parser & Formatted Views

struct OrderedListItem: Equatable, Identifiable {
    let id = UUID()
    let number: String
    let text: String

    static func == (lhs: OrderedListItem, rhs: OrderedListItem) -> Bool {
        lhs.number == rhs.number && lhs.text == rhs.text
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case codeBlock(language: String, code: String)
    case quote(text: String)
    case unorderedList(items: [String])
    case orderedList(items: [OrderedListItem])
    case table(headers: [String], rows: [[String]])
    case divider
    case paragraph(text: String)
}

func parseMarkdown(_ input: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    let lines = input.components(separatedBy: "\n")
    var i = 0
    let count = lines.count

    while i < count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            i += 1
            continue
        }

        // Fenced code block (```lang ... ```)
        if trimmed.hasPrefix("```") {
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < count {
                let codeLine = lines[i]
                if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                codeLines.append(codeLine)
                i += 1
            }
            blocks.append(.codeBlock(language: lang.isEmpty ? "code" : lang, code: codeLines.joined(separator: "\n")))
            continue
        }

        // Horizontal rule
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            blocks.append(.divider)
            i += 1
            continue
        }

        // Headings (# Heading)
        if trimmed.hasPrefix("#") {
            var level = 0
            for char in trimmed {
                if char == "#" { level += 1 } else { break }
            }
            if level <= 6 && trimmed.count > level && trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                let hText = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: hText))
                i += 1
                continue
            }
        }

        // Blockquotes (> Quote)
        if trimmed.hasPrefix(">") {
            var quoteLines: [String] = []
            while i < count {
                let qLine = lines[i].trimmingCharacters(in: .whitespaces)
                if qLine.hasPrefix(">") {
                    let text = qLine.hasPrefix("> ") ? String(qLine.dropFirst(2)) : String(qLine.dropFirst(1))
                    quoteLines.append(text)
                    i += 1
                } else {
                    break
                }
            }
            blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
            continue
        }

        // Markdown Table (| Header 1 | Header 2 |)
        if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.contains("|") {
            var tableLines: [String] = []
            while i < count {
                let tLine = lines[i].trimmingCharacters(in: .whitespaces)
                if tLine.hasPrefix("|") && tLine.hasSuffix("|") {
                    tableLines.append(tLine)
                    i += 1
                } else {
                    break
                }
            }
            if tableLines.count >= 2 {
                let parseRow: (String) -> [String] = { r in
                    let parts = r.split(separator: "|", omittingEmptySubsequences: false)
                    return parts.dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let headers = parseRow(tableLines[0])
                var rows: [[String]] = []
                for rowIdx in 2..<tableLines.count {
                    let row = parseRow(tableLines[rowIdx])
                    if !row.isEmpty && !row.allSatisfy({ $0.contains("-") }) {
                        rows.append(row)
                    }
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
        }

        // Unordered list (- item, * item, • item, + item)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("+ ") {
            var listItems: [String] = []
            while i < count {
                let rawLine = lines[i]
                let lTrimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if lTrimmed.isEmpty {
                    if i + 1 < count {
                        let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        if nextTrimmed.hasPrefix("- ") || nextTrimmed.hasPrefix("* ") || nextTrimmed.hasPrefix("• ") || nextTrimmed.hasPrefix("+ ") {
                            i += 1
                            continue
                        }
                    }
                    break
                }
                if lTrimmed.hasPrefix("- ") || lTrimmed.hasPrefix("* ") || lTrimmed.hasPrefix("• ") || lTrimmed.hasPrefix("+ ") {
                    let item = String(lTrimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    listItems.append(item)
                    i += 1
                } else if (rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")) && !listItems.isEmpty {
                    listItems[listItems.count - 1] += "\n" + lTrimmed
                    i += 1
                } else {
                    break
                }
            }
            blocks.append(.unorderedList(items: listItems))
            continue
        }

        // Ordered list (1. item, 1) item)
        let firstWord = trimmed.prefix(while: { $0.isNumber || $0 == "." || $0 == ")" })
        if (firstWord.hasSuffix(".") || firstWord.hasSuffix(")")) && trimmed.count > firstWord.count && trimmed[trimmed.index(trimmed.startIndex, offsetBy: firstWord.count)] == " " {
            var listItems: [OrderedListItem] = []
            while i < count {
                let rawLine = lines[i]
                let lTrimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if lTrimmed.isEmpty {
                    if i + 1 < count {
                        let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        let nextW = nextTrimmed.prefix(while: { $0.isNumber || $0 == "." || $0 == ")" })
                        if (nextW.hasSuffix(".") || nextW.hasSuffix(")")) && nextTrimmed.count > nextW.count && nextTrimmed[nextTrimmed.index(nextTrimmed.startIndex, offsetBy: nextW.count)] == " " {
                            i += 1
                            continue
                        }
                    }
                    break
                }
                let numWord = lTrimmed.prefix(while: { $0.isNumber || $0 == "." || $0 == ")" })
                if (numWord.hasSuffix(".") || numWord.hasSuffix(")")) && lTrimmed.count > numWord.count && lTrimmed[lTrimmed.index(lTrimmed.startIndex, offsetBy: numWord.count)] == " " {
                    let numStr = String(numWord)
                    let itemText = String(lTrimmed.dropFirst(numWord.count + 1)).trimmingCharacters(in: .whitespaces)
                    listItems.append(OrderedListItem(number: numStr, text: itemText))
                    i += 1
                } else if (rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t")) && !listItems.isEmpty {
                    let last = listItems.removeLast()
                    listItems.append(OrderedListItem(number: last.number, text: last.text + "\n" + lTrimmed))
                    i += 1
                } else {
                    break
                }
            }
            blocks.append(.orderedList(items: listItems))
            continue
        }

        // Regular paragraph: gather consecutive lines until empty line or special block
        var paraLines: [String] = []
        while i < count {
            let pLine = lines[i]
            let pTrimmed = pLine.trimmingCharacters(in: .whitespaces)
            if pTrimmed.isEmpty || pTrimmed.hasPrefix("```") || pTrimmed.hasPrefix("#") || pTrimmed.hasPrefix(">") || pTrimmed.hasPrefix("- ") || pTrimmed.hasPrefix("* ") || pTrimmed.hasPrefix("• ") || pTrimmed.hasPrefix("+ ") || (pTrimmed.hasPrefix("|") && pTrimmed.hasSuffix("|")) {
                break
            }
            let firstW = pTrimmed.prefix(while: { $0.isNumber || $0 == "." || $0 == ")" })
            if (firstW.hasSuffix(".") || firstW.hasSuffix(")")) && pTrimmed.count > firstW.count && pTrimmed[pTrimmed.index(pTrimmed.startIndex, offsetBy: firstW.count)] == " " {
                break
            }
            paraLines.append(pLine)
            i += 1
        }
        if !paraLines.isEmpty {
            blocks.append(.paragraph(text: paraLines.joined(separator: "\n")))
        }
    }

    return blocks
}

struct MarkdownInlineText: View {
    let text: String
    let isUser: Bool
    var font: Font = .system(size: 14)
    @Environment(\.colorScheme) var colorScheme

    var attributed: AttributedString {
        var attr = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)

        // Set base text color
        let baseFg = Color.primary
        attr.foregroundColor = baseFg

        // 1. Highlight inline code
        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].backgroundColor = colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
            }
        }

        // 2. Highlight @mentions in both user prompts and bot responses
        let raw = String(attr.characters)
        if let regex = try? NSRegularExpression(pattern: "@[a-zA-Z0-9_]+") {
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length))
            for match in matches {
                if let strRange = Range(match.range, in: raw),
                   let attrRange = Range(strRange, in: attr) {
                    let mentionColor: Color = isUser
                        ? (colorScheme == .dark ? Color(red: 0.35, green: 0.85, blue: 1.0) : Color(red: 0.05, green: 0.45, blue: 0.3))
                        : (colorScheme == .dark ? Color(red: 0.35, green: 0.85, blue: 1.0) : Color(red: 0.02, green: 0.52, blue: 0.88))

                    let mentionBg: Color = isUser
                        ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                        : (colorScheme == .dark ? Color.blue.opacity(0.2) : Color.blue.opacity(0.1))

                    attr[attrRange].foregroundColor = mentionColor
                    attr[attrRange].backgroundColor = mentionBg
                    attr[attrRange].inlinePresentationIntent = .stronglyEmphasized
                }
            }
        }

        return attr
    }

    var body: some View {
        Text(attributed)
            .font(font)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

struct MarkdownCodeBlockView: View {
    let language: String
    let code: String
    let isUser: Bool
    @State private var isCopied = false
    @Environment(\.colorScheme) var colorScheme

    var headerBg: Color {
        if isUser {
            return colorScheme == .dark ? Color(white: 0.12).opacity(0.8) : Color.white.opacity(0.4)
        } else {
            return colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.90)
        }
    }

    var bodyBg: Color {
        if isUser {
            return colorScheme == .dark ? Color(white: 0.08).opacity(0.8) : Color.white.opacity(0.6)
        } else {
            return colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isUser ? Color.primary.opacity(0.7) : .secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(isCopied ? .green : (isUser ? Color.primary.opacity(0.7) : .secondary))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(headerBg)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(isUser ? Color.primary : (colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.12)))
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(bodyBg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(0..<headers.count, id: \.self) { idx in
                        Text(headers[idx])
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary)
                    }
                }
                Divider()
                ForEach(0..<rows.count, id: \.self) { rIdx in
                    GridRow {
                        ForEach(0..<rows[rIdx].count, id: \.self) { cIdx in
                            Text(rows[rIdx][cIdx])
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                        }
                    }
                    if rIdx < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(10)
            .background(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.95))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

struct MarkdownMessageView: View {
    let text: String
    let isUser: Bool

    var blocks: [MarkdownBlock] {
        parseMarkdown(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<blocks.count, id: \.self) { idx in
                switch blocks[idx] {
                case .heading(let level, let hText):
                    MarkdownInlineText(
                        text: hText,
                        isUser: isUser,
                        font: level == 1 ? .title3.bold() : (level == 2 ? .headline.bold() : .subheadline.bold())
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                case .codeBlock(let language, let code):
                    MarkdownCodeBlockView(language: language, code: code, isUser: isUser)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .quote(let qText):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(DesktopTheme.accent.opacity(0.85))
                            .frame(width: 3)
                        MarkdownInlineText(text: qText, isUser: isUser)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .unorderedList(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<items.count, id: \.self) { itemIdx in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(DesktopTheme.accent)
                                MarkdownInlineText(text: items[itemIdx], isUser: isUser)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .orderedList(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.number)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(DesktopTheme.accent)
                                MarkdownInlineText(text: item.text, isUser: isUser)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .divider:
                    Divider().padding(.vertical, 2)
                case .paragraph(let pText):
                    MarkdownInlineText(text: pText, isUser: isUser)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct MessageComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    var isDisabled: Bool
    var focusTrigger: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2

        let placeholder = NSTextField(labelWithString: "Type a message")
        placeholder.font = NSFont.systemFont(ofSize: 14)
        placeholder.textColor = NSColor.placeholderTextColor
        placeholder.isBezeled = false
        placeholder.isEditable = false
        placeholder.isSelectable = false
        placeholder.drawsBackground = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 2),
            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 2)
        ])

        context.coordinator.textView = textView
        context.coordinator.placeholderField = placeholder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        textView.isEditable = !isDisabled
        textView.textColor = isDisabled ? NSColor.secondaryLabelColor : NSColor.labelColor

        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }

        context.coordinator.placeholderField?.isHidden = !text.isEmpty

        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        context.coordinator.recalculateHeight(containerWidth: scrollView.bounds.width)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        weak var textView: NSTextView?
        weak var placeholderField: NSTextField?
        var lastFocusTrigger: Int = 0
        private var lastMeasuredWidth: CGFloat = 0

        init(_ parent: MessageComposer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let updated = textView.string
            if parent.text != updated {
                parent.text = updated
            }
            placeholderField?.isHidden = !updated.isEmpty
            recalculateHeight(containerWidth: textView.enclosingScrollView?.bounds.width ?? 0)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if !parent.isDisabled {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        func recalculateHeight(containerWidth: CGFloat) {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            if containerWidth > 0 && abs(containerWidth - lastMeasuredWidth) > 0.5 {
                lastMeasuredWidth = containerWidth
                textContainer.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let minH: CGFloat = 22
            let maxH: CGFloat = 124
            let target = min(maxH, max(minH, ceil(used + 4)))
            if abs(parent.dynamicHeight - target) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.dynamicHeight = target
                }
            }
        }
    }
}


struct ChatBubble: View {
    let text: String
    let botNames: [String]
    let isStreamingTurn: Bool
    @Environment(\.colorScheme) var colorScheme

    var isUser: Bool {
        text.hasPrefix("You\n")
    }

    var senderName: String {
        if isUser { return "You" }
        return text.components(separatedBy: "\n").first ?? "Assistant"
    }

    var bodyText: String {
        let lines = text.components(separatedBy: "\n")
        let raw = lines.dropFirst().joined(separator: "\n")
        if !isUser {
            return AssistantService.cleanBotReply(raw, botName: senderName, otherBotNames: botNames)
        }
        return raw
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    // Show colored sender header for incoming bot messages
                    if !isUser && !senderName.isEmpty {
                        Text(senderName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 1)
                    }

                    if bodyText.isEmpty && isStreamingTurn {
                        // Subtle animated typing indicator while waiting for first tokens
                        HStack(spacing: 4) {
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    } else if bodyText.hasPrefix("[Image: "),
                              let closeIdx = bodyText.firstIndex(of: "]") {
                        let pathStart = bodyText.index(bodyText.startIndex, offsetBy: 8)
                        let imgPath = String(bodyText[pathStart..<closeIdx])
                        let caption = String(bodyText[bodyText.index(after: closeIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        VStack(alignment: .leading, spacing: 6) {
                            if let asset = OpenRouterClient.attachmentURL(imgPath), let nsImg = NSImage(contentsOf: asset) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 340, maxHeight: 260)
                                    .cornerRadius(8)
                                    .onTapGesture {
                                        NSWorkspace.shared.open(asset)
                                    }
                            }
                            if !caption.isEmpty {
                                MarkdownMessageView(text: caption, isUser: isUser)
                            }
                        }
                    } else {
                        MarkdownMessageView(text: bodyText, isUser: isUser)
                    }
                }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isUser ? DesktopTheme.userBubble(for: colorScheme) : Color.clear)
            .cornerRadius(10)
            .frame(maxWidth: isUser ? 580 : .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Workspaces (Memory & Reminders)

struct EditGroupModalView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Manage Multi-Bot Group")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    state.deleteGroup(id: state.editingGroupId)
                    state.showEditGroupModal = false
                } label: {
                    Label("Delete Group", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Group Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Group Name", text: $state.editingGroupName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Group Members (\(state.editingGroupMembers.count))")
                    .font(.subheadline.weight(.semibold))

                Text("Select participating bots:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                List {
                    ForEach([""] + state.bots.map { $0.id }, id: \.self) { botId in
                        let name = botId.isEmpty ? state.fridayName : (state.bots.first(where: { $0.id == botId })?.name ?? "FRIDAY")
                        HStack {
                            ZStack {
                                Circle()
                                    .fill(botId.isEmpty ? DesktopTheme.accent : avatarColor(for: name))
                                    .frame(width: 28, height: 28)
                                if botId.isEmpty {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                } else {
                                    Text(avatarInitials(for: name))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }

                            Text(name)
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { state.editingGroupMembers.contains(botId) },
                                set: { on in
                                    if on {
                                        state.editingGroupMembers.insert(botId)
                                    } else {
                                        state.editingGroupMembers.remove(botId)
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: 180)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }

            if state.editingGroupMembers.count < 2 {
                Text("A multi-bot group requires at least 2 members.")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.showEditGroupModal = false
                }
                Button("Save Changes") {
                    state.updateGroup(
                        id: state.editingGroupId,
                        name: state.editingGroupName,
                        memberIds: Array(state.editingGroupMembers)
                    )
                    state.showEditGroupModal = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.editingGroupName.trimmingCharacters(in: .whitespaces).isEmpty || state.editingGroupMembers.count < 2)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct MemoryCardRow: View {
    @EnvironmentObject var state:AppState
    @State private var editing=false
    @State private var bodyDraft=""
    @State private var audience=""
    @State private var error=""

    let entry: MemoryEntry
    let onDelete: () -> Void

    @ViewBuilder private var metadata: some View {
        Text(entry.scope == "shared" ? "Shared" : (entry.scope.hasPrefix("group:") ? "Group" : "Private"))
            .help(entry.scope)
        Text(MemoryOrigin.decode(entry.source) == nil ? entry.source : "Chat turn")
        Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
        if let similarity = entry.similarity { Text(String(format: "Match %.2f", similarity)) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.body).font(.body).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack { metadata }
                    VStack(alignment: .leading) { metadata }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Edit fact…") { bodyDraft = entry.body; audience = entry.scope; error = ""; editing = true }
                if MemoryOrigin.decode(entry.source) != nil {
                    Button("Open source turn") { state.showOrigin(entry.source) }
                }
                Divider()
                Button("Delete fact", role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis.circle") }
            .fixedSize().menuStyle(.borderlessButton).accessibilityLabel("Fact actions")
        }
        .sheet(isPresented:$editing) {
            VStack(alignment:.leading) {
                Text("Edit memory").font(.headline)
                TextEditor(text:$bodyDraft).frame(minHeight:110)
                Picker("Audience",selection:$audience) {
                    Text("Every bot").tag("shared")
                    Text(state.fridayName).tag("private:")
                    Text("All-bots group").tag("group:group")
                    ForEach(state.bots) { Text($0.name).tag("private:"+$0.id) }
                    ForEach(state.groups) { Text($0.name).tag("group:"+$0.id) }
                }
                if !error.isEmpty {Text(error)}
                HStack {Button("Cancel"){editing=false}; Button("Save"){
                    do {try state.reviseMemory(entry,body:bodyDraft,scope:audience);editing=false}
                    catch {self.error=error.localizedDescription}
                }}
            }.padding().frame(width:390)
        }
        .padding(.vertical, 6)
    }
}

struct GraphTripleCardRow: View {
    let triple: GraphTriple
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(triple.scope.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(triple.scope == "shared" ? DesktopTheme.accent : .blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((triple.scope == "shared" ? DesktopTheme.accent : Color.blue).opacity(0.15))
                .cornerRadius(4)

            HStack(spacing: 6) {
                Text(triple.subject)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(triple.predicate)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DesktopTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesktopTheme.accent.opacity(0.1))
                    .cornerRadius(4)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(triple.object)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Delete this knowledge relation")
        }
        .padding(.vertical, 6)
    }
}

struct MemoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var searchQuery = ""
    @State private var newMemoryText = ""
    @State private var isShared = false
    @State private var section = "Facts"
    @State private var showClearAlert = false
    @State private var adding = false

    var body: some View {
        WorkspacePage(title: "Memory Vault", selection: $section, sections: ["Facts", "Relationships", "Documents"]) {
            if section == "Documents" {
                DocumentImport()
            } else {
                HStack {
                    Picker("Audience", selection: $state.selectedMemoryScope) {
                        Text("All scopes").tag("all")
                        Text("Shared").tag("shared")
                        Text("Current chat").tag("current")
                    }.fixedSize()
                    Spacer()
                    if section == "Facts" {
                        Button { adding.toggle() } label: { Label("Add fact", systemImage: "plus") }
                    }
                    Menu {
                        Button("Clear selected scope…", role: .destructive) { showClearAlert = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Memory actions")
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search facts and relationships", text: $searchQuery).textFieldStyle(.plain)
                    if !searchQuery.isEmpty { Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(9).background(DesktopTheme.sidebar(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                if adding && section == "Facts" {
                    VStack(alignment: .leading) {
                        TextField("Fact or preference", text: $newMemoryText).onSubmit(saveNewMemory)
                        HStack {
                            Toggle("Share with every bot", isOn: $isShared)
                            Spacer()
                            Button("Cancel") { adding = false }
                            Button("Save", action: saveNewMemory).disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Divider()
                if section == "Facts" {
                    if state.memories.isEmpty { Text(searchQuery.isEmpty ? "No saved facts in this scope." : "No matching facts.").foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading) {
                        ForEach(state.memories) { item in
                            MemoryCardRow(entry: item) { state.deleteMemory(item) }
                            Divider()
                        }
                    }
                } else {
                    if state.graphTriples.isEmpty { Text("No matching relationships.").foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading) {
                        ForEach(state.graphTriples) { triple in
                            GraphTripleCardRow(triple: triple) { state.deleteTriple(triple) }
                            Divider()
                        }
                    }
                }
            }
        }
        .onChange(of: searchQuery) { state.loadMemories(query: searchQuery) }
        .onChange(of: state.selectedMemoryScope) { state.loadMemories(query: searchQuery) }
        .onAppear {
            state.loadMemories(query: searchQuery)
        }
        .confirmationDialog(
            "Clear Memories",
            isPresented: $showClearAlert,
            titleVisibility: .visible
        ) {
            Button("Delete All in Scope '\(state.selectedMemoryScope.capitalized)'", role: .destructive) {
                state.clearAllMemories()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete these memories? This will permanently remove them from SQLite.")
        }
    }

    private func saveNewMemory() {
        let clean = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        state.saveMemory(body: clean, isShared: isShared)
        newMemoryText = ""
        adding = false
    }
}

struct RemindersView: View {
    @EnvironmentObject var state: AppState
    @State private var reminderText = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var frequency: Frequency? = nil

    @State private var section = "Scheduled"
    @State private var adding = false

    var body: some View {
        WorkspacePage(title: "Reminders & Tasks", selection: $section, sections: ["Scheduled", "Activity", "Briefings", "Apple Reminders"]) {
            switch section {
            case "Briefings": LocalTools(isBackup: false)
            case "Apple Reminders": AppleReminderForm()
            case "Activity":
                if state.activities.isEmpty { Text("No recorded activity yet.").foregroundStyle(.secondary) }
                ForEach(state.activities) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.subject)
                        Text(item.action + " · " + item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                        if let error = item.error { Text(error).foregroundStyle(.red) }
                    }
                    Divider()
                }
            default:
                HStack {
                    Text("Upcoming").font(.headline)
                    Spacer()
                    Button { adding.toggle() } label: { Label("New reminder", systemImage: "plus") }
                }
                if adding {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Reminder title", text: $reminderText).textFieldStyle(.roundedBorder)
                        DatePicker("Due", selection: $due)
                        Picker("Repeat", selection: $frequency) {
                            Text("Once").tag(nil as Frequency?)
                            Text("Daily").tag(Frequency.daily as Frequency?)
                            Text("Weekly").tag(Frequency.weekly as Frequency?)
                        }
                        HStack {
                            Button("Cancel") { adding = false }
                            Button("Schedule") {
                                state.addReminder(text: reminderText, due: due, frequency: frequency)
                                reminderText = ""
                                adding = false
                            }.disabled(reminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Divider()
                if state.reminders.isEmpty { Text("No scheduled reminders.").foregroundStyle(.secondary) }
                ForEach(state.reminders.sorted { $0.due < $1.due }) { reminder in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reminder.text)
                            Text([reminder.due.formatted(), reminder.frequency?.rawValue].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "clock").foregroundStyle(DesktopTheme.accent) }
                    Divider()
                }
            }
        }.onAppear { state.loadReminders() }
    }
}
