import SwiftUI
import FridayCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var inputMessage: String = ""
    @Published public var statusMessage: String = "Ready"
    @Published public var isBusy: Bool = false
    @Published public var currentTranscript: [String] = []
    
    // Voice & Wake Word
    @Published public var isVoiceActive: Bool = false
    @Published public var isWakeEnabled: Bool = false
    @Published public var audioLevel: Double = 0.0
    @Published public var availableMics: [String] = []
    @Published public var selectedMic: String = ""

    // Bots and Groups
    @Published public var activeBotId: String = "" {
        didSet {
            if oldValue != activeBotId {
                onBotChanged()
            }
        }
    }
    @Published public var bots: [BotProfile] = []
    @Published public var groups: [BotGroup] = []
    @Published public var provider: String = ""
    @Published public var model: String = ""
    
    // Sessions & Conversations
    @Published public var currentSessionId: String = ""
    @Published public var savedSessions: [ChatSessionItem] = []
    
    // Memory & Reminders
    @Published public var selectedMemoryScope: String = "all" // "all", "shared", "current"
    @Published public var memories: [MemoryEntry] = []
    @Published public var graphTriples: [GraphTriple] = []
    @Published public var reminders: [Reminder] = []
    @Published public var activities: [ActivityEntry] = []
    @Published public var selectedTab: Int = 0 // 0: Messages, 1: Memory Vault, 2: Reminders

    // Persona & Instructions Editing
    @Published public var showEditPersonaModal: Bool = false
    @Published public var editingBotId: String = ""
    @Published public var editingBotName: String = ""
    @Published public var editingBotInstructions: String = ""

    // Group Editing & Member Management
    @Published public var showEditGroupModal: Bool = false
    @Published public var editingGroupId: String = ""
    @Published public var editingGroupName: String = ""
    @Published public var editingGroupMembers: Set<String> = []

    // ChatGPT/Gemini-Style In-Chat Memory Notification Pill
    @Published public var lastMemoryUpdateNotice: String? = nil
    @Published public var showMemoryToast: Bool = false
    private var toastTimer: Timer?

    public var memoryStore: HybridMemoryStore?
    public var reminderService: ReminderService
    public var activityService: ActivityService

    private let defaults = UserDefaults.standard
    private var reminderTimer: Timer?

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbUrl = appSupport.appendingPathComponent("Friday/Memory.sqlite")
        let reminderFile = appSupport.appendingPathComponent("FRIDAY/reminders.json")
        let activityFolder = appSupport.appendingPathComponent("FRIDAY/activity")

        self.reminderService = ReminderService(file: reminderFile)
        self.activityService = ActivityService(folder: activityFolder)

        do {
            self.memoryStore = try HybridMemoryStore(url: dbUrl)
        } catch {
            self.statusMessage = "Memory store init error: \(error.localizedDescription)"
        }

        // Real-time memory notification hook from autonomous extractor
        BackgroundFactExtractor.shared.onFactSaved = { [weak self] fact in
            Task { @MainActor in
                self?.notifyMemoryUpdated(text: fact)
                self?.loadMemories()
            }
        }

        loadBotsAndGroups()
        loadTranscripts()
        loadReminders()
        setupVoicePipeline()
        startReminderPoller()
    }

    public var activeBotScope: String {
        activeBotId.isEmpty ? "" : "bot." + activeBotId + "."
    }

    public var isGroupSelected: Bool {
        activeBotId == "group" || groups.contains(where: { $0.id == activeBotId })
    }

    public var memoryScope: String {
        (isGroupSelected ? "group:" : "private:") + activeBotId
    }

    public var groupMembers: [String] {
        if let g = groups.first(where: { $0.id == activeBotId }) {
            return g.members
        }
        return [""] + bots.map { $0.id }
    }

    private func setupVoicePipeline() {
        let voice = VoiceService.shared
        self.availableMics = voice.listMicrophones()
        self.selectedMic = defaults.string(forKey: "fridayMic") ?? availableMics.first ?? ""

        voice.onLevelUpdate = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        voice.onStateUpdate = { [weak self] state in
            Task { @MainActor in self?.statusMessage = state }
        }
        voice.onTranscriptionComplete = { [weak self] text in
            Task { @MainActor in
                self?.inputMessage = text
                self?.statusMessage = "Review transcription, then Send"
                if self?.isWakeEnabled == true {
                    self?.sendMessage()
                }
            }
        }
        voice.onError = { [weak self] error in
            Task { @MainActor in self?.statusMessage = error }
        }
    }

    public func toggleVoiceRecording() {
        if isVoiceActive {
            VoiceService.shared.stopCapture()
            isVoiceActive = false
        } else {
            VoiceService.shared.startCapture(handsFree: isWakeEnabled, micDeviceName: selectedMic)
            isVoiceActive = true
        }
    }

    private func startReminderPoller() {
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDueReminders() }
        }
    }

    private func checkDueReminders() {
        guard !isBusy, let rem = try? reminderService.takeDue(at: Date()) else { return }
        statusMessage = "Reminder: " + rem.text
        try? activityService.append(ActivityEntry(date: Date(), scheduled: rem.due, action: "Reminder Fired", subject: rem.text))
        loadReminders()
        AssistantService.shared.speak("Reminder: " + rem.text)
    }

    public func loadBotsAndGroups() {
        if let botDict = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] {
            self.bots = botDict.map { BotProfile(id: $0.key, name: $0.value["name"] ?? "Bot", instructions: $0.value["instructions"] ?? "") }.sorted(by: { $0.name < $1.name })
        }
        if let groupData = defaults.data(forKey: "namedGroups"),
           let groupMap = try? JSONDecoder().decode([String: BotGroup].self, from: groupData) {
            self.groups = Array(groupMap.values).sorted(by: { $0.name < $1.name })
        }
        self.activeBotId = defaults.string(forKey: "activeBot") ?? ""
        self.provider = defaults.string(forKey: activeBotScope + "chatProvider") ?? ""
        self.model = defaults.string(forKey: activeBotScope + "chatModel") ?? ""
    }

    public func onBotChanged() {
        defaults.set(provider, forKey: activeBotScope + "chatProvider")
        defaults.set(model, forKey: activeBotScope + "chatModel")
        defaults.set(activeBotId, forKey: "activeBot")
        self.provider = defaults.string(forKey: activeBotScope + "chatProvider") ?? ""
        self.model = defaults.string(forKey: activeBotScope + "chatModel") ?? ""
        self.currentSessionId = defaults.string(forKey: activeBotScope + "fridaySession") ?? UUID().uuidString
        defaults.set(currentSessionId, forKey: activeBotScope + "fridaySession")
        AssistantService.shared.stopSpeaking()
        loadTranscripts()
        loadSessions()
        loadMemories()
        self.statusMessage = "Switched to \(currentBotDisplayName)"
    }

    public var fridayName: String {
        let name = defaults.string(forKey: "fridayCustomName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "FRIDAY" : name
    }

    public var fridayInstructions: String {
        defaults.string(forKey: "fridayCustomInstructions") ?? ""
    }

    public var currentBotName: String {
        if isGroupSelected {
            return groups.first(where: { $0.id == activeBotId })?.name ?? "Group Chat"
        }
        if activeBotId.isEmpty {
            return fridayName
        }
        return bots.first(where: { $0.id == activeBotId })?.name ?? "Bot"
    }

    public var currentBotInstructions: String {
        if activeBotId.isEmpty {
            return fridayInstructions
        }
        return bots.first(where: { $0.id == activeBotId })?.instructions ?? ""
    }

    public var currentBotDisplayName: String {
        currentBotName
    }

    public func selectBot(_ id: String) {
        activeBotId = id
    }

    public func updateBot(id: String, name: String, instructions: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            // Updating Core Friday
            defaults.set(cleanName.isEmpty ? "FRIDAY" : cleanName, forKey: "fridayCustomName")
            defaults.set(instructions, forKey: "fridayCustomInstructions")
            objectWillChange.send()
            self.statusMessage = "Updated \(fridayName) persona"
        } else {
            // Updating custom bot
            var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
            current[id] = ["name": cleanName.isEmpty ? "Bot" : cleanName, "instructions": instructions]
            defaults.set(current, forKey: "fridayBots")
            loadBotsAndGroups()
            self.statusMessage = "Updated \(cleanName)"
        }
        // Invalidate any session cache so updated instructions take effect immediately
        let resumeKey = "hermesSession." + sessionID
        defaults.removeObject(forKey: resumeKey)
    }

    public func openPersonaEditor(for botId: String? = nil) {
        let targetId = botId ?? activeBotId
        if targetId.isEmpty {
            editingBotId = ""
            editingBotName = fridayName
            editingBotInstructions = fridayInstructions
            showEditPersonaModal = true
        } else if let b = bots.first(where: { $0.id == targetId }) {
            editingBotId = b.id
            editingBotName = b.name
            editingBotInstructions = b.instructions
            showEditPersonaModal = true
        }
    }

    // MARK: - @ Mention Suggestions & Auto-Complete

    public var mentionableBots: [MentionableBot] {
        var list = [MentionableBot(id: "", name: fridayName, role: "Core Assistant")]
        for b in bots {
            let roleSnippet = b.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(MentionableBot(
                id: b.id,
                name: b.name,
                role: roleSnippet.isEmpty ? "AI Assistant" : String(roleSnippet.prefix(50))
            ))
        }
        return list
    }

    public var currentMentionQuery: String? {
        guard let lastWord = inputMessage.components(separatedBy: .whitespacesAndNewlines).last,
              lastWord.hasPrefix("@") else {
            return nil
        }
        return String(lastWord.dropFirst())
    }

    public var matchingMentionBots: [MentionableBot] {
        guard let query = currentMentionQuery?.lowercased() else { return [] }
        if query.isEmpty {
            return mentionableBots
        }
        return mentionableBots.filter { $0.name.lowercased().contains(query) }
    }

    public func insertMention(_ bot: MentionableBot) {
        guard let lastWord = inputMessage.components(separatedBy: .whitespacesAndNewlines).last,
              lastWord.hasPrefix("@") else {
            inputMessage += "@" + bot.name + " "
            return
        }
        var words = inputMessage.components(separatedBy: " ")
        if !words.isEmpty && words.last?.hasPrefix("@") == true {
            words.removeLast()
        }
        words.append("@" + bot.name)
        inputMessage = words.joined(separator: " ") + " "
    }

    public func latestSnippet(for botId: String) -> String {
        let prefix = botId.isEmpty ? "" : "bot." + botId + "."
        let sessId = defaults.string(forKey: prefix + "fridaySession") ?? ""
        if !sessId.isEmpty, let turns = defaults.stringArray(forKey: prefix + "transcript." + sessId), let last = turns.last {
            let lines = last.components(separatedBy: "\n")
            let content = lines.dropFirst().joined(separator: " ")
            return content.isEmpty ? "Tap to chat" : String(content.prefix(32))
        }
        return "Tap to chat"
    }

    public func deleteBot(id: String) {
        guard !id.isEmpty else { return }
        var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
        current.removeValue(forKey: id)
        defaults.set(current, forKey: "fridayBots")

        // Remove from all existing groups so no group retains deleted member
        if let groupData = defaults.data(forKey: "namedGroups"),
           var groupMap = try? JSONDecoder().decode([String: BotGroup].self, from: groupData) {
            for (gId, var g) in groupMap {
                if g.members.contains(id) {
                    g.members.removeAll(where: { $0 == id })
                    groupMap[gId] = g
                }
            }
            if let data = try? JSONEncoder().encode(groupMap) {
                defaults.set(data, forKey: "namedGroups")
            }
        }

        loadBotsAndGroups()
        if activeBotId == id {
            selectBot("")
        }
        self.statusMessage = "Deleted bot"
    }

    public func newChat() {
        // Save current draft if any
        let newId = UUID().uuidString
        defaults.set(newId, forKey: activeBotScope + "fridaySession")
        self.currentSessionId = newId
        self.inputMessage = ""
        AssistantService.shared.stopSpeaking()
        loadTranscripts()
        loadSessions()
        self.statusMessage = "Started new conversation"
    }

    public func selectSession(_ id: String) {
        defaults.set(id, forKey: activeBotScope + "fridaySession")
        self.currentSessionId = id
        AssistantService.shared.stopSpeaking()
        loadTranscripts()
        loadSessions()
        self.statusMessage = "Loaded conversation"
    }

    public func loadSessions() {
        let prefix = activeBotScope + "transcript."
        let allKeys = defaults.dictionaryRepresentation().keys
        let matching = allKeys.filter { $0.hasPrefix(prefix) }
        
        var list = [ChatSessionItem]()
        for key in matching {
            let id = String(key.dropFirst(prefix.count))
            let turns = defaults.stringArray(forKey: key) ?? []
            let firstTurn = turns.first ?? ""
            let question = firstTurn.components(separatedBy: "\n\n").first?.dropFirst(4) ?? "Conversation"
            let title = String(question.prefix(45)).replacingOccurrences(of: "\n", with: " ")
            list.append(ChatSessionItem(id: id, title: title.isEmpty ? "New Chat" : title))
        }

        if !list.contains(where: { $0.id == currentSessionId }) {
            list.insert(ChatSessionItem(id: currentSessionId, title: "Current Chat"), at: 0)
        }
        self.savedSessions = list
    }

    public func loadTranscripts() {
        if currentSessionId.isEmpty {
            self.currentSessionId = defaults.string(forKey: activeBotScope + "fridaySession") ?? UUID().uuidString
            defaults.set(currentSessionId, forKey: activeBotScope + "fridaySession")
        }
        let key = activeBotScope + "transcript." + currentSessionId
        self.currentTranscript = defaults.stringArray(forKey: key) ?? []
    }

    public func createBot(name: String, instructions: String) {
        let id = UUID().uuidString
        var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
        current[id] = ["name": name, "instructions": instructions]
        defaults.set(current, forKey: "fridayBots")
        loadBotsAndGroups()
        selectBot(id)
    }

    public func createGroup(name: String, memberIds: [String]) {
        let id = "group-" + UUID().uuidString
        var updated = groups
        updated.append(BotGroup(id: id, name: name, members: memberIds))
        var groupMap = [String: BotGroup]()
        for g in updated { groupMap[g.id] = g }
        if let data = try? JSONEncoder().encode(groupMap) {
            defaults.set(data, forKey: "namedGroups")
            loadBotsAndGroups()
            selectBot(id)
        }
    }

    public func openGroupEditor(groupId: String) {
        guard let grp = groups.first(where: { $0.id == groupId }) else { return }
        editingGroupId = grp.id
        editingGroupName = grp.name
        editingGroupMembers = Set(grp.members)
        showEditGroupModal = true
    }

    public func updateGroup(id: String, name: String, memberIds: [String]) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        guard let groupData = defaults.data(forKey: "namedGroups"),
              var groupMap = try? JSONDecoder().decode([String: BotGroup].self, from: groupData),
              var grp = groupMap[id] else { return }
        grp.name = cleanName
        grp.members = memberIds
        groupMap[id] = grp
        if let data = try? JSONEncoder().encode(groupMap) {
            defaults.set(data, forKey: "namedGroups")
            loadBotsAndGroups()
            self.statusMessage = "Updated group \(cleanName)"
        }
    }

    public func deleteGroup(id: String) {
        guard !id.isEmpty else { return }
        if let groupData = defaults.data(forKey: "namedGroups"),
           var groupMap = try? JSONDecoder().decode([String: BotGroup].self, from: groupData) {
            groupMap.removeValue(forKey: id)
            if let data = try? JSONEncoder().encode(groupMap) {
                defaults.set(data, forKey: "namedGroups")
            }
        }
        loadBotsAndGroups()
        if activeBotId == id {
            selectBot("")
        }
        self.statusMessage = "Group deleted"
    }

    public func removeBotFromGroup(botId: String, groupId: String) {
        guard let groupData = defaults.data(forKey: "namedGroups"),
              var groupMap = try? JSONDecoder().decode([String: BotGroup].self, from: groupData),
              var grp = groupMap[groupId] else { return }
        grp.members.removeAll(where: { $0 == botId })
        groupMap[groupId] = grp
        if let data = try? JSONEncoder().encode(groupMap) {
            defaults.set(data, forKey: "namedGroups")
            loadBotsAndGroups()
            self.statusMessage = "Removed bot from group"
        }
    }

    public var sessionID: String {
        if !currentSessionId.isEmpty { return currentSessionId }
        if let id = defaults.string(forKey: activeBotScope + "fridaySession") {
            self.currentSessionId = id
            return id
        }
        let id = UUID().uuidString
        self.currentSessionId = id
        defaults.set(id, forKey: activeBotScope + "fridaySession")
        return id
    }

    public func loadMemories(query: String = "") {
        guard let store = memoryStore else { return }
        let effScope: String
        switch selectedMemoryScope {
        case "all": effScope = "all"
        case "shared": effScope = "shared"
        default: effScope = memoryScope
        }
        do {
            self.memories = try store.search(query, scope: effScope, limit: 100)
            self.graphTriples = try store.listTriples(scope: effScope, limit: 100)
        } catch {
            self.statusMessage = "Search error: \(error.localizedDescription)"
        }
    }

    public func deleteMemory(_ entry: MemoryEntry) {
        guard let store = memoryStore else { return }
        do {
            try store.remove(entry)
            WorkingMemoryCache.shared.clear()
            loadMemories()
            self.statusMessage = "Memory deleted"
        } catch {
            do {
                try store.remove(id: entry.id)
                WorkingMemoryCache.shared.clear()
                loadMemories()
                self.statusMessage = "Memory deleted"
            } catch {
                self.statusMessage = "Delete error: \(error.localizedDescription)"
            }
        }
    }

    public func deleteTriple(_ triple: GraphTriple) {
        guard let store = memoryStore else { return }
        do {
            try store.deleteTriple(id: triple.id)
            WorkingMemoryCache.shared.clear()
            loadMemories()
            self.statusMessage = "Relational fact deleted"
        } catch {
            self.statusMessage = "Delete error: \(error.localizedDescription)"
        }
    }

    public func clearAllMemories() {
        guard let store = memoryStore else { return }
        let effScope: String
        switch selectedMemoryScope {
        case "all": effScope = "all"
        case "shared": effScope = "shared"
        default: effScope = memoryScope
        }
        do {
            try store.clearAll(scope: effScope)
            WorkingMemoryCache.shared.clear()
            loadMemories()
            self.statusMessage = "Cleared memories for scope: \(selectedMemoryScope)"
        } catch {
            self.statusMessage = "Clear error: \(error.localizedDescription)"
        }
    }

    public func notifyMemoryUpdated(text: String) {
        lastMemoryUpdateNotice = text
        withAnimation(.easeInOut(duration: 0.3)) {
            showMemoryToast = true
        }
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.showMemoryToast = false
                }
            }
        }
    }

    public func saveMemory(body: String, isShared: Bool) {
        guard let store = memoryStore else { return }
        let scope = isShared ? "shared" : memoryScope
        do {
            try store.save(body, scope: scope, source: "User added", original: nil)
            loadMemories()
            notifyMemoryUpdated(text: body)
            self.statusMessage = "Memory saved to \(scope)."
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    public func loadReminders() {
        do {
            self.reminders = try reminderService.list()
            self.activities = try activityService.recent()
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    public func addReminder(text: String, due: Date, frequency: Frequency?) {
        do {
            try reminderService.update { list in
                list.append(Reminder(text: text, due: due, frequency: frequency))
            }
            loadReminders()
            self.statusMessage = "Reminder scheduled."
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    public func sendMessage() {
        let text = inputMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }

        inputMessage = ""
        isBusy = true
        statusMessage = "Understanding request…"

        let key = activeBotScope + "transcript." + sessionID
        var turns = defaults.stringArray(forKey: key) ?? []
        turns.append("You\n" + text)
        defaults.set(turns, forKey: key)
        self.currentTranscript = turns

        Task {
            do {
                let cacheKey = activeBotScope + "screen." + sessionID
                let history = turns.suffix(3).map { String($0.prefix(2000)) }
                let previous = defaults.string(forKey: cacheKey)

                // 1. Intelligent Route Decision
                let decision = try ScreenInferenceRouter.routeQuestion(
                    text,
                    history: history,
                    hasPreviousCapture: previous != nil,
                    provider: provider,
                    model: model
                )

                let botName = currentBotName
                let botInstr = currentBotInstructions

                // Natural Language Memory Forget Handler (ChatGPT / Gemini style)
                let lowerText = text.lowercased()
                let isForgetRequest = lowerText.hasPrefix("forget ") || lowerText.contains("forget that i ") ||
                                      lowerText.contains("forget that my ") || lowerText.contains("forget my ") ||
                                      lowerText.contains("forget about ") || lowerText.contains("delete memory about ") ||
                                      lowerText.contains("remove from memory ")

                if isForgetRequest, let store = self.memoryStore {
                    var targetTopic = text
                    let stripPrefixes = ["forget that i am a ", "forget that i am ", "forget that i ", "forget that my ",
                                         "forget my ", "forget about ", "forget ", "delete memory about ", "remove from memory "]
                    for p in stripPrefixes {
                        if lowerText.contains(p) {
                            if let r = lowerText.range(of: p) {
                                targetTopic = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                    }
                    if targetTopic.isEmpty { targetTopic = text }

                    let deleted = (try? store.deleteMatching(topic: targetTopic, scope: "all")) ?? []
                    WorkingMemoryCache.shared.clear()
                    loadMemories()

                    let replyText: String
                    if !deleted.isEmpty {
                        replyText = "I've updated my memory and forgotten that for you: “\(deleted.first ?? targetTopic)”"
                        notifyMemoryUpdated(text: "Forgotten: \(targetTopic)")
                    } else {
                        replyText = "I checked my memory and couldn't find any stored facts matching “\(targetTopic)”."
                    }

                    turns.append(botName + "\n" + replyText)
                    defaults.set(turns, forKey: key)
                    self.currentTranscript = turns
                    self.statusMessage = "Ready"
                    self.isBusy = false
                    AssistantService.shared.speak(replyText)
                    return
                }

                // 2. Action or Chat Dispatch
                var reply = ""
                switch decision.source {
                case .remember:
                    let proposalReq: [String: Any] = [
                        "operation": "memoryProposal",
                        "question": text,
                        "history": history
                    ]
                    let proposal = try ScreenInferenceRouter.infer(proposalReq, provider: provider, model: model)
                    saveMemory(body: proposal, isShared: true)
                    reply = "I've remembered that for you: “\(proposal)”"

                case .control:
                    statusMessage = "Operating Mac app…"
                    let planReq: [String: Any] = ["operation": "control", "question": text]
                    let planJson = try ScreenInferenceRouter.infer(planReq, provider: provider, model: model)
                    let activeProvider = provider
                    let activeModel = model
                    reply = try MacAutomationDriver.performMacPlan(planJson) { visible in
                        var rev = planReq
                        rev["visibleControls"] = visible
                        rev["initialPlan"] = planJson
                        let revPlan = try ScreenInferenceRouter.infer(rev, provider: activeProvider, model: activeModel)
                        return try JSONDecoder().decode(MacPlan.self, from: Data(revPlan.utf8))
                    }

                case .active:
                    statusMessage = "Reading active window…"
                    let capture = try MacAutomationDriver.readActiveWindow()
                    defaults.set(String(capture.prefix(12000)), forKey: cacheKey)
                    let answerReq: [String: Any] = ["operation": "answer", "capture": String(capture.prefix(12000)), "question": text]
                    reply = try ScreenInferenceRouter.infer(answerReq, provider: provider, model: model)

                case .editor:
                    statusMessage = "Reading TextEdit document…"
                    let capture = try MacAutomationDriver.readEditor(text)
                    reply = "TextEdit contents:\n" + capture

                case .mailReply, .calendarReply:
                    statusMessage = "Drafting Apple Mail reply…"
                    let helper = Bundle.main.path(forResource: "mail_reply", ofType: "js")
                        ?? "/Users/user/Documents/Codex/2026-11-23/i-w/outputs/Friday.app/Contents/Resources/mail_reply.js"
                    let msg = try MailCalendarService.mailOperation(["read"], helperScriptPath: helper)
                    guard let ident = msg["identity"], let body = msg["body"], let subj = msg["subject"] else {
                        throw FridayError.message("Could not read selected email.")
                    }
                    var draftReq: [String: Any] = ["operation": "mailBody", "question": text, "subject": subj, "body": body]
                    if decision.source == .calendarReply {
                        draftReq["calendar"] = try MailCalendarService.upcomingCalendarConflicts()
                    }
                    let draft = try ScreenInferenceRouter.infer(draftReq, provider: provider, model: model)
                    _ = try MailCalendarService.mailOperation(["draft", ident, draft], helperScriptPath: helper)
                    reply = "Reply draft opened in Apple Mail for review."

                case .previous:
                    if let prev = previous {
                        let answerReq: [String: Any] = ["operation": "answer", "capture": prev, "question": text]
                        reply = try ScreenInferenceRouter.infer(answerReq, provider: provider, model: model)
                    } else {
                        reply = "No previous screen capture available for follow-up."
                    }

                case .chat:
                    // 1. Working Memory & Identity Context Retrieval
                    var context = ""
                    let cacheKey = self.memoryScope + "::" + text
                    if let cached = WorkingMemoryCache.shared.get(key: cacheKey) {
                        context = cached.map { "[" + $0.scope + "] " + $0.body }.joined(separator: "\n")
                    } else if let store = memoryStore {
                        var contextLines = [String]()

                        let lowerText = text.lowercased()
                        let isIdentityQuery = lowerText.contains("my name") || lowerText.contains("who am i") ||
                                             lowerText.contains("who i am") || lowerText.contains("know me") ||
                                             lowerText.contains("what's my name")

                        // Graph Triples Join (GraphRAG)
                        let tripleQuery = isIdentityQuery ? "name user" : text
                        if let triples = try? store.queryTriples(query: tripleQuery, scope: memoryScope, limit: 3), !triples.isEmpty {
                            contextLines.append("Relational facts: " + triples.map { $0.summary }.joined(separator: ", "))
                        }
                        // Hybrid Stanford-Scored Semantic Memories
                        let searchQuery = isIdentityQuery ? "user name" : text
                        if let results = try? store.search(searchQuery, scope: memoryScope, limit: 3) {
                            WorkingMemoryCache.shared.set(key: cacheKey, entries: results)
                            contextLines.append(contentsOf: results.map { "[" + $0.scope + "] " + $0.body })
                        }
                        context = contextLines.joined(separator: "\n")
                    }

                    // 2. Discover Candidate Bots (Group or Active + @Mentions)
                    struct CandidateBot {
                        let id: String
                        let name: String
                        let instructions: String
                        let provider: String
                        let model: String
                    }

                    var candidates = [CandidateBot]()

                    if isGroupSelected {
                        for memberId in groupMembers {
                            let memberName = memberId.isEmpty ? fridayName : (bots.first(where: { $0.id == memberId })?.name ?? "FRIDAY")
                            let memberInstr = memberId.isEmpty ? fridayInstructions : (bots.first(where: { $0.id == memberId })?.instructions ?? "")
                            let prefix = memberId.isEmpty ? "" : "bot." + memberId + "."
                            let botProvider = defaults.string(forKey: prefix + "chatProvider") ?? provider
                            let botModel = defaults.string(forKey: prefix + "chatModel") ?? model
                            candidates.append(CandidateBot(id: memberId, name: memberName, instructions: memberInstr, provider: botProvider, model: botModel))
                        }
                    } else {
                        // 1-on-1 Chat: Active bot is primary
                        candidates.append(CandidateBot(id: activeBotId, name: botName, instructions: botInstr, provider: provider, model: model))

                        // Check if any other bots were @mentioned for delegation or collaboration
                        for mb in mentionableBots where mb.name.caseInsensitiveCompare(botName) != .orderedSame {
                            if text.localizedCaseInsensitiveContains("@" + mb.name) {
                                let mbInstr = mb.id.isEmpty ? fridayInstructions : (bots.first(where: { $0.id == mb.id })?.instructions ?? "")
                                let prefix = mb.id.isEmpty ? "" : "bot." + mb.id + "."
                                let bProvider = defaults.string(forKey: prefix + "chatProvider") ?? provider
                                let bModel = defaults.string(forKey: prefix + "chatModel") ?? model
                                candidates.append(CandidateBot(id: mb.id, name: mb.name, instructions: mbInstr, provider: bProvider, model: bModel))
                            }
                        }
                    }

                    // 3. Execution: Single Bot or Multi-Agent Turn Orchestration
                    if candidates.count == 1 {
                        let single = candidates[0]
                        statusMessage = "Streaming response…"
                        reply = try await AssistantService.shared.streamChat(
                            prompt: text,
                            history: turns,
                            provider: single.provider,
                            model: single.model,
                            sessionID: sessionID,
                            contextMemory: context,
                            botName: single.name,
                            botInstructions: single.instructions,
                            onChunk: { _ in }
                        )
                        let cleanReply = AssistantService.cleanBotReply(reply, botName: single.name)
                        turns.append(single.name + "\n" + cleanReply)
                        defaults.set(turns, forKey: key)
                        self.currentTranscript = turns
                        self.statusMessage = "Ready"
                        self.isBusy = false
                        AssistantService.shared.speak(cleanReply)
                    } else {
                        statusMessage = "Orchestrating agent collaboration…"
                        let respondingNames = try await AssistantService.shared.resolveRespondingBots(
                            transcript: turns,
                            userMessage: text,
                            candidateBots: candidates.map { ($0.name, $0.instructions) },
                            provider: provider,
                            model: model
                        )

                        for targetName in respondingNames {
                            guard let target = candidates.first(where: { $0.name.caseInsensitiveCompare(targetName) == .orderedSame }) else { continue }

                            statusMessage = "\(target.name) is replying…"
                            let contextTurns = turns.suffix(16).joined(separator: "\n\n")
                            let otherBots = candidates.filter { $0.name.caseInsensitiveCompare(target.name) != .orderedSame }.map { $0.name }
                            let otherBotsNotice = otherBots.isEmpty ? "" : "Other bots in this conversation: \(otherBots.joined(separator: ", "))."

                            let cleanInstr = target.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                            let effectiveInstr = cleanInstr.isEmpty ? "You are a helpful, thoughtful, and intelligent AI assistant." : cleanInstr

                            let groupPrompt = """
                            [SYSTEM DIRECTIVE: STRICT CHARACTER & ROLEPLAY PERSONA]
                            You are \(target.name).
                            Core Identity, Tone, & Instructions:
                            \(effectiveInstr)
                            \(otherBotsNotice)

                            STRICT MULTI-AGENT COLLABORATION PROTOCOL:
                            1. You are speaking EXCLUSIVELY as \(target.name).
                            2. Embody your assigned identity and persona (\(effectiveInstr)) completely in your voice, tone, and worldview.
                            3. NEVER generate responses, simulate dialogue, or write on behalf of any other bot (\(otherBots.joined(separator: ", "))). Each bot is an independent agent and is called in its own separate turn.
                            4. If the user addressed multiple bots in their message, respond ONLY to the part intended for \(target.name).
                            5. Respond directly in your own persona. Do not prefix your message with your name (do NOT write "\(target.name):" or "**\(target.name)**:").
                            6. Do NOT output internal reasoning, thought commentary, or preambles (never write "Let me respond directly...").
                            \(context.isEmpty ? "" : "\nDurable User Profile & Memory Context:\n" + context + "\n")
                            Conversation transcript so far:
                            \(contextTurns)
                            """

                            let rawMemberReply = try await AssistantService.shared.executeRawChat(
                                prompt: groupPrompt,
                                provider: target.provider,
                                model: target.model
                            )
                            let memberReply = AssistantService.cleanBotReply(
                                rawMemberReply,
                                botName: target.name,
                                otherBotNames: candidates.map(\.name)
                            )
                            guard !memberReply.isEmpty else { continue }
                            turns.append(target.name + "\n" + memberReply)
                            defaults.set(turns, forKey: key)
                            self.currentTranscript = turns
                        }

                        statusMessage = "Ready"
                        self.isBusy = false
                        if let lastTurn = turns.last {
                            let textToSpeak = lastTurn.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                            AssistantService.shared.speak(textToSpeak)
                        }
                    }

                    // 4. Autonomous Background Fact & Graph Triple Extraction
                    if let store = self.memoryStore {
                        let lastReply = turns.last ?? reply
                        BackgroundFactExtractor.shared.processTurn(
                            userPrompt: text,
                            assistantResponse: lastReply,
                            botName: isGroupSelected ? "Group" : botName,
                            scope: self.memoryScope,
                            store: store,
                            provider: self.provider,
                            model: self.model
                        )
                    }
                    return
                }

                if !reply.isEmpty {
                    turns.append(botName + "\n" + reply)
                    defaults.set(turns, forKey: key)
                    self.currentTranscript = turns
                    self.statusMessage = "Ready"
                    self.isBusy = false
                    AssistantService.shared.speak(reply)
                }

            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }
}
