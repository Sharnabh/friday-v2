import AppKit
import AVFoundation

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func run(_ path: String, _ args: [String], errors: FileHandle = .nullDevice) throws -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath:path)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = errors
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure.message("Could not complete " + URL(fileURLWithPath:path).lastPathComponent + ". Check its installation and permissions.") }
    return String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
}
func driver(_ action:String,_ arguments:[String:Any]) throws -> [String:Any] {
    let json = try JSONSerialization.data(withJSONObject:arguments)
    let result = try run("/Applications/CuaDriver.app/Contents/MacOS/cua-driver",["call",action,String(decoding:json,as:UTF8.self)])
    return (try JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any] ?? [:]
}
func readEditor(_ query:String) throws -> String {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.TextEdit").first else { throw Failure.message("Open a document in TextEdit first.") }
    _ = try run("/usr/bin/open", ["-g", "-a", "/Applications/CuaDriver.app"])
    let pid = Int(app.processIdentifier)
    var listing: [String:Any]?
    for _ in 0..<10 {
        listing = try? driver("list_windows", ["pid":pid])
        if listing != nil { break }
        Thread.sleep(forTimeInterval:0.2)
    }
    let windows = listing?["windows"] as? [[String:Any]] ?? []
    guard let window = windows.first(where:{($0["layer"] as? Int)==0}), let id = window["window_id"] else { throw Failure.message("No TextEdit document window was found.") }
    let state = try driver("get_window_state",["pid":pid,"window_id":id,"include_screenshot":false,"tree_format":"elements"])
    let elements = state["elements"] as? [[String:Any]] ?? []
    guard let area = elements.first(where:{$0["role"] as? String == "AXTextArea"}), let body = (area["value"] as? String) ?? (area["label"] as? String), !body.isEmpty else { throw Failure.message("Could not read the TextEdit text area. Check CuaDriver Accessibility permission.") }
    if query.localizedCaseInsensitiveContains("code"), let range = body.range(of:"verification code:",options:.caseInsensitive) {
        return String(body[range.upperBound...].prefix(while:{ !$0.isNewline })).trimmingCharacters(in:.whitespaces)
    }
    return body
}
class Friday: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window:NSWindow!
    let input = NSTextField(), status = NSTextField(labelWithString:"Ready"), answer = NSTextView()
    let record = NSButton(), submit = NSButton()
    let newChat = NSButton()
    let chats = NSPopUpButton()
    let bots = NSPopUpButton()
    let addBot = NSButton()
    var activeBot = testDefaults.string(forKey:"activeBot") ?? ""
    var scope: String { activeBot.isEmpty ? "" : "bot." + activeBot + "." }
    var profiles: [String:[String:String]] {
        testDefaults.dictionary(forKey:"fridayBots") as? [String:[String:String]] ?? [:]
    }
    func refreshBots() {
        bots.removeAllItems()
        for id in [""] + profiles.keys.sorted() {
            let item = NSMenuItem(title:profiles[id]?["name"] ?? "FRIDAY", action:nil, keyEquivalent:"")
            item.representedObject = id
            bots.menu?.addItem(item)
            if id == activeBot { bots.select(item) }
        }
    }
    func switchBot(_ id:String) {
        saveDraft()
        testDefaults.set(provider.stringValue, forKey:scope + "chatProvider")
        testDefaults.set(model.stringValue, forKey:scope + "chatModel")
        activeBot = id
        testDefaults.set(id, forKey:"activeBot")
        provider.stringValue = testDefaults.string(forKey:scope + "chatProvider") ?? ""
        model.stringValue = testDefaults.string(forKey:scope + "chatModel") ?? ""
        input.stringValue = testDefaults.string(forKey:scope + "draft." + sessionID) ?? ""
        speech.stopSpeaking()
        refreshBots()
        showHistory()
        status.stringValue = "Ready"
    }
    @objc func pickBot() {
        if let id = bots.selectedItem?.representedObject as? String { switchBot(id) }
    }
    @objc func createBot() {
        let alert = NSAlert()
        alert.messageText = "Create a bot"
        let fields = NSView(frame:NSRect(x:0,y:0,width:350,height:74))
        let name = NSTextField(frame:NSRect(x:0,y:44,width:350,height:26))
        let instructions = NSTextField(frame:NSRect(x:0,y:6,width:350,height:26))
        name.placeholderString = "Bot name"
        instructions.placeholderString = "Instructions for this bot"
        fields.addSubview(name)
        fields.addSubview(instructions)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = name
        alert.addButton(withTitle:"Create")
        alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { status.stringValue = "A bot name is required."; return }
        let id = UUID().uuidString
        var updated = profiles
        updated[id] = ["name":title,"instructions":instructions.stringValue]
        testDefaults.set(updated, forKey:"fridayBots")
        switchBot(id)
    }
    var sessionID: String {
        if let id = testDefaults.string(forKey:scope + "fridaySession") { return id }
        let id = UUID().uuidString
        testDefaults.set(id, forKey:scope + "fridaySession")
        return id
    }
    func showHistory() {
        let turns = testDefaults.stringArray(forKey:scope + "transcript." + sessionID) ?? []
        let defaults = testDefaults
        let prefix = scope + "transcript."
        let draftPrefix = scope + "draft."
        let keys = defaults.dictionaryRepresentation().keys
        let transcripts = keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let drafts = keys.filter { $0.hasPrefix(draftPrefix) && !(defaults.string(forKey:$0) ?? "").isEmpty }.map { String($0.dropFirst(draftPrefix.count)) }
        let saved = Set(transcripts + drafts).sorted()
        chats.removeAllItems()
        for id in [sessionID] + saved.filter({ $0 != sessionID }) {
            let first = defaults.stringArray(forKey:prefix + id)?.first ?? ""
            let question = first.components(separatedBy:"\n\n")[0].dropFirst(4)
            let draft = defaults.string(forKey:scope + "draft." + id) ?? ""
            let title = question.isEmpty ? (draft.isEmpty ? "New conversation" : "Draft · " + String(draft.prefix(48))) : String(question.prefix(60)).replacingOccurrences(of:"\n", with:" ")
            let item = NSMenuItem(title:title, action:nil, keyEquivalent:"")
            item.representedObject = id
            chats.menu?.addItem(item)
        }
        chats.selectItem(at:0)
        answer.string = turns.joined(separator:"\n\n")
        answer.scrollToEndOfDocument(nil)
    }
    @objc func selectChat() {
        guard recorder == nil, let id = chats.selectedItem?.representedObject as? String else { return }
        saveDraft()
        testDefaults.set(id, forKey:scope + "fridaySession")
        input.stringValue = testDefaults.string(forKey:scope + "draft." + id) ?? ""
        speech.stopSpeaking()
        showHistory()
        status.stringValue = "Ready"
    }
    func saveDraft() {
        testDefaults.set(input.stringValue, forKey:scope + "draft." + sessionID)
    }
    @objc func beginChat() {
        saveDraft()
        speech.stopSpeaking()
        testDefaults.set(UUID().uuidString, forKey:scope + "fridaySession")
        input.stringValue = ""
        showHistory()
        status.stringValue = "Ready"
    }
    let provider = NSTextField(), model = NSTextField()
    var recorder:AVAudioRecorder?
    let speech = NSSpeechSynthesizer()
    func applicationDidFinishLaunching(_ n:Notification) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:510),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "FRIDAY"; window.center(); window.delegate = self
        let root = window.contentView!
        func add(_ view:NSView,_ x:Int,_ y:Int,_ w:Int,_ h:Int) { view.frame = NSRect(x:x,y:y,width:w,height:h); root.addSubview(view) }
        let title = NSTextField(labelWithString:"Ask FRIDAY"); title.font = .systemFont(ofSize:25,weight:.semibold); add(title,24,412,450,36)
        add(NSTextField(labelWithString:"Chat provider"),24,383,160,20)
        add(NSTextField(labelWithString:"Model"),215,383,340,20)
        provider.placeholderString = "Hermes default"
        model.placeholderString = "Provider default"
        provider.stringValue = testDefaults.string(forKey:scope + "chatProvider") ?? ""
        model.stringValue = testDefaults.string(forKey:scope + "chatModel") ?? ""
        add(provider,24,352,178,28)
        add(model,215,352,361,28)
        input.placeholderString = "Read the verification code in TextEdit"; input.target=self; input.action=#selector(send); add(input,24,278,552,34)
        record.title="Record headset"; record.target=self; record.action=#selector(toggle); add(record,24,225,145,36)
        submit.title="Send"; submit.target=self; submit.action=#selector(send); add(submit,172,225,82,36)
        add(status,24,190,552,25)
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; answer.isEditable=false; answer.font = .systemFont(ofSize:17); answer.autoresizingMask = [.width]; scroll.documentView=answer; add(scroll,24,20,552,162)
        chats.target = self
        chats.action = #selector(selectChat)
        chats.setAccessibilityLabel("Saved chats")
        add(chats,205,414,250,34)
        input.stringValue = testDefaults.string(forKey:scope + "draft." + sessionID) ?? ""
        newChat.title = "New chat"
        newChat.target = self
        newChat.action = #selector(beginChat)
        add(newChat,466,414,110,34)
        bots.target = self
        bots.action = #selector(pickBot)
        bots.setAccessibilityLabel("Active bot")
        add(NSTextField(labelWithString:"Bot"),24,469,42,24)
        add(bots,65,465,380,30)
        addBot.title = "Create bot"
        addBot.target = self
        addBot.action = #selector(createBot)
        add(addBot,466,462,110,34)
        refreshBots()
        showHistory()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func busy(_ value:Bool) { bots.isEnabled = !value; addBot.isEnabled = !value; chats.isEnabled = !value; newChat.isEnabled = !value; record.isEnabled = !value; submit.isEnabled = !value; input.isEnabled = !value }
    func job(_ label:String,_ work:@escaping () throws ->String,_ done:@escaping(String)->Void) {
        busy(true); status.stringValue=label
        DispatchQueue.global().async { let result=Result { try work() }; DispatchQueue.main.async { self.busy(false); switch result { case .success(let s): done(s); case .failure(let e):self.status.stringValue="Needs attention"; self.answer.string=e.localizedDescription } } }
    }
    @objc func send() {
        guard recorder == nil, submit.isEnabled else {return}
        let q=input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); guard !q.isEmpty else {return}
        let editor=q.lowercased().replacingOccurrences(of:" ",with:"").contains("textedit")
        let providerID = provider.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let modelID = model.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        var route = ["chat", "--quiet"]
        if !providerID.isEmpty { route += ["--provider", providerID] }
        if !modelID.isEmpty { route += ["--model", modelID] }
        testDefaults.set(providerID, forKey:scope + "chatProvider")
        testDefaults.set(modelID, forKey:scope + "chatModel")
        let resumeKey = "hermesSession." + sessionID
        if let id = testDefaults.string(forKey:resumeKey) { route += ["--resume", id] }
        let profile = profiles[activeBot]
        let speaker = profile?["name"] ?? "FRIDAY"
        let prompt = profile.map { "Your name is " + speaker + ". " + ($0["instructions"] ?? "") + "\n\nUser request:\n" + q } ?? q
        let arguments = route + ["-q", prompt]
        job(editor ? "Reading TextEdit…" : "Waiting for the model…", {
            if editor { return try readEditor(q) }
            let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath:log.path, contents:nil, attributes:[.posixPermissions:0o600]) else { throw Failure.message("Could not create session log.") }
            defer { try? FileManager.default.removeItem(at:log) }
            let handle = try FileHandle(forWritingTo:log)
            defer { try? handle.close() }
            let reply = try run(NSHomeDirectory()+"/.local/bin/hermes",arguments,errors:handle)
            let lines = try String(contentsOf:log, encoding:.utf8).components(separatedBy:.newlines)
            if let marker = lines.last(where:{ $0.hasPrefix("session_id: ") }) {
                testDefaults.set(String(marker.dropFirst(12)), forKey:resumeKey)
            }
            return reply
        }) { s in
            let key = self.scope + "transcript." + self.sessionID
            var turns = testDefaults.stringArray(forKey:key) ?? []
            turns.append("You\n" + q + "\n\n" + speaker + "\n" + s)
            testDefaults.set(turns, forKey:key)
            self.showHistory()
            self.input.stringValue = ""
            self.saveDraft()
             self.status.stringValue="Ready"; self.speech.stopSpeaking(); self.speech.startSpeaking(String(s.prefix(1500))) }
    }
    @objc func toggle() {
        if let r=recorder {
            r.stop(); recorder=nil; record.title="Record headset"
            let url=r.url, dir=NSHomeDirectory()+"/.hermes/tools/friday-whisper/"
            job("Transcribing locally…", { defer {try? FileManager.default.removeItem(at:url)}
                return try run(dir+"whisper-cli",["-m",dir+"ggml-small.en.bin","-f",url.path,"-l","en","-ng","-nt","-np"])
            }) { self.input.stringValue=$0; self.status.stringValue="Review the transcript, then press Send." }; return
        }
        busy(true); speech.stopSpeaking()
        AVCaptureDevice.requestAccess(for:.audio) { ok in DispatchQueue.main.async {
            self.busy(false); guard ok else {self.status.stringValue="Allow Friday in System Settings → Privacy & Security → Microphone.";return}
            do {
                let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
                let r=try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16])
                guard r.record() else {throw Failure.message("Microphone recording could not start.")}
                self.newChat.isEnabled=false; self.chats.isEnabled=false; self.bots.isEnabled=false; self.addBot.isEnabled=false; self.recorder=r;self.submit.isEnabled=false;self.record.title="Stop recording";self.status.stringValue="Listening on the macOS default microphone…"
            } catch { self.status.stringValue=error.localizedDescription }
        }}
    }
}

let testDefaults = UserDefaults(suiteName:UUID().uuidString)!
let _ = NSApplication.shared
let f = Friday()
let original = f.sessionID
testDefaults.set(["You\nHello\n\nFRIDAY\nHi"],forKey:"transcript."+original)
f.model.stringValue="first-model"
f.switchBot("writer")
precondition(f.sessionID != original && f.chats.numberOfItems == 1 && f.answer.string.isEmpty && f.model.stringValue.isEmpty)
f.model.stringValue="second-model"
f.input.stringValue="Draft"
f.switchBot("")
precondition(f.sessionID == original && f.answer.string.contains("Hello") && f.model.stringValue=="first-model")
f.switchBot("writer")
precondition(f.model.stringValue=="second-model" && f.input.stringValue=="Draft")
print("Bot session, transcript, model and draft isolation passed")
