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
    @Published public var activeBotId: String = ""
    @Published public var bots: [BotProfile] = []
    @Published public var groups: [BotGroup] = []
    @Published public var provider: String = ""
    @Published public var model: String = ""
    
    // Memory & Reminders
    @Published public var memories: [MemoryEntry] = []
    @Published public var reminders: [Reminder] = []
    @Published public var activities: [ActivityEntry] = []

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

    public func selectBot(_ id: String) {
        defaults.set(provider, forKey: activeBotScope + "chatProvider")
        defaults.set(model, forKey: activeBotScope + "chatModel")
        activeBotId = id
        defaults.set(id, forKey: "activeBot")
        self.provider = defaults.string(forKey: activeBotScope + "chatProvider") ?? ""
        self.model = defaults.string(forKey: activeBotScope + "chatModel") ?? ""
        loadTranscripts()
        loadMemories()
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

    public var sessionID: String {
        if let id = defaults.string(forKey: activeBotScope + "fridaySession") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: activeBotScope + "fridaySession")
        return id
    }

    public func loadTranscripts() {
        let key = activeBotScope + "transcript." + sessionID
        self.currentTranscript = defaults.stringArray(forKey: key) ?? []
    }

    public func loadMemories(query: String = "") {
        guard let store = memoryStore else { return }
        do {
            self.memories = try store.search(query, scope: memoryScope, limit: 50)
        } catch {
            self.statusMessage = "Search error: \(error.localizedDescription)"
        }
    }

    public func saveMemory(body: String, isShared: Bool) {
        guard let store = memoryStore else { return }
        let scope = isShared ? "shared" : memoryScope
        do {
            try store.save(body, scope: scope, source: "User added", original: nil)
            loadMemories()
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

                let botName = bots.first(where: { $0.id == activeBotId })?.name ?? "FRIDAY"
                let botInstr = bots.first(where: { $0.id == activeBotId })?.instructions ?? ""

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
                    if isGroupSelected {
                        // Multi-Bot Group Conversation
                        for memberId in groupMembers {
                            let memberName = bots.first(where: { $0.id == memberId })?.name ?? "FRIDAY"
                            let memberInstr = bots.first(where: { $0.id == memberId })?.instructions ?? ""
                            statusMessage = "\(memberName) is replying…"
                            let memberReply = try await AssistantService.shared.streamChat(
                                prompt: text,
                                provider: provider,
                                model: model,
                                sessionID: sessionID,
                                contextMemory: "",
                                botName: memberName,
                                botInstructions: memberInstr,
                                onChunk: { _ in }
                            )
                            turns.append(memberName + "\n" + memberReply)
                            defaults.set(turns, forKey: key)
                            self.currentTranscript = turns
                        }
                        statusMessage = "Ready"
                        isBusy = false
                        return
                    } else {
                        // Fast LRU Working Memory Cache & Hybrid Context Retrieval
                        var context = ""
                        let cacheKey = self.memoryScope + "::" + text
                        if let cached = WorkingMemoryCache.shared.get(key: cacheKey) {
                            context = cached.map { "[" + $0.scope + "] " + $0.body }.joined(separator: "\n")
                        } else if let store = memoryStore {
                            var contextLines = [String]()
                            // 1. Graph Triples Join (GraphRAG)
                            if let triples = try? store.queryTriples(query: text, scope: memoryScope, limit: 3), !triples.isEmpty {
                                contextLines.append("Relational facts: " + triples.map { $0.summary }.joined(separator: ", "))
                            }
                            // 2. Hybrid Stanford-Scored Semantic Memories
                            if let results = try? store.search(text, scope: memoryScope, limit: 3) {
                                WorkingMemoryCache.shared.set(key: cacheKey, entries: results)
                                contextLines.append(contentsOf: results.map { "[" + $0.scope + "] " + $0.body })
                            }
                            context = contextLines.joined(separator: "\n")
                        }
                        statusMessage = "Streaming response…"
                        reply = try await AssistantService.shared.streamChat(
                            prompt: text,
                            provider: provider,
                            model: model,
                            sessionID: sessionID,
                            contextMemory: context,
                            botName: botName,
                            botInstructions: botInstr,
                            onChunk: { _ in }
                        )
                    }
                }

                turns.append(botName + "\n" + reply)
                defaults.set(turns, forKey: key)
                self.currentTranscript = turns
                self.statusMessage = "Ready"
                self.isBusy = false
                AssistantService.shared.speak(reply)

                // Autonomous Background Fact & Graph Triple Extraction
                if let store = self.memoryStore {
                    BackgroundFactExtractor.shared.processTurn(
                        userPrompt: text,
                        assistantResponse: reply,
                        scope: self.memoryScope,
                        store: store,
                        provider: self.provider,
                        model: self.model
                    )
                }

            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }
}
