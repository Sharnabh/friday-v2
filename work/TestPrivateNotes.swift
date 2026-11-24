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
func readEditor(_ query:String, windowTitle:String? = nil) throws -> String {
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
    let documents = windows.filter { ($0["layer"] as? Int) == 0 }
    let matches = windowTitle.map { title in documents.filter { $0["title"] as? String == title } } ?? documents
    if let title = windowTitle, matches.count != 1 {
        throw Failure.message(matches.isEmpty ? "Open the TextEdit document named “" + title + "” to run this check." : "Multiple TextEdit windows share that title.")
    }
    guard let window = matches.first, let id = window["window_id"] else { throw Failure.message("No TextEdit document window was found.") }
    let state = try driver("get_window_state",["pid":pid,"window_id":id,"include_screenshot":false,"tree_format":"elements"])
    let elements = state["elements"] as? [[String:Any]] ?? []
    guard let area = elements.first(where:{$0["role"] as? String == "AXTextArea"}), let body = (area["value"] as? String) ?? (area["label"] as? String), !body.isEmpty else { throw Failure.message("Could not read the TextEdit text area. Check CuaDriver Accessibility permission.") }
    if query.localizedCaseInsensitiveContains("code"), let range = body.range(of:"verification code:",options:.caseInsensitive) {
        return String(body[range.upperBound...].prefix(while:{ !$0.isNewline })).trimmingCharacters(in:.whitespaces)
    }
    return body
}
enum Frequency: String, Codable {
    case daily = "Daily", weekly = "Weekly"
}
struct Reminder: Codable, Equatable {
    let id: UUID
    let text: String
    var due: Date
    var frequency: Frequency?
    var firstDue: Date?
    var readsTextEdit: Bool?
    func deliveryText() throws -> String {
        guard readsTextEdit == true else { return text }
        let contents = try readEditor("", windowTitle:text)
        let preview = String(contents.prefix(1200))
        return text + "\n\n" + preview + (preview.count < contents.count ? "…" : "")
    }
}

