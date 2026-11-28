import SwiftUI
import FridayCore

private final class StreamChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated = ""
    private var lastEmit: Date = .distantPast
    private var pendingTrailing = false

    func append(_ chunk: String, onUpdate: @escaping @Sendable (String) -> Void) {
        lock.lock()
        let isFirst = accumulated.isEmpty
        accumulated += chunk
        let current = accumulated
        let now = Date()
        let shouldEmitNow = isFirst || now.timeIntervalSince(lastEmit) >= 0.035
        if shouldEmitNow {
            lastEmit = now
            pendingTrailing = false
            lock.unlock()
            onUpdate(current)
            return
        }
        let scheduleTrailing = !pendingTrailing
        if scheduleTrailing { pendingTrailing = true }
        lock.unlock()

        if scheduleTrailing {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.pendingTrailing else {
                    self.lock.unlock()
                    return
                }
                self.pendingTrailing = false
                self.lastEmit = Date()
                let text = self.accumulated
                self.lock.unlock()
                onUpdate(text)
            }
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var inputMessage: String = ""
    @Published public var showScreenPermissionHelp = false
    @Published public var statusMessage: String = "Ready"
    @Published public var isBusy: Bool = false
    @Published public var currentTranscript: [String] = []
    
    // Voice & Wake Word
    @Published public var isVoiceActive: Bool = false
    @Published public var isTTSEnabled: Bool = true {
        didSet {
            guard !loadingVoiceSettings else { return }
            if isWakeEnabled && !isTTSEnabled {
                isTTSEnabled = true
                return
            }
            defaults.set(isTTSEnabled, forKey: "friday.isTTSEnabled")
            AssistantService.shared.setMuted(!isTTSEnabled)
        }
    }
    @Published public var isWakeEnabled: Bool = false {
        didSet {
            guard oldValue != isWakeEnabled else { return }
            if isWakeEnabled {
                if !isTTSEnabled {
                    isTTSEnabled = true
                } else {
                    AssistantService.shared.setMuted(false)
                }
                guard servicesEnabled else { return }
                if VoiceService.shared.isActive { VoiceService.shared.stopCapture() }
                armWakeIfReady()
            } else {
                guard servicesEnabled else { return }
                VoiceService.shared.stopCapture()
                isVoiceActive = false
            }
        }
    }
    @Published public var audioLevel: Double = 0.0
    @Published public var availableMics: [String] = []
    @Published public var selectedMic: String = "" {
        didSet {
            guard selectedMic != oldValue else { return }
            defaults.set(selectedMic, forKey: "fridayMic")
            if isWakeEnabled, servicesEnabled {
                VoiceService.shared.stopCapture()
                armWakeIfReady()
            }
        }
    }

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
    @Published public var provider: String = "" { didSet { if !loadingModels { defaults.set(provider,forKey:activeBotScope+"chatProvider") } } }
    @Published public var model: String = "" { didSet { if !loadingModels { defaults.set(model,forKey:activeBotScope+"chatModel") } } }
    private var loadingModels = false
    
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

    // Persona, Voice & Instructions Editing
    @Published public var showEditPersonaModal: Bool = false
    @Published public var editingBotId: String = ""
    @Published public var editingBotName: String = ""
    @Published public var editingBotInstructions: String = ""
    @Published public var editingBotVoice: String = ""
    @Published public var editingBotRole: BotRolePreset = .auto
    @Published public var openRouterAPIKey = ""
    @Published public private(set) var speechCredentialStatus = ""

    // Multi-Model Orchestration & Opt-In Capabilities
    @Published public var isDeciderRoutingEnabled: Bool = false {
        didSet { if !loadingMultiModelSettings { defaults.set(isDeciderRoutingEnabled, forKey: "friday.optIn.perplexityDecider") } }
    }
    @Published public var memoryEmbeddingMode: MemoryEmbeddingMode = .localOnly {
        didSet { if !loadingMultiModelSettings { defaults.set(memoryEmbeddingMode.rawValue, forKey: "friday.optIn.embeddingMode") } }
    }
    @Published public var isCloudRerankEnabled: Bool = false {
        didSet { if !loadingMultiModelSettings { defaults.set(isCloudRerankEnabled, forKey: "friday.optIn.cloudRerank") } }
    }
    @Published public var hasOpenRouterCredits: Bool = false {
        didSet { if !loadingMultiModelSettings { defaults.set(hasOpenRouterCredits, forKey: "friday.openrouter.hasCredits") } }
    }
    @Published public private(set) var dailyFreeRequests: Int = 0
    @Published public private(set) var openRouterCatalogModels: [OpenRouterModelDescriptor] = []
    @Published public var openRouterRefreshStatus: String = ""
    private var loadingMultiModelSettings = false

    public func saveSpeechCredential(remove: Bool = false) {
        do {
            try SpeechCredential.save(remove ? "" : openRouterAPIKey)
            defaults.removeObject(forKey: "friday.openrouterApiKey")
            openRouterAPIKey = ""
            speechCredentialStatus = remove ? "Removed the saved voice key." : "Voice key saved in Keychain."
        } catch {
            speechCredentialStatus = "Keychain: " + error.localizedDescription
        }
    }

    @Published public var openRouterTTSModel: String = HeyGenTTSCatalog.defaultModel {
        didSet {
            if !loadingVoiceSettings {
                defaults.set(openRouterTTSModel, forKey: "friday.openrouterTTSModel")
            }
        }
    }
    private var loadingVoiceSettings = false

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

    @Published var liveWakePresented=false
    var autoStartLive=false
    func presentLive(fromWake:Bool=false){
        guard !liveWakePresented else {return}
        autoStartLive=fromWake
        liveWakePresented=true
        if VoiceService.shared.isActive {VoiceService.shared.stopCapture();isVoiceActive=false}
    }
    let cloudAccount = CloudAccount()
    let mobileCompanion = MobileCompanion()
    private let defaults:UserDefaults
    private let servicesEnabled: Bool
    private var activeStream: StreamChunkBuffer?
    private var reminderTimer: Timer?

    public init(defaults:UserDefaults = .standard,
                appSupport:URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0],
                startServices:Bool = true) {
        self.defaults=defaults
        self.servicesEnabled = startServices
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

        loadingVoiceSettings = true
        if startServices, let legacy = defaults.string(forKey: "friday.openrouterApiKey"), !legacy.isEmpty {
            do {
                try SpeechCredential.save(legacy)
                defaults.removeObject(forKey: "friday.openrouterApiKey")
            } catch { speechCredentialStatus = "Could not move the saved voice key to Keychain." }
        }
        let savedTTSModel = defaults.string(forKey: "friday.openrouterTTSModel") ?? ""
        self.openRouterTTSModel = savedTTSModel.isEmpty ? HeyGenTTSCatalog.defaultModel : savedTTSModel
        let savedTTSEnabled = defaults.object(forKey: "friday.isTTSEnabled") as? Bool ?? true
        self.isTTSEnabled = savedTTSEnabled
        loadingVoiceSettings = false
        if startServices {
            AssistantService.shared.setMuted(!savedTTSEnabled)
        }

        loadingMultiModelSettings = true
        self.isDeciderRoutingEnabled = defaults.bool(forKey: "friday.optIn.perplexityDecider")
        let savedEmbed = defaults.string(forKey: "friday.optIn.embeddingMode") ?? ""
        self.memoryEmbeddingMode = MemoryEmbeddingMode(rawValue: savedEmbed) ?? .localOnly
        self.isCloudRerankEnabled = defaults.bool(forKey: "friday.optIn.cloudRerank")
        self.hasOpenRouterCredits = defaults.bool(forKey: "friday.openrouter.hasCredits")
        loadingMultiModelSettings = false
        self.dailyFreeRequests = OpenRouterModelRegistry.shared.todayFreeRequestCount()
        self.openRouterCatalogModels = OpenRouterModelRegistry.shared.allModels()

        AssistantService.shared.onSpeechError = { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }

        loadBotsAndGroups()
        loadTranscripts()
        loadReminders()
        if startServices {
            setupVoicePipeline()
            startReminderPoller()
            Task { try? await self.refreshOpenRouterCatalog(force: false) }
        }
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
        let savedMic = defaults.string(forKey: "fridayMic") ?? ""
        self.selectedMic = availableMics.contains(savedMic) ? savedMic : availableMics.first ?? ""

        voice.onLevelUpdate = { [weak self] level in self?.audioLevel = level }
        voice.onStateUpdate = { [weak self] state in
            if self?.isWakeEnabled == true && state == "Listening" {AssistantService.shared.stopSpeaking()}
            if let self, state=="Listening", self.isWakeEnabled, !self.cloudAccount.token.isEmpty, !self.liveWakePresented {
                self.presentLive(fromWake:true)
                self.statusMessage="Opening Gemini Live"
                return
            }
            self?.statusMessage = state
        }
        voice.onTranscriptionComplete = { [weak self] text in
            guard let self else {return}
            self.isVoiceActive = false
            self.inputMessage = text
            self.statusMessage = "Review transcription, then Send"
            if self.isWakeEnabled {self.sendMessage()}
        }
        voice.onError = { [weak self] error in
            self?.isVoiceActive = false
            self?.isWakeEnabled = false
            self?.statusMessage = error
        }
    }

    private func armWakeIfReady() {
        guard isWakeEnabled, !liveWakePresented, !isBusy, !VoiceService.shared.isActive else {return}
        isVoiceActive = true
        VoiceService.shared.startCapture(handsFree:true,micDeviceName:selectedMic)
    }

    public func toggleVoiceRecording() {
        if isWakeEnabled {isWakeEnabled = false; return}
        if VoiceService.shared.isActive {VoiceService.shared.finishCapture();return}
        isVoiceActive = true
        VoiceService.shared.startCapture(handsFree:false,micDeviceName:selectedMic)
    }

    private func startReminderPoller() {
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDueReminders(); self?.armWakeIfReady() }
        }
    }

    private func checkDueReminders() {
        guard !isBusy, let rem = try? reminderService.takeDue(at: Date()) else { return }
        statusMessage = "Reminder: " + rem.text
        try? activityService.append(ActivityEntry(date: Date(), scheduled: rem.due, action: "Reminder Fired", subject: rem.text))
        loadReminders()
        AssistantService.shared.speak("Reminder: " + rem.text, voice: fridayVoice)
    }

    public func loadBotsAndGroups() {
        if let botDict = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] {
            self.bots = botDict.map {
                BotProfile(
                    id: $0.key,
                    name: $0.value["name"] ?? "Bot",
                    instructions: $0.value["instructions"] ?? "",
                    voice: $0.value["voice"] ?? "",
                    role: BotRolePreset(rawValue: $0.value["role"] ?? "") ?? .auto
                )
            }.sorted(by: { $0.name < $1.name })
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
        loadingModels = true
        defer { loadingModels = false }
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

    public var fridayVoice: String {
        defaults.string(forKey: "fridayCustomVoice") ?? ""
    }

    public func voiceForBot(id: String) -> String {
        if id.isEmpty {
            return fridayVoice
        }
        return bots.first(where: { $0.id == id })?.voice ?? ""
    }

    public var currentBotVoice: String {
        get {
            guard !isGroupSelected else { return "" }
            return voiceForBot(id: activeBotId)
        }
        set {
            setVoiceForBot(id: activeBotId, voice: newValue)
        }
    }

    public func setVoiceForBot(id: String, voice: String) {
        if id.isEmpty {
            defaults.set(voice, forKey: "fridayCustomVoice")
            objectWillChange.send()
        } else {
            var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
            var entry = current[id] ?? [:]
            entry["voice"] = voice
            current[id] = entry
            defaults.set(current, forKey: "fridayBots")
            loadBotsAndGroups()
        }
    }

    public var fridayRole: BotRolePreset {
        BotRolePreset(rawValue: defaults.string(forKey: "fridayCustomRole") ?? "") ?? .auto
    }

    public func botRole(for id: String) -> BotRolePreset {
        if id.isEmpty { return fridayRole }
        return bots.first(where: { $0.id == id })?.role ?? .auto
    }

    public var currentBotRole: BotRolePreset {
        get { isGroupSelected ? .orchestrator : botRole(for: activeBotId) }
        set { setRoleForBot(id: activeBotId, role: newValue) }
    }

    public func setRoleForBot(id: String, role: BotRolePreset) {
        if id.isEmpty {
            defaults.set(role.rawValue, forKey: "fridayCustomRole")
            objectWillChange.send()
        } else {
            var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
            var entry = current[id] ?? [:]
            entry["role"] = role.rawValue
            current[id] = entry
            defaults.set(current, forKey: "fridayBots")
            loadBotsAndGroups()
        }
    }

    public func refreshOpenRouterCatalog(force: Bool = false) async throws {
        openRouterRefreshStatus = "Syncing OpenRouter models…"
        let list = try await OpenRouterModelRegistry.shared.refreshIfNeeded(force: force)
        self.openRouterCatalogModels = list
        let freeCount = list.filter(\.isFree).count
        self.openRouterRefreshStatus = "Synced \(list.count) models (\(freeCount) free)."
    }

    public func syncQuotaCount() {
        self.dailyFreeRequests = OpenRouterModelRegistry.shared.todayFreeRequestCount()
    }

    public func previewVoice(_ voice: String, botName: String) {
        let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = HeyGenTTSCatalog.voices.first(where: { $0.id == voice })?.label ?? voice
        let sample = "Hello! I'm \(name.isEmpty ? fridayName : name), speaking with \(voice.isEmpty ? "the macOS system voice" : label)."
        AssistantService.shared.speak(sample, voice: voice, force: true)
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

    public func updateBot(id: String, name: String, instructions: String, voice: String? = nil, role: BotRolePreset? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            // Updating Core Friday
            defaults.set(cleanName.isEmpty ? "FRIDAY" : cleanName, forKey: "fridayCustomName")
            defaults.set(instructions, forKey: "fridayCustomInstructions")
            if let voice {
                defaults.set(voice, forKey: "fridayCustomVoice")
            }
            if let role {
                defaults.set(role.rawValue, forKey: "fridayCustomRole")
            }
            objectWillChange.send()
            self.statusMessage = "Updated \(fridayName) persona"
        } else {
            // Updating custom bot
            var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
            let existingVoice = current[id]?["voice"] ?? ""
            let existingRole = current[id]?["role"] ?? BotRolePreset.auto.rawValue
            current[id] = [
                "name": cleanName.isEmpty ? "Bot" : cleanName,
                "instructions": instructions,
                "voice": voice ?? existingVoice,
                "role": role?.rawValue ?? existingRole
            ]
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
            editingBotVoice = fridayVoice
            editingBotRole = fridayRole
            showEditPersonaModal = true
        } else if let b = bots.first(where: { $0.id == targetId }) {
            editingBotId = b.id
            editingBotName = b.name
            editingBotInstructions = b.instructions
            editingBotVoice = b.voice
            editingBotRole = b.role
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

    public func createBot(name: String, instructions: String, voice: String = "", role: BotRolePreset = .auto) {
        let id = UUID().uuidString
        var current = defaults.dictionary(forKey: "fridayBots") as? [String: [String: String]] ?? [:]
        current[id] = ["name": name, "instructions": instructions, "voice": voice, "role": role.rawValue]
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

    @Published var pendingMailSubject:String?
    @Published var controlTask:Task<String,Error>?
    private var guests=[String:GuestController]()
    func guestForBot()->GuestController {
        guestForOwner(activeBotId)
    }
    func guestForOwner(_ id:String)->GuestController {
        if let existing=guests[id] {return existing}
        let new=GuestController();guests[id]=new;return new
    }
    private var memorySearchTask: Task<Void,Never>?
    private var currentMemoryQuery = ""
    public func loadMemories(query: String? = nil) {
        if let query { currentMemoryQuery = query }
        memorySearchTask?.cancel()
        guard let store = memoryStore else {return}
        let q = currentMemoryQuery
        let scope = ["all","shared"].contains(selectedMemoryScope) ? selectedMemoryScope : memoryScope
        memorySearchTask = Task {
            do {
                try await Task.sleep(for:.milliseconds(180))
                let result = try await Task.detached(priority:.userInitiated) {
                    let entries = try store.search(q,scope:scope,limit:100)
                    let triples = q.isEmpty ? try store.listTriples(scope:scope,limit:100) : try store.queryTriples(query:q,scope:scope,limit:100)
                    return (entries,triples)
                }.value
                try Task.checkCancellation()
                memories=result.0;graphTriples=result.1
            } catch { if !Task.isCancelled {statusMessage=error.localizedDescription} }
        }
    }

    func reviseMemory(_ entry:MemoryEntry,body:String,scope:String) throws {
        guard let memoryStore else {throw FridayError.message("Memory store unavailable")}
        try memoryStore.save(body,scope:scope,source:entry.source,importance:entry.importance,original:entry)
        WorkingMemoryCache.shared.clear()
        loadMemories()
    }

    func showOrigin(_ source:String) {
        guard let origin=MemoryOrigin.decode(source),
              let turns=defaults.stringArray(forKey:(origin.bot.isEmpty ? "" : "bot."+origin.bot+".")+"transcript."+origin.session),
              turns.indices.contains(origin.turn) else {statusMessage="Original turn unavailable";return}
        let panel=NSAlert()
        panel.messageText="Original chat turn";panel.informativeText=turns[origin.turn]
        panel.addButton(withTitle:"Open conversation");panel.addButton(withTitle:"Close")
        if panel.runModal() == .alertFirstButtonReturn {
            selectBot(origin.bot);selectSession(origin.session);selectedTab=0
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
            self.statusMessage = "Delete error: \(error.localizedDescription)"
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
        let mode = memoryEmbeddingMode
        do {
            try store.save(body, scope: scope, source: "User added", original: nil)
            if mode == .cloudAll {
                Task.detached(priority: .utility) {
                    await HybridMemoryCloudHelper.attachCloudEmbeddingToMemoryIfSaved(
                        store: store,
                        scope: scope,
                        body: body
                    )
                }
            }
            loadMemories()
            notifyMemoryUpdated(text: body)
            self.statusMessage = "Memory saved to \(scope)."
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    public func generateImage(prompt: String, aspectRatio: String = "", background: String = "") async throws -> OpenRouterGeneratedImage {
        let generated = try await OpenRouterClient.shared.generateImage(
            prompt: prompt,
            aspectRatio: aspectRatio.isEmpty ? nil : aspectRatio,
            background: background.isEmpty ? nil : background
        )
        self.syncQuotaCount()
        return generated
    }

    public func indexRAGDocument(title: String, body: String, mediaType: String = "text", sourcePath: String? = nil) async throws {
        guard let store = memoryStore else { throw FridayError.message("Memory store unavailable.") }
        let useCloud = memoryEmbeddingMode != .localOnly
        _ = try await HybridMemoryCloudHelper.indexDocument(
            store: store,
            scope: memoryScope,
            title: title,
            body: body,
            mediaType: mediaType,
            sourcePath: sourcePath,
            useCloudEmbedding: useCloud
        )
        self.syncQuotaCount()
        self.statusMessage = "Indexed \(title) into knowledge base."
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

        if currentSessionId.hasPrefix("cloud-account-") {
            guard !cloudAccount.token.isEmpty else {statusMessage="Sign in under Settings → Account";return}
            isBusy=true
            let id=String(currentSessionId.dropFirst("cloud-account-".count))
            Task { await cloudAccount.sendFromMirror(text,id:id,state:self) }
            return
        }
        if isWakeEnabled {VoiceService.shared.stopCapture();isVoiceActive = false}
        inputMessage = ""
        isBusy = true
        statusMessage = "Understanding request…"

        let originatingScope = memoryScope
        let key = activeBotScope + "transcript." + sessionID
        var turns = defaults.stringArray(forKey: key) ?? []
        let origin = MemoryOrigin(bot:activeBotId,session:sessionID,turn:turns.count).encoded
        turns.append("You\n" + text)
        defaults.set(turns, forKey: key)
        self.currentTranscript = turns

        Task {
            do {
                let cacheKey = activeBotScope + "screen." + sessionID
                let history = turns.dropLast().suffix(3).map { String($0.prefix(2000)) }
                let previous = defaults.string(forKey: cacheKey)

                let botName = currentBotName
                let botInstr = currentBotInstructions
                let activeProvider = provider
                let activeModel = model
                let useDecider = isDeciderRoutingEnabled
                let embedMode = memoryEmbeddingMode
                let useRerank = isCloudRerankEnabled

                if let topic = ForgetRequest.topic(in:text), let store = self.memoryStore {
                    let (local, shared) = try await Task.detached(priority: .userInitiated) {
                        let l = try store.previewForget(topic: topic, scope: originatingScope)
                        let s = try store.previewForget(topic: topic, scope: "shared")
                        return (l, s)
                    }.value
                    var replyText = "No matching memories in this conversation or shared memory."
                    if !local.isEmpty || !shared.isEmpty {
                        let panel = NSAlert()
                        panel.messageText = "Review memories to forget"
                        let scope = local.isEmpty ? "shared" : originatingScope
                        let matches = local.isEmpty ? shared : local
                        panel.informativeText = "Audience: " + scope + "\n\n" + matches.map(\.description).joined(separator:"\n")
                        panel.addButton(withTitle:"Cancel")
                        panel.addButton(withTitle:"Forget these memories")
                        if panel.runModal() == .alertSecondButtonReturn {
                            try await Task.detached(priority: .userInitiated) {
                                try store.forget(topic: topic, scope: scope, approved: matches)
                            }.value
                            WorkingMemoryCache.shared.clear()
                            loadMemories()
                            replyText = "Removed the reviewed memories."
                        } else {replyText = "Kept the memories."}
                    }
                    turns.append(botName + "\n" + replyText)
                    defaults.set(turns, forKey: key)
                    self.currentTranscript = turns
                    self.statusMessage = "Ready"
                    self.isBusy = false
                    AssistantService.shared.speak(replyText, voice: voiceForBot(id: activeBotId))
                    return
                }

                // 1. Intelligent Route Decision (Perplexity Decider when opted-in, else fast OpenRouter/Hermes router)
                let decision = try await MultiModelRouter.routeQuestion(
                    text,
                    history: history,
                    hasPreviousCapture: previous != nil,
                    provider: activeProvider,
                    model: activeModel,
                    usePerplexityDecider: useDecider
                )

                // 2. Action or Chat Dispatch
                var reply = ""
                switch decision.source {
                case .remember:
                    let proposalReq: [String: Any] = [
                        "operation": "memoryProposal",
                        "question": text,
                        "history": history
                    ]
                    let proposal = try await Task.detached(priority: .userInitiated) {
                        try ScreenInferenceRouter.infer(proposalReq, provider: activeProvider, model: activeModel)
                    }.value
                    let panel = NSAlert()
                    panel.messageText = "Save this memory?"
                    panel.informativeText = proposal
                    panel.addButton(withTitle:isGroupSelected ? "Save for this group" : "Save for this bot")
                    panel.addButton(withTitle:"Cancel")
                    panel.addButton(withTitle:"Share with every bot")
                    let choice = panel.runModal()
                    if choice == .alertSecondButtonReturn {reply = "Memory was not saved."}
                    else {
                        guard let store = memoryStore else {throw FridayError.message("Memory store unavailable.")}
                        let audience = choice == .alertThirdButtonReturn ? "shared" : originatingScope
                        try await Task.detached(priority: .userInitiated) {
                            try store.save(proposal, scope: audience, source: origin, original: nil)
                        }.value
                        WorkingMemoryCache.shared.clear()
                        loadMemories()
                        notifyMemoryUpdated(text:proposal)
                        reply = "Memory saved to " + audience + "."
                    }

                case .control:
                    statusMessage = "Operating Mac app…"
                    let controlEff = MultiModelRouter.effectiveProviderAndModel(for: .coding, botProvider: activeProvider, botModel: activeModel)
                    let visionEff = MultiModelRouter.effectiveProviderAndModel(for: .vision, botProvider: activeProvider, botModel: activeModel)
                    let worker=Task.detached(priority:.userInitiated) {
                        let request:[String:Any]=["operation":"control","question":text]
                        let initial=try ScreenInferenceRouter.infer(request,provider:controlEff.provider,model:controlEff.model)
                        try Task.checkCancellation()
                        return try MacAutomationDriver.performMacPlan(initial,locate:{ image,description in
                            let raw=try ScreenInferenceRouter.infer(["operation":"locate","image":image.path,"question":description],provider:visionEff.provider,model:visionEff.model)
                            return try JSONDecoder().decode([String:Double].self,from:Data(raw.utf8))
                        }) { labels,completed,app in
                            var refined=request;refined["initialPlan"]=initial;refined["visibleControls"]=labels;refined["alreadyCompleted"]=completed;refined["currentApp"]=app
                            let raw=try ScreenInferenceRouter.infer(refined,provider:controlEff.provider,model:controlEff.model)
                            return try JSONDecoder().decode(MacPlan.self,from:Data(raw.utf8))
                        }
                    }
                    controlTask=worker
                    defer {controlTask=nil}
                    reply=try await worker.value

                case .visual:
                    guard CGPreflightScreenCaptureAccess() else {
                        showScreenPermissionHelp = true
                        throw FridayError.message("Allow FRIDAY to capture the visible window in Screen Recording settings.")
                    }
                    let visionEff = MultiModelRouter.effectiveProviderAndModel(for: .vision, botProvider: activeProvider, botModel: activeModel)
                    reply = try await Task.detached(priority: .userInitiated) {
                        let url = try DesktopTools.imageOfActiveWindow()
                        defer { try? FileManager.default.removeItem(at: url) }
                        return try ScreenInferenceRouter.infer(["operation": "visual", "image": url.path, "question": text], provider: visionEff.provider, model: visionEff.model)
                    }.value
                    defaults.set(reply,forKey:cacheKey)
                case .active:
                    statusMessage = "Reading active window…"
                    let capture: String
                    do {
                        capture = try await Task.detached(priority: .userInitiated) {
                            try MacAutomationDriver.readActiveWindow()
                        }.value
                    } catch {
                        if !CGPreflightScreenCaptureAccess() { showScreenPermissionHelp = true }
                        throw error
                    }
                    defaults.set(String(capture.prefix(12000)), forKey: cacheKey)
                    if decision.mode == .verbatim {reply=capture} else {
                        let answerReq: [String: Any] = ["operation": "answer", "capture": String(capture.prefix(12000)), "question": text]
                        reply = try await Task.detached(priority: .userInitiated) {
                            try ScreenInferenceRouter.infer(answerReq, provider: activeProvider, model: activeModel)
                        }.value
                    }

                case .editor:
                    statusMessage = "Reading TextEdit document…"
                    let capture = try await Task.detached(priority: .userInitiated) {
                        try MacAutomationDriver.readEditor(text)
                    }.value
                    defaults.set(capture, forKey: cacheKey)
                    if decision.mode == .verbatim {
                        reply = capture
                    } else {
                        reply = try await Task.detached(priority: .userInitiated) {
                            try ScreenInferenceRouter.infer(["operation": "answer", "capture": capture, "question": text], provider: activeProvider, model: activeModel)
                        }.value
                    }

                case .messageDraft:
                    let raw = try await Task.detached(priority: .userInitiated) {
                        try ScreenInferenceRouter.infer(["operation": "messageBody", "question": text, "history": history],
                                                          provider: activeProvider, model: activeModel)
                    }.value
                    let draft = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
                    guard let body = draft["body"], !body.isEmpty,
                          let service = NSSharingService(named: .composeMessage) else {
                        throw FridayError.message("Could not prepare a Messages draft.")
                    }
                    if let recipient = draft["recipient"], !recipient.isEmpty { service.recipients = [recipient] }
                    service.perform(withItems: [body])
                    reply = "Opened a draft for review in Messages."

                case .mailReply, .calendarReply:
                    statusMessage = "Drafting Apple Mail reply…"
                    let helper = AppResources.path("mail_reply","js")
                    let msg = try await Task.detached(priority: .userInitiated) {
                        try MailCalendarService.mailOperation(["read"], helperScriptPath: helper)
                    }.value
                    guard let ident = msg["identity"], let body = msg["body"], let subj = msg["subject"] else {
                        throw FridayError.message("Could not read selected email.")
                    }
                    var draftReq: [String: Any] = ["operation": "mailBody", "question": text, "subject": subj, "body": body]
                    if decision.source == .calendarReply {
                        draftReq["calendar"] = try await MailCalendarService.upcomingCalendarConflicts()
                    }
                    let reqSnapshot = draftReq
                    let (draft, opened) = try await Task.detached(priority: .userInitiated) {
                        let d = try ScreenInferenceRouter.infer(reqSnapshot, provider: activeProvider, model: activeModel)
                        let o = try MailCalendarService.mailOperation(["draft", ident, d], helperScriptPath: helper)
                        return (d, o)
                    }.value
                    _ = draft
                    reply = "Reply draft opened in Apple Mail for review."
                    if let followUp = decision.followUp {
                        let title = followUp.title.isEmpty ? "Follow up: " + subj : followUp.title
                        let proposedDate = followUp.due.flatMap { ISO8601DateFormatter().date(from: $0) }
                        let panel = NSAlert()
                        panel.messageText = "Add follow-up to Apple Reminders?"
                        panel.informativeText = [title, opened["recipients"] ?? ""].joined(separator: "\n")
                        let date = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 270, height: 28))
                        date.datePickerElements = [.yearMonthDay, .hourMinute]
                        date.dateValue = proposedDate ?? Date().addingTimeInterval(86400)
                        panel.accessoryView = date
                        panel.addButton(withTitle: "Add reminder")
                        panel.addButton(withTitle: "Skip")
                        if panel.runModal() == .alertFirstButtonReturn {
                            do { try await DesktopTools.addReminder(title, due: date.dateValue); reply += " Follow-up added to Apple Reminders." }
                            catch { reply += " The follow-up could not be saved. " + error.localizedDescription }
                        }
                    }
                    pendingMailSubject = subj

                case .previous:
                    if let prev = previous {
                        let answerReq: [String: Any] = ["operation": "answer", "capture": prev, "question": text]
                        reply = try await Task.detached(priority: .userInitiated) {
                            try ScreenInferenceRouter.infer(answerReq, provider: activeProvider, model: activeModel)
                        }.value
                    } else {
                        reply = "No previous screen capture available for follow-up."
                    }

                case .generateImage:
                    self.statusMessage = "Generating image…"
                    let generated = try await OpenRouterClient.shared.generateImage(prompt: text)
                    reply = "[Image: \(generated.fileURL.lastPathComponent)]\nGenerated image using `\(generated.model)`."

                case .chat:
                    // 1. Working Memory, Cloud Multimodal RAG & Reranked Retrieval
                    var context = ""
                    let scope = self.memoryScope
                    if let store = memoryStore {
                        context = await Task.detached(priority: .userInitiated) {
                            var contextLines = [String]()
                            let lowerText = text.lowercased()
                            let isIdentityQuery = lowerText.contains("my name") || lowerText.contains("who am i") ||
                                                 lowerText.contains("who i am") || lowerText.contains("know me") ||
                                                 lowerText.contains("what's my name")

                            let tripleQuery = isIdentityQuery ? "name user" : text
                            if let triples = try? store.queryTriples(query: tripleQuery, scope: scope, limit: 3), !triples.isEmpty {
                                contextLines.append("Relational facts: " + triples.map { $0.summary }.joined(separator: ", "))
                            }
                            let searchQuery = isIdentityQuery ? "user name" : text
                            let cloudRes = await HybridMemoryCloudHelper.retrieveContext(
                                store: store,
                                query: searchQuery,
                                scope: scope,
                                limit: 3,
                                embeddingMode: embedMode,
                                useCloudRerank: useRerank
                            )
                            contextLines.append(contentsOf: cloudRes.memories.map { "[" + $0.scope + "] " + $0.body })
                            contextLines.append(contentsOf: cloudRes.ragSnippets)
                            return contextLines.joined(separator: "\n")
                        }.value
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
                        self.statusMessage = "\(single.name) is typing…"

                        let streamBuffer = StreamChunkBuffer()
                        activeStream = streamBuffer
                        turns.append(single.name + "\n")
                        self.currentTranscript = turns

                        let chatHistory = turns.dropLast().map { $0 }
                        let chatRole = MultiModelRouter.classifyChatRole(botPreset: botRole(for: single.id), inferred: decision.chatRole.flatMap(ModelRole.init(rawValue:)))
                        let effChat = MultiModelRouter.effectiveProviderAndModel(for: chatRole, botProvider: single.provider, botModel: single.model)
                        reply = try await AssistantService.shared.streamChat(
                            prompt: text,
                            history: chatHistory,
                            provider: effChat.provider,
                            model: effChat.model,
                            sessionID: sessionID,
                            contextMemory: context,
                            botName: single.name,
                            botInstructions: single.instructions,
                            onChunk: { chunk in
                                streamBuffer.append(chunk) { snapshot in
                                    Task { @MainActor in
                                        if let lastIdx = self.currentTranscript.indices.last, self.isBusy, self.activeStream === streamBuffer {
                                            self.currentTranscript[lastIdx] = single.name + "\n" + snapshot
                                        }
                                    }
                                }
                            }
                        )
                        activeStream = nil
                        let cleanReply = AssistantService.cleanBotReply(reply.isEmpty ? streamBuffer.snapshot() : reply, botName: single.name)
                        if turns.indices.contains(turns.count - 1) {
                            turns[turns.count - 1] = single.name + "\n" + cleanReply
                        }
                        defaults.set(turns, forKey: key)
                        self.currentTranscript = turns
                        self.statusMessage = "Ready"
                        self.isBusy = false
                        AssistantService.shared.speak(cleanReply, voice: voiceForBot(id: single.id))
                    } else {
                        self.statusMessage = "Orchestrating agent collaboration…"
                        let respondingNames = try await AssistantService.shared.resolveRespondingBots(
                            transcript: turns,
                            userMessage: text,
                            candidateBots: candidates.map { ($0.name, $0.instructions) },
                            provider: activeProvider,
                            model: activeModel
                        )

                        var speechQueue = [(text: String, voice: String)]()
                        for targetName in respondingNames {
                            guard let target = candidates.first(where: { $0.name.caseInsensitiveCompare(targetName) == .orderedSame }) else { continue }

                            self.statusMessage = "\(target.name) is typing…"

                            let streamBuffer = StreamChunkBuffer()
                            activeStream = streamBuffer
                            turns.append(target.name + "\n")
                            self.currentTranscript = turns

                            let contextTurns = turns.dropLast().suffix(16).joined(separator: "\n\n")
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

                            let rawMemberRole = MultiModelRouter.classifyChatRole(botPreset: botRole(for: target.id), inferred: decision.chatRole.flatMap(ModelRole.init(rawValue:)))
                            let effMember = MultiModelRouter.effectiveProviderAndModel(for: rawMemberRole, botProvider: target.provider, botModel: target.model)
                            let rawMemberReply = try await AssistantService.shared.executeRawChat(
                                prompt: groupPrompt,
                                provider: effMember.provider,
                                model: effMember.model,
                                onChunk: { chunk in
                                    streamBuffer.append(chunk) { snapshot in
                                        Task { @MainActor in
                                            if let lastIdx = self.currentTranscript.indices.last, self.isBusy, self.activeStream === streamBuffer {
                                                self.currentTranscript[lastIdx] = target.name + "\n" + snapshot
                                            }
                                        }
                                    }
                                }
                            )
                            activeStream = nil
                            let memberReply = AssistantService.cleanBotReply(
                                rawMemberReply.isEmpty ? streamBuffer.snapshot() : rawMemberReply,
                                botName: target.name,
                                otherBotNames: candidates.map(\.name)
                            )
                            if !memberReply.isEmpty {
                                if turns.indices.contains(turns.count - 1) {
                                    turns[turns.count - 1] = target.name + "\n" + memberReply
                                }
                                speechQueue.append((text: memberReply, voice: voiceForBot(id: target.id)))
                            } else {
                                if !turns.isEmpty { turns.removeLast() }
                            }
                            defaults.set(turns, forKey: key)
                            self.currentTranscript = turns
                        }

                        self.statusMessage = "Ready"
                        self.isBusy = false
                        if !speechQueue.isEmpty {
                            AssistantService.shared.speakSequence(speechQueue)
                        }
                    }

                    // 4. Autonomous Background Fact & Graph Triple Extraction
                    if let store = self.memoryStore {
                        let lastReply = turns.last ?? reply
                        BackgroundFactExtractor.shared.processTurn(
                            userPrompt: text,
                            assistantResponse: lastReply,
                            botName: isGroupSelected ? "Group" : botName,
                            scope: originatingScope,
                            source: origin,
                            store: store,
                            provider: self.provider,
                            model: self.model,
                            usePerplexityDecider: useDecider,
                            embeddingMode: embedMode
                        )
                    }
                    self.syncQuotaCount()
                    return
                }

                if !reply.isEmpty {
                    turns.append(botName + "\n" + reply)
                    defaults.set(turns, forKey: key)
                    self.currentTranscript = turns
                    self.statusMessage = "Ready"
                    self.isBusy = false
                    self.syncQuotaCount()
                    AssistantService.shared.speak(reply, voice: voiceForBot(id: activeBotId))
                }

            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }
}
