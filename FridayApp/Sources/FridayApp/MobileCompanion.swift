import Foundation
import FridayCore

@MainActor
final class MobileCompanion: ObservableObject {
    @Published private(set) var token = ""
    @Published private(set) var status = "Disconnected"
    private(set) var listeningPort = 0
    private var child: Process?

    func start(_ state: AppState, port: Int = 8765) {
        guard child == nil else { return }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: AppResources.python)
        process.arguments = [AppResources.path("mobile_bridge", "py"), String(port)]
        process.standardInput = input
        process.standardOutput = output
        do { try process.run() } catch { status = error.localizedDescription; return }
        child = process
        let secret = UUID().uuidString + UUID().uuidString
        status = "Starting…"
        Task {
            defer {
                try? input.fileHandleForWriting.close()
                if child === process {
                    stop()
                    status = "Disconnected. Check whether port 8765 is in use."
                }
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard child === process else { break }
                    guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { break }
                    if token.isEmpty, request["action"] as? String == "ready" {
                        listeningPort = request["port"] as? Int ?? port
                        token = secret
                        status = "Ready to pair"
                        continue
                    }
                    let result = await handle(request, state: state)
                    var data = try JSONSerialization.data(withJSONObject: result)
                    data.append(10)
                    try input.fileHandleForWriting.write(contentsOf: data)
                }
            } catch { return }
        }
    }

    func stop() {
        if let child, child.isRunning { child.terminate() }
        child = nil
        token = ""
        status = "Disconnected"
    }

    func handle(_ request: [String: Any], state: AppState) async -> [String: Any] {
        let action = request["action"] as? String
        if action == "catalog" {
            var models = await Task.detached { DesktopTools.models() }.value
            models["openrouter"] = Set((models["openrouter"] ?? []) + state.openRouterCatalogModels.map(\.id)).sorted()
            var choices = [[String: Any]]()
            func add(_ key: String, _ label: String, _ current: String, _ options: [(String, String)]) {
                choices.append(["key": key, "label": label, "current": current,
                                "options": options.map { ["id": $0.0, "name": $0.1] }])
            }
            add("embedding", "Memory embeddings", state.memoryEmbeddingMode.rawValue,
                MemoryEmbeddingMode.allCases.map { ($0.rawValue, $0.displayName) })
            if !state.isGroupSelected {
                add("role", "Assistant role", state.currentBotRole.rawValue, BotRolePreset.allCases.map { ($0.rawValue, $0.displayName) })
                add("voice", "Assistant voice", state.currentBotVoice, HeyGenTTSCatalog.voices.map { ($0.id, $0.label) })
            }
            add("ttsModel", "Speech model", state.openRouterTTSModel, HeyGenTTSCatalog.availableModels)
            let registry = OpenRouterModelRegistry.shared
            for role in ModelRole.allCases {
                let current = registry.preferredModel(for: role) ?? ""
                let ids = Set(registry.freeModels(for: role).map(\.id) + (OpenRouterCatalogDefaults.roleChains[role] ?? []) + [current])
                add("task." + role.rawValue, role.displayName, current, [("", "Auto")] + ids.filter { !$0.isEmpty }.sorted().map { ($0, $0) })
            }
            return ["catalog": models, "choices": choices, "bot": state.activeBotId, "session": state.currentSessionId,
                    "speak": state.isTTSEnabled, "wake": state.isWakeEnabled]
        }
        if action != "state" {
            guard !state.isBusy, state.activeBotId == request["bot"] as? String,
                  state.currentSessionId == request["session"] as? String else {
                return ["error": "The Mac workspace changed or is busy. Refresh and try again."]
            }
        }
        switch action {
        case "state": break
        case "send":
            guard let message = request["text"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.inputMessage.isEmpty else { return ["error": "Enter a message and finish any open draft on the Mac."] }
            state.inputMessage = message
            state.sendMessage()
        case "new": state.newChat()
        case "selectSession":
            state.loadSessions()
            guard let id = request["id"] as? String, state.savedSessions.contains(where: { $0.id == id }) else { return ["error": "Unknown chat"] }
            state.selectSession(id)
        case "selectBot":
            guard let id = request["id"] as? String, id.isEmpty || state.bots.contains(where: { $0.id == id }) || state.groups.contains(where: { $0.id == id }) else { return ["error": "Unknown assistant"] }
            state.selectBot(id)
        case "settings":
            guard let provider = request["provider"] as? String, let model = request["model"] as? String,
                  let decider = request["decider"] as? Bool, let rerank = request["rerank"] as? Bool else { return ["error": "Incomplete settings"] }
            state.provider = provider
            state.model = model
            state.isDeciderRoutingEnabled = decider
            state.isCloudRerankEnabled = rerank
            if let speak = request["speak"] as? Bool, !state.isWakeEnabled { state.isTTSEnabled = speak }
            let changes = request["choices"] as? [String: String] ?? [:]
            if let raw = changes["embedding"], let mode = MemoryEmbeddingMode(rawValue: raw) { state.memoryEmbeddingMode = mode }
            if !state.isGroupSelected {
                if let raw = changes["role"], let role = BotRolePreset(rawValue: raw) { state.currentBotRole = role }
                if let voice = changes["voice"], HeyGenTTSCatalog.voices.contains(where: { $0.id == voice }) { state.currentBotVoice = voice }
            }
            if let model = changes["ttsModel"], HeyGenTTSCatalog.availableModels.contains(where: { $0.id == model }) { state.openRouterTTSModel = model }
            for role in ModelRole.allCases {
                if let id = changes["task." + role.rawValue] { OpenRouterModelRegistry.shared.setPreferredModel(id, for: role) }
            }
        default: return ["error": "Unknown action"]
        }
        state.loadSessions()
        return ["bot": state.activeBotId, "name": state.currentBotName, "session": state.currentSessionId,
                "assistants": [["id": "", "name": state.fridayName]] + state.bots.map { ["id": $0.id, "name": $0.name] } + state.groups.map { ["id": $0.id, "name": $0.name] },
                "sessions": state.savedSessions.map { ["id": $0.id, "name": $0.title] },
                "turns": state.currentTranscript, "busy": state.isBusy, "status": state.statusMessage,
                "provider": state.provider, "model": state.model, "decider": state.isDeciderRoutingEnabled,
                "rerank": state.isCloudRerankEnabled]
    }
}
