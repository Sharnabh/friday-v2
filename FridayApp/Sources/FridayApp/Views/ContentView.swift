import SwiftUI
import FridayCore

// MARK: - WhatsApp Theme Palette

struct WhatsAppTheme {
    static func wallpaper(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.043, green: 0.078, blue: 0.102) // #0B141A
            : Color(red: 0.937, green: 0.918, blue: 0.886) // #EFEAE2
    }

    static func headerBg(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.078, green: 0.114, blue: 0.137) // #141D23
            : Color(red: 0.941, green: 0.949, blue: 0.961) // #F0F2F5
    }

    static func inputBarBg(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.078, green: 0.114, blue: 0.137) // #141D23
            : Color(red: 0.941, green: 0.949, blue: 0.961) // #F0F2F5
    }

    static func inputFieldBg(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.165, green: 0.224, blue: 0.259) // #2A3942
            : Color.white
    }

    static func userBubble(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.0, green: 0.361, blue: 0.294)   // #005C4B
            : Color(red: 0.851, green: 0.992, blue: 0.827) // #D9FDD3
    }

    static func botBubble(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.125, green: 0.173, blue: 0.200) // #202C33
            : Color.white                                   // #FFFFFF
    }

    static func userText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.914, green: 0.929, blue: 0.937) // #E9EDEF
            : Color(red: 0.067, green: 0.106, blue: 0.129) // #111B21
    }

    static func botText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.914, green: 0.929, blue: 0.937)
            : Color(red: 0.067, green: 0.106, blue: 0.129)
    }

    static func timestamp(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.525, green: 0.588, blue: 0.627) // #8696A0
            : Color(red: 0.400, green: 0.467, blue: 0.502) // #667781
    }

    static let emerald = Color(red: 0.0, green: 0.659, blue: 0.518)   // #00A884
    static let blueTick = Color(red: 0.325, green: 0.741, blue: 0.922) // #53BDEB
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
    @State private var selectedTab: Int = 0
    @State private var showCreateBot = false
    @State private var showCreateGroup = false
    @State private var newBotName = ""
    @State private var newBotInstructions = ""
    @State private var newGroupName = ""
    @State private var selectedGroupMembers = Set<String>()
    @State private var searchChatQuery = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // WhatsApp-Style Sidebar Header
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(WhatsAppTheme.emerald)
                            .frame(width: 36, height: 36)
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }

                    Text("Chats")
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
                .background(WhatsAppTheme.headerBg(for: colorScheme))

                Divider()

                // WhatsApp Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    TextField("Search or start new chat", text: $searchChatQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(WhatsAppTheme.inputFieldBg(for: colorScheme))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // Contact & Group Chat List
                List(selection: $state.activeBotId) {
                    Section("Core Assistant") {
                        NavigationLink(value: "") {
                            WhatsAppChatRow(
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
                                    WhatsAppChatRow(
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
                                    WhatsAppChatRow(
                                        name: group.name,
                                        subtitle: "\(group.members.count) members",
                                        isGroup: true,
                                        isCore: false
                                    )
                                }
                            }
                        }
                    }

                    Section("Workspaces") {
                        Button {
                            selectedTab = 0
                        } label: {
                            Label("Messages", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button {
                            selectedTab = 1
                        } label: {
                            Label("Memory Vault", systemImage: "brain.head.profile")
                        }
                        Button {
                            selectedTab = 2
                        } label: {
                            Label("Reminders & Tasks", systemImage: "clock.badge.checkmark")
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("")
        } detail: {
            Group {
                switch selectedTab {
                case 1:
                    MemoryView()
                case 2:
                    RemindersView()
                default:
                    ChatView()
                }
            }
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
                    Spacer()
                    Button("Cancel") { showCreateBot = false }
                    Button("Create") {
                        if !newBotName.isEmpty {
                            state.createBot(name: newBotName, instructions: newBotInstructions)
                            newBotName = ""
                            newBotInstructions = ""
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
            VStack(alignment: .leading, spacing: 14) {
                Text(state.editingBotId.isEmpty ? "Edit Core Assistant Persona" : "Edit Assistant Persona")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Persona Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Bot Name", text: $state.editingBotName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("System Instructions & Tone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $state.editingBotInstructions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }

                HStack {
                    if !state.editingBotId.isEmpty {
                        Button(role: .destructive) {
                            state.deleteBot(id: state.editingBotId)
                            state.showEditPersonaModal = false
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    Spacer()

                    Button("Cancel") { state.showEditPersonaModal = false }
                    Button("Save Changes") {
                        state.updateBot(
                            id: state.editingBotId,
                            name: state.editingBotName,
                            instructions: state.editingBotInstructions
                        )
                        state.showEditPersonaModal = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.editingBotName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .frame(width: 460)
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

// MARK: - WhatsApp Sidebar Row

struct WhatsAppChatRow: View {
    let name: String
    let subtitle: String
    let isGroup: Bool
    let isCore: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isGroup ? Color.orange : avatarColor(for: name))
                    .frame(width: 38, height: 38)

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

// MARK: - WhatsApp Main Chat View

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var showSettingsBar = false

    var body: some View {
        VStack(spacing: 0) {
            // WhatsApp Top Chat Bar
            HStack(spacing: 12) {
                // Contact Avatar
                ZStack {
                    Circle()
                        .fill(state.isGroupSelected ? Color.orange : avatarColor(for: state.currentBotDisplayName))
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

                    if state.isBusy {
                        Text(state.statusMessage)
                            .font(.system(size: 12))
                            .foregroundColor(WhatsAppTheme.emerald)
                    } else if state.isGroupSelected {
                        Text("\(state.groupMembers.count) participants")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Text("online")
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
                    .frame(maxWidth: 160)
                    .onChange(of: state.currentSessionId) { _, newId in
                        state.selectSession(newId)
                    }
                }

                // Edit Persona Action
                if !state.isGroupSelected {
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
                .keyboardShortcut("n", modifiers: .command)
                .help("New Conversation")

                // Settings Bar Toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsBar.toggle()
                    }
                } label: {
                    Image(systemName: showSettingsBar ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 15))
                        .foregroundColor(showSettingsBar ? WhatsAppTheme.emerald : .secondary)
                }
                .buttonStyle(.plain)
                .help("Audio & Model Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(WhatsAppTheme.headerBg(for: colorScheme))

            // Expandable Settings Drawer (WhatsApp Clean Integration)
            if showSettingsBar {
                HStack(spacing: 12) {
                    TextField("Provider override", text: $state.provider)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    TextField("Model override", text: $state.model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)

                    if !state.availableMics.isEmpty {
                        Picker("Mic", selection: $state.selectedMic) {
                            ForEach(state.availableMics, id: \.self) { mic in
                                Text(mic).tag(mic)
                            }
                        }
                        .frame(maxWidth: 140)
                    }

                    Toggle("Hey Friday", isOn: $state.isWakeEnabled)
                        .toggleStyle(.switch)

                    Button {
                        AssistantService.shared.stopSpeaking()
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                    }
                    .help("Mute Speech")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(WhatsAppTheme.headerBg(for: colorScheme).opacity(0.85))
                Divider()
            }

            if state.audioLevel > 0.05 {
                ProgressView(value: state.audioLevel)
                    .progressViewStyle(.linear)
                    .tint(WhatsAppTheme.emerald)
                    .padding(.horizontal)
            }

            // WhatsApp Message Canvas with Signature Wallpaper
            ZStack {
                WhatsAppTheme.wallpaper(for: colorScheme)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(state.currentTranscript.enumerated()), id: \.offset) { index, turn in
                                ChatBubble(text: turn)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: state.currentTranscript.count) { _, _ in
                        if let last = state.currentTranscript.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
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
                                        .fill(bot.id.isEmpty ? WhatsAppTheme.emerald : avatarColor(for: bot.name))
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
                .background(WhatsAppTheme.headerBg(for: colorScheme))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // WhatsApp Bottom Input Bar
            HStack(spacing: 10) {
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

                // WhatsApp Capsule Text Input Field
                HStack {
                    TextField("Type a message", text: $state.inputMessage)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit {
                            state.sendMessage()
                        }
                        .disabled(state.isBusy)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(WhatsAppTheme.inputFieldBg(for: colorScheme))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )

                // Voice Recording or WhatsApp Green Send Button
                if state.inputMessage.trimmingCharacters(in: .whitespaces).isEmpty {
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
                                .fill(WhatsAppTheme.emerald)
                                .frame(width: 36, height: 36)
                            if state.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .colorInvert()
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .offset(x: -1, y: 1)
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
            .background(WhatsAppTheme.inputBarBg(for: colorScheme))
        }
    }
}

// MARK: - WhatsApp Chat Bubble

struct ChatBubble: View {
    let text: String
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
        return lines.dropFirst().joined(separator: "\n")
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
                            .foregroundColor(avatarColor(for: senderName))
                            .padding(.bottom, 1)
                    }

                    Text(bodyText)
                        .font(.system(size: 14))
                        .foregroundColor(isUser ? WhatsAppTheme.userText(for: colorScheme) : WhatsAppTheme.botText(for: colorScheme))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Bottom Timestamp & Read Receipt Tick marks
                HStack(spacing: 3) {
                    Text(Date().formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundColor(WhatsAppTheme.timestamp(for: colorScheme))

                    if isUser {
                        HStack(spacing: -3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(WhatsAppTheme.blueTick)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isUser ? WhatsAppTheme.userBubble(for: colorScheme) : WhatsAppTheme.botBubble(for: colorScheme))
            .cornerRadius(10)
            .shadow(color: Color.black.opacity(0.06), radius: 1, x: 0, y: 1)
            .frame(maxWidth: 540, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Workspaces (Memory & Reminders)

struct MemoryView: View {
    @EnvironmentObject var state: AppState
    @State private var searchQuery = ""
    @State private var newMemoryText = ""
    @State private var isShared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hybrid Memory Vault (FTS5 + Dense Embeddings)")
                .font(.headline)

            HStack {
                TextField("Search memories with semantic or exact text…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchQuery) { _, query in
                        state.loadMemories(query: query)
                    }
                Button("Search") {
                    state.loadMemories(query: searchQuery)
                }
            }

            HStack {
                TextField("Add new durable fact / preference…", text: $newMemoryText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Shared", isOn: $isShared)
                Button("Save Memory") {
                    if !newMemoryText.isEmpty {
                        state.saveMemory(body: newMemoryText, isShared: isShared)
                        newMemoryText = ""
                    }
                }
            }

            List(state.memories) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.scope.capitalized)
                            .font(.caption)
                            .padding(3)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        if let sim = item.similarity {
                            Text(String(format: "Cosine: %.2f", sim))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(item.source)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(item.body)
                        .font(.body)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .onAppear {
            state.loadMemories()
        }
    }
}

struct RemindersView: View {
    @EnvironmentObject var state: AppState
    @State private var reminderText = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var frequency: Frequency? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automated Reminders & Activities")
                .font(.headline)

            HStack {
                TextField("Reminder or document title", text: $reminderText)
                    .textFieldStyle(.roundedBorder)
                DatePicker("", selection: $due)
                Picker("Repeat", selection: $frequency) {
                    Text("Once").tag(nil as Frequency?)
                    Text("Daily").tag(Frequency.daily as Frequency?)
                    Text("Weekly").tag(Frequency.weekly as Frequency?)
                }
                .frame(width: 100)
                Button("Schedule") {
                    if !reminderText.isEmpty {
                        state.addReminder(text: reminderText, due: due, frequency: frequency)
                        reminderText = ""
                    }
                }
            }

            List(state.reminders) { rem in
                HStack {
                    VStack(alignment: .leading) {
                        Text(rem.text).font(.body)
                        Text(rem.due.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let freq = rem.frequency {
                        Text(freq.rawValue)
                            .font(.caption)
                            .padding(4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding()
        .onAppear {
            state.loadReminders()
        }
    }
}
