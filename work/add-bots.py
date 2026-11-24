from pathlib import Path
p=Path("outputs/Friday.swift")
s=p.read_text()
for k in ["fridaySession","draft.","chatProvider","chatModel","transcript."]:
 s=s.replace('forKey:"'+k+'"','forKey:scope + "'+k+'"')
s=s.replace('let prefix = "transcript."','let prefix = scope + "transcript."\n        let draftPrefix = scope + "draft."').replace('hasPrefix("draft.")','hasPrefix(draftPrefix)').replace('dropFirst(6)','dropFirst(draftPrefix.count)').replace('let key = "transcript."','let key = self.scope + "transcript."')
s=s.replace('    var sessionID:', '''    let bots = NSPopUpButton()
    let addBot = NSButton()
    var activeBot = UserDefaults.standard.string(forKey:"activeBot") ?? ""
    var scope: String { activeBot.isEmpty ? "" : "bot." + activeBot + "." }
    var profiles: [String:[String:String]] {
        UserDefaults.standard.dictionary(forKey:"fridayBots") as? [String:[String:String]] ?? [:]
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
        UserDefaults.standard.set(provider.stringValue, forKey:scope + "chatProvider")
        UserDefaults.standard.set(model.stringValue, forKey:scope + "chatModel")
        activeBot = id
        UserDefaults.standard.set(id, forKey:"activeBot")
        provider.stringValue = UserDefaults.standard.string(forKey:scope + "chatProvider") ?? ""
        model.stringValue = UserDefaults.standard.string(forKey:scope + "chatModel") ?? ""
        input.stringValue = UserDefaults.standard.string(forKey:scope + "draft." + sessionID) ?? ""
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
        UserDefaults.standard.set(updated, forKey:"fridayBots")
        switchBot(id)
    }
    var sessionID:''')
s=s.replace('height:460),styleMask','height:510),styleMask').replace('        showHistory()\n        window.makeKey','''        bots.target = self
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
        window.makeKey''')
s=s.replace('chats.isEnabled = !value;', 'bots.isEnabled = !value; addBot.isEnabled = !value; chats.isEnabled = !value;').replace('self.recorder=r;', 'self.bots.isEnabled=false; self.addBot.isEnabled=false; self.recorder=r;')
s=s.replace('let arguments = route + ["-q", q]', '''let profile = profiles[activeBot]
        let speaker = profile?["name"] ?? "FRIDAY"
        let prompt = profile.map { "Your name is " + speaker + ". " + ($0["instructions"] ?? "") + "\\n\\nUser request:\\n" + q } ?? q
        let arguments = route + ["-q", prompt]''').replace('q + "\\n\\nFRIDAY\\n" + s','q + "\\n\\n" + speaker + "\\n" + s').replace('components(separatedBy:"\\n\\nFRIDAY\\n")','components(separatedBy:"\\n\\n")')
p.write_text(s)
