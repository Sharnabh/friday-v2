import SwiftUI
import FridayCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedTab: Int = 0
    @State private var showCreateBot = false
    @State private var showCreateGroup = false
    @State private var newBotName = ""
    @State private var newBotInstructions = ""
    @State private var newGroupName = ""
    @State private var selectedGroupMembers = Set<String>()

    var body: some View {
        NavigationSplitView {
            List(selection: $state.activeBotId) {
                Section("Assistant") {
                    NavigationLink(value: "") {
                        Label("FRIDAY (Core)", systemImage: "sparkles")
                    }
                }

                if !state.bots.isEmpty {
                    Section("Custom Bots") {
                        ForEach(state.bots) { bot in
                            NavigationLink(value: bot.id) {
                                Label(bot.name, systemImage: "person.circle")
                            }
                        }
                    }
                }

                if !state.groups.isEmpty {
                    Section("Groups") {
                        ForEach(state.groups) { group in
                            NavigationLink(value: group.id) {
                                Label(group.name, systemImage: "person.3.sequence")
                            }
                        }
                    }
                }

                Section("Workspaces") {
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
            .navigationTitle("FRIDAY")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showCreateBot = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .help("Create Custom Bot")

                    Button {
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "person.3.fill")
                    }
                    .help("Create Group Chat")
                }
            }
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
            .navigationSubtitle(state.statusMessage)
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
                        let name = state.bots.first(where: { $0.id == botId })?.name ?? "FRIDAY"
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
    }
}

struct ChatView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Configuration bar (Model / Provider / Mic / Wake)
            HStack(spacing: 12) {
                TextField("Provider (e.g. anthropic, gemini)", text: $state.provider)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                TextField("Model override", text: $state.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)

                if !state.availableMics.isEmpty {
                    Picker("Mic", selection: $state.selectedMic) {
                        ForEach(state.availableMics, id: \.self) { mic in
                            Text(mic).tag(mic)
                        }
                    }
                    .frame(maxWidth: 150)
                }

                Toggle("Hey Friday", isOn: $state.isWakeEnabled)
                    .toggleStyle(.switch)

                Button {
                    state.toggleVoiceRecording()
                } label: {
                    Image(systemName: state.isVoiceActive ? "mic.fill" : "mic.slash")
                        .foregroundColor(state.isVoiceActive ? .red : .secondary)
                }
                .help(state.isVoiceActive ? "Stop Voice Recording" : "Record Voice")

                Button {
                    AssistantService.shared.stopSpeaking()
                } label: {
                    Image(systemName: "speaker.slash.fill")
                }
                .help("Mute Speech")
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if state.audioLevel > 0.05 {
                ProgressView(value: state.audioLevel)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            Divider().padding(.vertical, 8)

            // Transcript Scroll
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(state.currentTranscript.enumerated()), id: \.offset) { index, turn in
                            ChatBubble(text: turn)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onChange(of: state.currentTranscript.count) { _ in
                    if let last = state.currentTranscript.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Message Input bar
            HStack(spacing: 10) {
                TextField("Ask Friday, inspect screen, or command Mac…", text: $state.inputMessage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        state.sendMessage()
                    }
                    .disabled(state.isBusy)

                Button {
                    state.sendMessage()
                } label: {
                    if state.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(state.inputMessage.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy)
            }
            .padding()
        }
    }
}

struct ChatBubble: View {
    let text: String

    var isUser: Bool {
        text.hasPrefix("You\n")
    }

    var body: some View {
        HStack {
            if isUser { Spacer() }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(isUser ? .white : .primary)
                    .padding(10)
                    .background(isUser ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
            }
            if !isUser { Spacer() }
        }
    }
}

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
                    .onChange(of: searchQuery) { query in
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
