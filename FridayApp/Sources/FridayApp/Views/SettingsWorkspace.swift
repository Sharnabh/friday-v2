import SwiftUI
import FridayCore

struct SettingsWorkspace: View {
    @EnvironmentObject var state: AppState
    @AppStorage("workspace.settings.section") private var section = "Mac setup"
    @State private var feedback = ""
    @State private var catalog = [String: [String]]()
    @State private var savedVoiceOverride = false
    @State private var voiceKeyAvailable = false
    @State private var roleSelections: [ModelRole: String] = [:]

    private func loadRoleSelections() {
        var next = [ModelRole: String]()
        for role in ModelRole.allCases {
            next[role] = OpenRouterModelRegistry.shared.preferredModel(for: role) ?? ""
        }
        roleSelections = next
    }

    private func refreshVoiceKey() {
        savedVoiceOverride = SpeechCredential.read() != nil
        voiceKeyAvailable = savedVoiceOverride || AssistantService.hasOpenRouterAPIKey()
    }

    var body: some View {
        WorkspacePage(title: "Settings", selection: $section, sections: ["Mac setup", "Models", "Voice", "Backup"]) {
            switch section {
            case "Models": modelSettings; routingSettings
            case "Voice": voiceSettings
            case "Backup": LocalTools(isBackup: true)
            default: SetupView()
            }
            if !feedback.isEmpty { Text(feedback).font(.callout).textSelection(.enabled) }
        }
        .onAppear { refreshVoiceKey(); loadRoleSelections(); state.syncQuotaCount() }
        .onChange(of: section) { feedback = "" }
        .task { catalog = await Task.detached { DesktopTools.models() }.value }
    }

    @ViewBuilder private var modelSettings: some View {
        GroupBox("Model connection") {
            VStack(alignment:.leading) {
                HStack {
                    Picker("Provider",selection:$state.provider){
                        Text("Hermes default").tag("")
                        ForEach(Array(Set(catalog.keys).union([state.provider]).subtracting([""])).sorted(),id:\.self){Text($0).tag($0)}
                    }
                    Picker("Model",selection:$state.model){
                        Text("Provider default").tag("")
                        ForEach(Array(Set(catalog[state.provider] ?? []).union([state.model]).subtracting([""])).sorted(),id:\.self){Text($0).tag($0)}
                    }
                }
                DisclosureGroup("Custom model identifiers") {
                    TextField("Provider ID", text: $state.provider)
                    TextField("Model ID", text: $state.model)
                }
                Button("Test connection"){
                    let provider=state.provider,model=state.model
                    feedback="Testing connection…"
                    Task { do {
                        _ = try await Task.detached {try ScreenInferenceRouter.infer(["operation":"answer","question":"Respond OK","capture":"Service test"],provider:provider,model:model)}.value
                        feedback="Model responded."
                    } catch {feedback=error.localizedDescription} }
                }
            }
        }
    }

    @ViewBuilder private var routingSettings: some View {
        GroupBox("Model routing") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        Text("Free requests recorded by FRIDAY today: \(OpenRouterModelRegistry.shared.todayFreeRequestCount())")
                            .font(.caption.monospacedDigit())
                            .help("Counts successful direct API requests. Hermes and external activity are excluded.")
                    }
                    Spacer()
                    Button("Sync OpenRouter Catalog") {
                        Task {
                            do { try await state.refreshOpenRouterCatalog(force: true) }
                            catch { feedback = error.localizedDescription }
                        }
                    }
                }
                if !state.openRouterRefreshStatus.isEmpty {
                    Text(state.openRouterRefreshStatus).font(.caption).foregroundStyle(.secondary)
                }
                if !state.isGroupSelected {
                    Picker("Active bot task role", selection: $state.currentBotRole) {
                        ForEach(BotRolePreset.allCases) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                }
                Divider()
                Toggle("Use Perplexity Decider for routing and memory checks", isOn: $state.isDeciderRoutingEnabled)
                Picker("Memory embeddings mode", selection: $state.memoryEmbeddingMode) {
                    ForEach(MemoryEmbeddingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Rerank search results in the cloud", isOn: $state.isCloudRerankEnabled)
                Divider()
                DisclosureGroup("Models by task") {
                    ForEach([ModelRole.orchestrator, .fastChat, .coding, .vision, .decisionsFast, .embeddings, .rerank, .imageGen], id: \.self) { role in
                        let discovered = OpenRouterModelRegistry.shared.freeModels(for: role).map(\.id)
                        let defaultId = OpenRouterCatalogDefaults.roleChains[role]?.first ?? ""
                        let options = Array(Set(discovered + (OpenRouterCatalogDefaults.roleChains[role] ?? []) + [roleSelections[role] ?? ""])).filter { !$0.isEmpty }.sorted()
                        Picker(role.displayName, selection: Binding(
                            get: { roleSelections[role] ?? "" },
                            set: { newVal in
                                roleSelections[role] = newVal
                                OpenRouterModelRegistry.shared.setPreferredModel(newVal, for: role)
                            }
                        )) {
                            Text("Auto (\(defaultId))").tag("")
                            ForEach(options, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var voiceSettings: some View {
        GroupBox("Speech output") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Speak responses automatically (always on in Hey Friday mode)", isOn: $state.isTTSEnabled)
                    .disabled(state.isWakeEnabled)
                VStack(alignment: .leading) {
                    Picker("Active bot voice", selection: $state.currentBotVoice) {
                        ForEach(HeyGenTTSCatalog.voices) { v in
                            Text(v.label).tag(v.id)
                        }
                    }
                    .disabled(state.isGroupSelected)
                    Picker("TTS model", selection: $state.openRouterTTSModel) {
                        ForEach(HeyGenTTSCatalog.availableModels, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                }
                SecureField("OpenRouter API key", text: $state.openRouterAPIKey)
                HStack {
                    Button("Save key") { state.saveSpeechCredential(); refreshVoiceKey() }
                        .disabled(state.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if savedVoiceOverride {
                        Button("Remove key") { state.saveSpeechCredential(remove: true); refreshVoiceKey() }
                    }
                    Button("Test Voice") {
                        state.previewVoice(state.currentBotVoice, botName: state.currentBotName)
                    }
                }
                if !state.speechCredentialStatus.isEmpty { Text(state.speechCredentialStatus).font(.caption) }
                Text(voiceKeyAvailable
                     ? "OpenRouter TTS key configured. HeyGen voices use OpenRouter. System Default uses macOS Speech."
                     : "Add OPENROUTER_API_KEY above or in ~/.hermes/.env to use HeyGen voices (otherwise falls back to macOS Speech).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
