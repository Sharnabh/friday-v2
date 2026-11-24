import SwiftUI
import FridayCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var inputMessage: String = ""
    @Published public var statusMessage: String = "Ready"
    @Published public var isBusy: Bool = false
    @Published public var currentTranscript: [String] = []
    
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
    }

    public var activeBotScope: String {
        activeBotId.isEmpty ? "" : "bot." + activeBotId + "."
    }

    public var memoryScope: String {
        let isGroup = activeBotId == "group" || groups.contains(where: { $0.id == activeBotId })
        return (isGroup ? "group:" : "private:") + activeBotId
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
            try store.save(body, scope: scope, source: "Entered via SwiftUI", original: nil)
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
        statusMessage = "Streaming response…"

        let key = activeBotScope + "transcript." + sessionID
        var turns = defaults.stringArray(forKey: key) ?? []
        turns.append("You\n" + text)
        defaults.set(turns, forKey: key)
        self.currentTranscript = turns

        // Retrieve Hybrid context memories
        var context = ""
        if let store = memoryStore {
            if let results = try? store.search(text, scope: memoryScope, limit: 3) {
                context = results.map { "[" + $0.scope + "] " + $0.body }.joined(separator: "\n")
            }
        }

        let botName = bots.first(where: { $0.id == activeBotId })?.name ?? "FRIDAY"
        let botInstr = bots.first(where: { $0.id == activeBotId })?.instructions ?? ""

        Task {
            do {
                let result = try await AssistantService.shared.streamChat(
                    prompt: text,
                    provider: provider,
                    model: model,
                    sessionID: sessionID,
                    contextMemory: context,
                    botName: botName,
                    botInstructions: botInstr
                ) { _ in
                    Task { @MainActor in
                        self.statusMessage = "Receiving stream…"
                    }
                }

                turns.append(botName + "\n" + result)
                defaults.set(turns, forKey: key)
                self.currentTranscript = turns
                self.statusMessage = "Ready"
                self.isBusy = false

                AssistantService.shared.speak(result)
            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }
}