struct ReminderStore {
    let file: URL
    func update<T>(_ edit: (inout [Reminder]) -> T) throws -> T {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        let lock = Darwin.open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure.message("Could not open the reminders store.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.message("Could not lock the reminders store.") }
        var items = FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode([Reminder].self, from:Data(contentsOf:file)) : []
        let before = items
        let result = edit(&items)
        if before != items {
            try JSONEncoder().encode(items).write(to:file, options:.atomic)
        }
        return result
    }
    func takeDue(at now:Date) throws -> Reminder? {
        try update { items in
            guard let index = items.indices.filter({ items[$0].due <= now }).min(by:{ items[$0].due < items[$1].due }) else { return nil }
            let fired = items[index]
            if let frequency = fired.frequency {
                let calendar = Calendar.current
                let anchor = fired.firstDue ?? fired.due
                var pattern = calendar.dateComponents([.hour,.minute,.second], from:anchor)
                if frequency == .weekly { pattern.weekday = calendar.component(.weekday, from:anchor) }
                if let next = calendar.nextDate(after:now, matching:pattern, matchingPolicy:.nextTimePreservingSmallerComponents) {
                    items[index].firstDue = anchor
                    items[index].due = next
                    return fired
                }
            }
            return items.remove(at:index)
        }
    }
}
struct ActivityEntry: Codable {
    let date: Date
    let scheduled: Date
    let action: String
    let subject: String
    let error: String?
}

struct ActivityStore {
    let folder: URL
    func append(_ entry:ActivityEntry) throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(entry).write(to:file,options:.atomic)
    }
    func recent() throws -> [ActivityEntry] {
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(ActivityEntry.self,from:Data(contentsOf:$0))
        }.sorted { $0.date > $1.date }
    }
}
class Friday: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let reminders = ReminderStore(file:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FRIDAY/reminders.json"))
    var activity: ActivityStore {
        ActivityStore(folder:reminders.file.deletingLastPathComponent().appendingPathComponent("activity"))
    }
    @objc func showActivity() {
        let panel = NSAlert()
        panel.messageText = "Scheduled activity"
        do {
            let entries = try activity.recent()
            if entries.isEmpty {
                panel.informativeText = "Scheduled results will appear here after they run."
            } else {
                let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:470,height:270))
                scroll.hasVerticalScroller = true
                let detail = NSTextView(frame:scroll.contentView.bounds)
                detail.isEditable = false
                detail.autoresizingMask = [.width]
                detail.string = entries.prefix(100).map { entry in
                    let when = DateFormatter.localizedString(from:entry.date,dateStyle:.short,timeStyle:.medium)
                    let scheduled = DateFormatter.localizedString(from:entry.scheduled,dateStyle:.short,timeStyle:.short)
                    let result = entry.error.map { "Failed · " + $0 } ?? "Completed"
                    return when + " · " + entry.action + "\n" + entry.subject + "\nScheduled for " + scheduled + "\n" + result
                }.joined(separator:"\n\n")
                scroll.documentView = detail
                panel.accessoryView = scroll
            }
        } catch { panel.informativeText = error.localizedDescription }
        panel.runModal()
    }
    var showingReminder = false
    func pollReminders() {
        guard !showingReminder, NSApp.modalWindow == nil else { return }
        do {
            guard let reminder = try reminders.takeDue(at:Date()) else { return }
            showingReminder = true
            defer { showingReminder = false }
            let alert = NSAlert()
            alert.messageText = reminder.readsTextEdit == true ? "Scheduled TextEdit check" : "FRIDAY reminder"
            var failure: String?
            do { alert.informativeText = try reminder.deliveryText() }
            catch {
                failure = error.localizedDescription
                alert.informativeText = error.localizedDescription
            }
            do {
                try activity.append(ActivityEntry(date:Date(),scheduled:reminder.due,action:alert.messageText,subject:reminder.text,error:failure))
            } catch { status.stringValue = "Could not save activity: " + error.localizedDescription }
            NSApp.requestUserAttention(.criticalRequest)
            alert.runModal()
        } catch { status.stringValue = "Could not read reminders: " + error.localizedDescription }
    }
    @objc func manageReminders() {
        do {
            let items = try reminders.update { $0.sorted { $0.due < $1.due } }
            let alert = NSAlert()
            alert.messageText = "Reminders"
            alert.informativeText = "Reminders appear while FRIDAY is open. Overdue reminders appear the next time you open it."
            let view = NSView(frame:NSRect(x:0,y:0,width:400,height:160))
            let text = NSTextField(frame:NSRect(x:0,y:85,width:400,height:26))
            text.placeholderString = "Reminder message or exact TextEdit window title"
            let action = NSPopUpButton(frame:NSRect(x:0,y:123,width:400,height:28))
            action.addItems(withTitles:["Show a reminder", "Read a TextEdit document"])
            action.setAccessibilityLabel("Scheduled action")
            let date = NSDatePicker(frame:NSRect(x:0,y:45,width:250,height:30))
            date.datePickerElements = [.yearMonthDay,.hourMinute]
            date.datePickerStyle = .textFieldAndStepper
            date.dateValue = Date().addingTimeInterval(3600)
            let frequency = NSPopUpButton(frame:NSRect(x:258,y:45,width:142,height:30))
            frequency.addItems(withTitles:["Once", Frequency.daily.rawValue, Frequency.weekly.rawValue])
            frequency.setAccessibilityLabel("Repeat frequency")
            let pending = NSPopUpButton(frame:NSRect(x:0,y:2,width:400,height:28))
            for item in items {
                let time = DateFormatter.localizedString(from:item.due,dateStyle:.short,timeStyle:.short)
                let option = NSMenuItem(title:time + " · " + (item.frequency.map { $0.rawValue + " · " } ?? "") + (item.readsTextEdit == true ? "Read · " : "") + item.text,action:nil,keyEquivalent:"")
                option.representedObject = item.id
                pending.menu?.addItem(option)
            }
            if items.isEmpty { pending.addItem(withTitle:"No pending reminders"); pending.isEnabled = false }
            for control in [text as NSView,date,frequency,pending,action] { view.addSubview(control) }
            alert.accessoryView = view
            alert.window.initialFirstResponder = text
            alert.addButton(withTitle:"Schedule")
            alert.addButton(withTitle:"Close")
            if !items.isEmpty { alert.addButton(withTitle:"Remove selected") }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let message = text.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !message.isEmpty, date.dateValue > Date() else { status.stringValue = "Enter a reminder and a future time."; return }
                try reminders.update { $0.append(Reminder(id:UUID(),text:message,due:date.dateValue,frequency:Frequency(rawValue:frequency.titleOfSelectedItem ?? ""),readsTextEdit:action.indexOfSelectedItem == 1)) }
                status.stringValue = "Reminder scheduled."
            case .alertThirdButtonReturn:
                if let id = pending.selectedItem?.representedObject as? UUID {
                    try reminders.update { $0.removeAll { $0.id == id } }
                    status.stringValue = "Reminder removed."
                }
            default: break
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    var window:NSWindow!
    let input = NSTextField(), status = NSTextField(labelWithString:"Ready"), answer = NSTextView()
    let record = NSButton(), submit = NSButton()
    let newChat = NSButton()
    let chats = NSPopUpButton()
    let bots = NSPopUpButton()
    let addBot = NSButton()
    let newGroup = NSButton()
    struct BotGroup: Codable {
        let name: String
        let members: [String]
    }
    var groups: [String:BotGroup] {
        guard let data = testDefaults.data(forKey:"namedGroups") else { return [:] }
        return (try? JSONDecoder().decode([String:BotGroup].self, from:data)) ?? [:]
    }
    var groupSelected: Bool { activeBot == "group" || groups[activeBot] != nil }
    var groupMembers: [String] { groups[activeBot]?.members ?? ([""] + profiles.keys.sorted()) }
    @objc func createGroup() {
        let ids = [""] + profiles.keys.sorted()
        guard ids.count >= 2 else { status.stringValue = "Create a bot first to start a group."; return }
        let panel = NSAlert()
        panel.messageText = "Create a group chat"
        panel.informativeText = "Choose at least two members. Each selected member receives the group conversation and shared project note."
        let height = min(220,ids.count * 30)
        let form = NSView(frame:NSRect(x:0,y:0,width:360,height:height + 42))
        let name = NSTextField(frame:NSRect(x:0,y:height + 10,width:360,height:28))
        name.placeholderString = "Group name"
        form.addSubview(name)
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:360,height:height))
        scroll.hasVerticalScroller = true
        let list = NSView(frame:NSRect(x:0,y:0,width:330,height:ids.count * 30))
        let boxes = ids.enumerated().map { index,id in
            let box = NSButton(checkboxWithTitle:profiles[id]?["name"] ?? "FRIDAY",target:nil,action:nil)
            box.frame = NSRect(x:0,y:(ids.count-index-1)*30,width:325,height:28)
            list.addSubview(box)
            return box
        }
        scroll.documentView = list
        list.scroll(NSPoint(x:0,y:max(0,ids.count * 30 - height)))
        form.addSubview(scroll)
        panel.accessoryView = form
        panel.window.initialFirstResponder = name
        panel.addButton(withTitle:"Create")
        panel.addButton(withTitle:"Cancel")
        while panel.runModal() == .alertFirstButtonReturn {
            let title = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            let selected = zip(ids,boxes).filter { $0.1.state == .on }.map { $0.0 }
            guard !title.isEmpty, selected.count >= 2 else {
                panel.informativeText = "Enter a group name and select at least two members."
                continue
            }
            let id = "group-" + UUID().uuidString
            var updated = groups
            updated[id] = BotGroup(name:title,members:selected)
            do {
                testDefaults.set(try JSONEncoder().encode(updated),forKey:"namedGroups")
                switchBot(id)
            } catch { status.stringValue = error.localizedDescription }
            break
        }
    }
    let memoryButton = NSButton()
    let privateNoteButton = NSButton()
    var privateNoteKey: String { "privateNote." + activeBot }
    func directPrompt(_ prompt:String) -> String {
        let shared = withSharedMemory(prompt)
        guard !groupSelected, let text = testDefaults.string(forKey:privateNoteKey), !text.isEmpty else { return shared }
        return "Personal context supplied for this bot's direct chats:\n" + text + "\n\n" + shared
    }
    var sharedNote: String { testDefaults.string(forKey:"sharedProjectNote") ?? "" }
    func withSharedMemory(_ prompt:String) -> String {
        guard !sharedNote.isEmpty else { return prompt }
        return "Shared project notes supplied by the user:\n" + sharedNote + "\n\n" + prompt
    }
    func saveSharedNote(_ text:String) {
        let defaults = testDefaults
        let note = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if note.isEmpty {
            defaults.removeObject(forKey:"sharedProjectNote")
            defaults.removeObject(forKey:"sharedProjectNoteDate")
        } else {
            defaults.set(note, forKey:"sharedProjectNote")
            defaults.set(Date(), forKey:"sharedProjectNoteDate")
        }
    }
    @objc func editMemory() { editNote(personal:false) }
    @objc func editPrivateNote() {
        guard !groupSelected else { return }
        editNote(personal:true)
    }
    func editNote(personal:Bool) {
        let panel = NSAlert()
        panel.messageText = personal ? "Private note · " + (profiles[activeBot]?["name"] ?? "FRIDAY") : "Shared memory"
        panel.informativeText = "These notes are included in future model requests from FRIDAY and every bot on this Mac. Clear the notes and save to stop including them."
        if personal {
            panel.informativeText = "This note stays on this Mac and is included in direct chat requests to this bot’s model provider. Group prompts omit it. Clearing it affects future prompts; earlier conversations retain their history."
        }
        if let date = testDefaults.object(forKey:personal ? privateNoteKey + ".date" : "sharedProjectNoteDate") as? Date {
            panel.informativeText += "\n\nLast saved by you on " + DateFormatter.localizedString(from:date,dateStyle:.medium,timeStyle:.short) + "."
        }
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:420,height:170))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame:scroll.contentView.bounds)
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.string = personal ? (testDefaults.string(forKey:privateNoteKey) ?? "") : sharedNote
        scroll.documentView = editor
        panel.accessoryView = scroll
        panel.addButton(withTitle:"Save")
        panel.addButton(withTitle:"Cancel")
        panel.window.initialFirstResponder = editor
        if panel.runModal() == .alertFirstButtonReturn {
            if personal {
                let note = editor.string.trimmingCharacters(in:.whitespacesAndNewlines)
                let defaults = testDefaults
                if note.isEmpty {
                    defaults.removeObject(forKey:privateNoteKey)
                    defaults.removeObject(forKey:privateNoteKey + ".date")
                } else {
                    defaults.set(note,forKey:privateNoteKey)
                    defaults.set(Date(),forKey:privateNoteKey + ".date")
                }
                status.stringValue = note.isEmpty ? "Private note cleared." : "Private note saved."
                return
            }
            saveSharedNote(editor.string)
            status.stringValue = sharedNote.isEmpty ? "Shared memory cleared." : "Shared memory saved."
        }
    }
    var activeBot = testDefaults.string(forKey:"activeBot") ?? ""
    var scope: String { activeBot.isEmpty ? "" : "bot." + activeBot + "." }
    var profiles: [String:[String:String]] {
        testDefaults.dictionary(forKey:"fridayBots") as? [String:[String:String]] ?? [:]
    }
    func refreshBots() {
        bots.removeAllItems()
        let choices = [""] + profiles.keys.sorted() + (profiles.isEmpty ? [] : ["group"]) + groups.keys.sorted()
        privateNoteButton.isEnabled = !groupSelected
        provider.isEnabled = !groupSelected
        model.isEnabled = !groupSelected
        for id in choices {
            let item = NSMenuItem(title:id == "group" ? "Group chat · all bots" : (groups[id].map { "Group · " + $0.name } ?? profiles[id]?["name"] ?? "FRIDAY"), action:nil, keyEquivalent:"")
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
        add(bots,65,465,245,30)
        memoryButton.title = "Shared memory"
        memoryButton.target = self
        memoryButton.action = #selector(editMemory)
        add(memoryButton,320,462,138,34)
        addBot.title = "Create bot"
        addBot.target = self
        addBot.action = #selector(createBot)
        add(addBot,466,462,110,34)
        newGroup.title = "Create group"
        newGroup.target = self
        newGroup.action = #selector(createGroup)
        add(newGroup,24,316,135,32)
        privateNoteButton.title = "Private note"
        privateNoteButton.target = self
        privateNoteButton.action = #selector(editPrivateNote)
        add(privateNoteButton,165,316,125,32)
        refreshBots()
        showHistory()
        let remindersButton = NSButton(title:"Reminders",target:self,action:#selector(manageReminders))
        add(remindersButton,460,316,116,32)
        let historyButton = NSButton(title:"Activity",target:self,action:#selector(showActivity))
        add(historyButton,356,316,98,32)
        Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.pollReminders() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func busy(_ value:Bool) { newGroup.isEnabled = !value; bots.isEnabled = !value; addBot.isEnabled = !value; chats.isEnabled = !value; newChat.isEnabled = !value; record.isEnabled = !value; submit.isEnabled = !value; input.isEnabled = !value }
    func job(_ label:String,_ work:@escaping () throws ->String,_ done:@escaping(String)->Void) {
        busy(true); status.stringValue=label
        DispatchQueue.global().async { let result=Result { try work() }; DispatchQueue.main.async { self.busy(false); switch result { case .success(let s): done(s); case .failure(let e):self.status.stringValue="Needs attention"; self.answer.string=e.localizedDescription } } }
    }
    func sendGroup(_ question:String) {
        let defaults = testDefaults
        let key = scope + "transcript." + sessionID
        let previous = defaults.stringArray(forKey:key) ?? []
        let members = groupMembers
        var entries = previous + ["You\n" + question]
        defaults.set(entries, forKey:key)
        input.stringValue = ""
        saveDraft()
        showHistory()
        let note = sharedNote
        func next(_ index:Int) {
            guard index < members.count else {
                busy(false)
                status.stringValue = "Ready"
                return
            }
            let id = members[index]
            let name = profiles[id]?["name"] ?? "FRIDAY"
            let instructions = profiles[id]?["instructions"] ?? ""
            let prefix = id.isEmpty ? "" : "bot." + id + "."
            var arguments = ["chat","--quiet"]
            for (flag, setting) in [("--provider","chatProvider"),("--model","chatModel")] {
                if let value = defaults.string(forKey:prefix + setting), !value.isEmpty { arguments += [flag,value] }
            }
            let context = entries.suffix(20).joined(separator:"\n\n")
            arguments += ["-q","You are " + name + " in a group conversation. Respond once to the latest user request, taking earlier replies into account. " + instructions + "\nShared project note:\n" + note + "\nGroup conversation:\n" + context]
            let command = arguments
            busy(true)
            status.stringValue = name + " is replying…"
            DispatchQueue.global().async {
                let result = Result { try run(NSHomeDirectory()+"/.local/bin/hermes", command) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let reply): entries.append(name + "\n" + reply)
                    case .failure(let error): entries.append(name + " could not reply. " + error.localizedDescription)
                    }
                    defaults.set(entries,forKey:key)
                    self.showHistory()
                    next(index + 1)
                }
            }
        }
        next(0)
    }
    @objc func send() {
        guard recorder == nil, submit.isEnabled else {return}
        let q=input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); guard !q.isEmpty else {return}
        if groupSelected { sendGroup(q); return }
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
        let arguments = route + ["-q", directPrompt(prompt)]
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
                self.newChat.isEnabled=false; self.chats.isEnabled=false; self.bots.isEnabled=false; self.addBot.isEnabled=false; self.newGroup.isEnabled=false; self.recorder=r;self.submit.isEnabled=false;self.record.title="Stop recording";self.status.stringValue="Listening on the macOS default microphone…"
            } catch { self.status.stringValue=error.localizedDescription }
        }}
    }
}

let testDefaults = UserDefaults(suiteName:UUID().uuidString)!
let _ = NSApplication.shared
let f = Friday()
testDefaults.set("team",forKey:"sharedProjectNote")
f.switchBot("writer")
testDefaults.set("tone",forKey:f.privateNoteKey)
precondition(f.directPrompt("draft").contains("tone") && f.directPrompt("draft").contains("team"))
f.switchBot("")
precondition(!f.directPrompt("draft").contains("tone"))
f.switchBot("group")
precondition(!f.directPrompt("draft").contains("tone") && !f.privateNoteButton.isEnabled)
f.switchBot("writer")
precondition(Friday().directPrompt("draft").contains("tone"))
testDefaults.removeObject(forKey:f.privateNoteKey)
precondition(!f.directPrompt("draft").contains("tone"))
print("Verified private prompt inclusion, isolation, restoration and clearing.")
