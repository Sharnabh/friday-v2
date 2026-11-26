import SwiftUI
import FridayCore
import WebKit

@MainActor
final class ResearchBrowser: ObservableObject {
    let web:WKWebView
    let owner:String
    init(owner:String) {
        self.owner=owner
        let config=WKWebViewConfiguration()
        let key="browser.profile."+owner
        let id=UserDefaults.standard.string(forKey:key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(id.uuidString,forKey:key)
        config.websiteDataStore=WKWebsiteDataStore(forIdentifier:id)
        web=WKWebView(frame:.zero,configuration:config)
    }
    func open(_ address:String) {
        guard let url=URL(string:address),["http","https"].contains(url.scheme?.lowercased() ?? "") else {return}
        web.load(URLRequest(url:url))
    }
}
struct BrowserSurface:NSViewRepresentable {
    let browser:ResearchBrowser
    func makeNSView(context:Context)->WKWebView {browser.web}
    func updateNSView(_ view:WKWebView,context:Context) {}
}
struct ToolsWorkspace:View {
    @EnvironmentObject var state:AppState
    @State private var catalog=[String:[String]]()
    @State private var recipient=""
    @State private var bodyText=""
    @State private var reminder=""
    @State private var address=""
    @State private var taskText=""
    @State private var handoff=""
    @State private var due=Date().addingTimeInterval(3600)
    @State private var browser:ResearchBrowser?
    @State private var research:Task<Void,Never>?
    @State private var feedback=""
    @State private var savedVoiceOverride = false
    @State private var voiceKeyAvailable = false
    @State private var imagePrompt = ""
    @State private var imageAspect = ""
    @State private var imageBackground = ""
    @State private var generatedImagePath = ""
    @State private var isGeneratingImage = false
    @State private var ragTitle = ""
    @State private var ragBody = ""
    @State private var isIndexingRAG = false
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
    @State private var researching=false
    private func startResearch(_ browser:ResearchBrowser) {
        research?.cancel()
        let owner=state.activeBotId
        let provider=state.provider, model=state.model, question=taskText
        research=Task {
            researching=true
            do {
                let initialURL=browser.web.url
                let page=try await browser.web.evaluateJavaScript("document.body.innerText.slice(0,12000)") as? String ?? ""
                let links=try await browser.web.evaluateJavaScript("""
                Array.from(document.querySelectorAll('a[href]')).filter(a=>a.origin===location.origin && /^https?:$/.test(a.protocol) && a.innerText.trim().length>3).slice(0,35).map(a=>({title:a.innerText.trim().slice(0,100),url:a.href}))
                """) as? [[String:String]] ?? []
                let candidates=links.filter { $0["url"] != initialURL?.absoluteString }
                var evidence=page
                var sources=[initialURL?.absoluteString ?? ""]
                if !candidates.isEmpty {
                    let index=try await Task.detached {
                        try ScreenInferenceRouter.infer(["operation":"selectEvidence","question":question,"links":candidates.map{$0["title"] ?? ""}],provider:provider,model:model)
                    }.value
                    try Task.checkCancellation()
                    if let n=Int(index),candidates.indices.contains(n),let link=candidates[n]["url"] {
                        let extra=try await browser.web.callAsyncJavaScript("""
                        const url=new URL(link); if(url.origin!==location.origin)return "";
                        const response=await fetch(url,{redirect:"error",credentials:"omit",signal:AbortSignal.timeout(8000)});
                        if(!response.ok||!response.headers.get("content-type")?.includes("text/html"))return "";
                        const doc=new DOMParser().parseFromString(await response.text(),"text/html");
                        doc.querySelectorAll("script,style,noscript").forEach(n=>n.remove());
                        return doc.body.textContent.slice(0,8000);
                        """,arguments:["link":link],in:nil,contentWorld:.defaultClient) as? String ?? ""
                        if !extra.isEmpty {evidence+="\n"+extra;sources.append(link)}
                    }
                }
                let capture=evidence, sourceList=sources.joined(separator:"\n")
                let result=try await Task.detached {
                    try ScreenInferenceRouter.infer(["operation":"answer","question":question,"capture":capture],provider:provider,model:model)
                }.value
                try Task.checkCancellation()
                guard owner==state.activeBotId else {return}
                handoff=result+"\n"+sourceList
                UserDefaults.standard.set(handoff,forKey:"research.result."+owner)
                UserDefaults.standard.set(question,forKey:"research.task."+owner)
            }catch {if !Task.isCancelled{feedback=error.localizedDescription}}
            if !Task.isCancelled {researching=false}
        }
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Text("Tools & workspaces").font(.title)
                SetupView()
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
                GroupBox("Voice & speech (OpenRouter HeyGen)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Speak responses automatically (always on in Hey Friday mode)", isOn: $state.isTTSEnabled)
                            .disabled(state.isWakeEnabled)
                        HStack {
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
                        HStack {
                            SecureField("OpenRouter API key override (optional if in ~/.hermes/.env)", text: $state.openRouterAPIKey)
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
                GroupBox("Multi-Model Orchestration & Opt-In Capabilities") {
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
                        Toggle("Use Perplexity Decider (/api/alpha/decisions) for routing & fact gate", isOn: $state.isDeciderRoutingEnabled)
                        Picker("Memory embeddings mode", selection: $state.memoryEmbeddingMode) {
                            ForEach(MemoryEmbeddingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Toggle("Use Cloud Search Reranking (/api/v1/rerank)", isOn: $state.isCloudRerankEnabled)
                        Divider()
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
                GroupBox("Image Generation (Recraft V4.1 Flash V2)") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Describe an image to generate…", text: $imagePrompt)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Picker("Aspect", selection: $imageAspect) {
                                Text("Default").tag("")
                                Text("1:1").tag("1:1")
                                Text("16:9").tag("16:9")
                                Text("9:16").tag("9:16")
                            }
                            .frame(maxWidth: 160)
                            Picker("Background", selection: $imageBackground) {
                                Text("Default").tag("")
                                Text("Transparent").tag("transparent")
                            }
                            .frame(maxWidth: 180)
                            Button(isGeneratingImage ? "Generating…" : "Generate Image") {
                                let promptText = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !promptText.isEmpty else { return }
                                isGeneratingImage = true
                                Task {
                                    defer { isGeneratingImage = false }
                                    do {
                                        let res = try await state.generateImage(prompt: promptText, aspectRatio: imageAspect, background: imageBackground)
                                        generatedImagePath = res.fileURL.path
                                        feedback = "Generated image via \(res.model): \(res.fileURL.lastPathComponent)"
                                    } catch {
                                        feedback = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(isGeneratingImage || imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !generatedImagePath.isEmpty, let nsImg = NSImage(contentsOfFile: generatedImagePath) {
                            HStack(spacing: 12) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 160)
                                    .cornerRadius(8)
                                VStack(alignment: .leading, spacing: 6) {
                                    Button("Open in Preview") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: generatedImagePath))
                                    }
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: generatedImagePath)])
                                    }
                                }
                            }
                        }
                    }
                }
                GroupBox("Knowledge Base / Multimodal RAG") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Document title", text: $ragTitle)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $ragBody)
                            .frame(minHeight: 70, maxHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        HStack {
                            Button("Import Text / Markdown File…") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url,
                                   let content = try? String(contentsOf: url, encoding: .utf8) {
                                    ragTitle = url.lastPathComponent
                                    ragBody = content
                                }
                            }
                            Button(isIndexingRAG ? "Indexing…" : "Index Document") {
                                let title = ragTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                let body = ragBody.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !title.isEmpty, !body.isEmpty else { return }
                                isIndexingRAG = true
                                Task {
                                    defer { isIndexingRAG = false }
                                    do {
                                        try await state.indexRAGDocument(title: title, body: body, mediaType: "text", sourcePath: nil)
                                        feedback = "Indexed '\(title)' (\(state.memoryEmbeddingMode.displayName))."
                                        ragTitle = ""
                                        ragBody = ""
                                    } catch {
                                        feedback = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(isIndexingRAG || ragTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ragBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                GroupBox("Messages draft"){
                    VStack {TextField("Recipient",text:$recipient);TextField("Message",text:$bodyText)
                        Button("Review in Messages"){
                            guard let service=NSSharingService(named:.composeMessage) else {feedback="Messages unavailable";return}
                            service.recipients=[recipient];service.perform(withItems:[bodyText])
                        }.disabled(recipient.isEmpty || bodyText.isEmpty)
                    }
                }
                GroupBox("Apple Reminders"){
                    if let subject=state.pendingMailSubject {Button("Use Mail draft subject"){reminder="Follow up: "+subject}}
                    HStack {TextField("Follow-up",text:$reminder);DatePicker("Due",selection:$due)
                        Button("Add reminder"){Task {do {try await DesktopTools.addReminder(reminder,due:due);feedback="Added to Apple Reminders";reminder=""}catch {feedback=error.localizedDescription}}}.disabled(reminder.isEmpty)
                    }
                }
                if let browser, browser.owner == state.activeBotId {
                    GroupBox("Browser · "+state.currentBotName) {
                        VStack {
                            HStack {TextField("https://",text:$address).onSubmit{browser.open(address)};Button("Open"){browser.open(address)};Button("Stop"){browser.web.stopLoading();research?.cancel();researching=false}}
                            BrowserSurface(browser:browser).id(browser.owner).frame(minHeight:300)
                            TextField("Research question about this page",text:$taskText)
                            Button(researching ? "Researching…" : "Research this page"){startResearch(browser)}.disabled(taskText.isEmpty || researching)
                            if !handoff.isEmpty {
                                Text(handoff).textSelection(.enabled)
                                Menu("Hand off to chat"){
                                    ForEach(state.bots){bot in Button(bot.name){state.selectBot(bot.id);state.inputMessage=handoff;state.selectedTab=0}}
                                    Button(state.fridayName){state.selectBot("");state.inputMessage=handoff;state.selectedTab=0}
                                    ForEach(state.groups.filter { $0.members.contains(browser.owner) }) { group in
                                        Menu(group.name) {
                                            ForEach(group.members.filter { $0 != browser.owner }, id: \.self) { id in
                                                let name = state.bots.first { $0.id == id }?.name ?? state.fridayName
                                                Button(name) {
                                                    let message = "@" + name + " " + handoff
                                                    state.selectBot(group.id)
                                                    state.inputMessage = message
                                                    state.selectedTab = 0
                                                }
                                            }
                                        }
                                    }
                                }
                                Button("Save handoff to guest") {
                                    if let folder = state.guestForBot().exchange {
                                        do {
                                            let file = folder.appendingPathComponent("Research-" + UUID().uuidString + ".txt")
                                            try handoff.write(to: file, atomically: true, encoding: .utf8)
                                            feedback = "Saved " + file.lastPathComponent + " to the guest handoff folder."
                                        } catch { feedback = error.localizedDescription }
                                    }
                                }.disabled(state.guestForBot().exchange == nil)
                                Button("Export handoff"){let panel=NSSavePanel();panel.nameFieldStringValue="Research.txt";if panel.runModal() == .OK,let url=panel.url {do {try handoff.write(to:url,atomically:true,encoding:.utf8)}catch {feedback=error.localizedDescription}}}
                            }
                        }
                    }
                }
                GuestDesktop(owner:state.activeBotId,controller:state.guestForBot())
                LocalTools()
                Text(feedback).textSelection(.enabled)
            }.padding()
        }.onAppear { refreshVoiceKey(); loadRoleSelections(); state.syncQuotaCount() }.task {catalog=await Task.detached {DesktopTools.models()}.value}
        .task(id:state.activeBotId){research?.cancel();researching=false;handoff=UserDefaults.standard.string(forKey:"research.result."+state.activeBotId) ?? "";taskText=UserDefaults.standard.string(forKey:"research.task."+state.activeBotId) ?? "";browser=ResearchBrowser(owner:state.activeBotId)}
        .onDisappear{research?.cancel()}
    }
}
