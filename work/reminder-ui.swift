    let reminders = ReminderStore(file:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FRIDAY/reminders.json"))
    var showingReminder = false
    func pollReminders() {
        guard !showingReminder, NSApp.modalWindow == nil else { return }
        do {
            guard let reminder = try reminders.takeDue(at:Date()) else { return }
            showingReminder = true
            defer { showingReminder = false }
            let alert = NSAlert()
            alert.messageText = "FRIDAY reminder"
            alert.informativeText = reminder.text
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
            let view = NSView(frame:NSRect(x:0,y:0,width:400,height:120))
            let text = NSTextField(frame:NSRect(x:0,y:85,width:400,height:26))
            text.placeholderString = "Remind me to…"
            let date = NSDatePicker(frame:NSRect(x:0,y:45,width:300,height:30))
            date.datePickerElements = [.yearMonthDay,.hourMinute]
            date.datePickerStyle = .textFieldAndStepper
            date.dateValue = Date().addingTimeInterval(3600)
            let pending = NSPopUpButton(frame:NSRect(x:0,y:2,width:400,height:28))
            for item in items {
                let time = DateFormatter.localizedString(from:item.due,dateStyle:.short,timeStyle:.short)
                let option = NSMenuItem(title:time + " · " + item.text,action:nil,keyEquivalent:"")
                option.representedObject = item.id
                pending.menu?.addItem(option)
            }
            if items.isEmpty { pending.addItem(withTitle:"No pending reminders"); pending.isEnabled = false }
            for control in [text as NSView,date,pending] { view.addSubview(control) }
            alert.accessoryView = view
            alert.window.initialFirstResponder = text
            alert.addButton(withTitle:"Schedule")
            alert.addButton(withTitle:"Close")
            if !items.isEmpty { alert.addButton(withTitle:"Remove selected") }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let message = text.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !message.isEmpty, date.dateValue > Date() else { status.stringValue = "Enter a reminder and a future time."; return }
                try reminders.update { $0.append(Reminder(id:UUID(),text:message,due:date.dateValue)) }
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
