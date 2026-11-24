import AppKit
import SQLite3
import EventKit
import Vision
import AVFoundation

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func run(_ path: String, _ args: [String], errors: FileHandle = .nullDevice, inputFile: FileHandle? = nil, driverAction: String? = nil) throws -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath:path)
    if let inputFile = inputFile { p.standardInput = inputFile }
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = driverAction == nil ? errors : pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if let action = driverAction, p.terminationStatus != 0 {
        let response = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        let detail = (response?["refusal"] as? [String:Any])?["message"] as? String
            ?? (response?["error"] as? [String:Any])?["message"] as? String
            ?? response?["message"] as? String ?? response?["error"] as? String
        let raw = String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        throw Failure.message("Mac control (" + action + "): " + (detail ?? (raw.isEmpty ? "Driver exited with status " + String(p.terminationStatus) : String(raw.prefix(400)))))
    }
    guard p.terminationStatus == 0 else { throw Failure.message("Could not complete " + URL(fileURLWithPath:path).lastPathComponent + ". Check its installation and permissions.") }
    return String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
}
func driver(_ action:String,_ arguments:[String:Any]) throws -> [String:Any] {
    let json = try JSONSerialization.data(withJSONObject:arguments)
    let result = try run("/Applications/CuaDriver.app/Contents/MacOS/cua-driver",["call",action,String(decoding:json,as:UTF8.self)],driverAction:action)
    return (try JSONSerialization.jsonObject(with:Data(result.utf8))) as? [String:Any] ?? [:]
}
struct MemoryEntry {
    let id:Int64
    let scope:String
    let body:String
    let source:String
    let revision:String
}

final class MemoryStore {
    private var db:OpaquePointer?
    private static let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard sqlite3_open(url.path,&db) == SQLITE_OK else {throw Failure.message("Could not open the memory database.")}
        sqlite3_busy_timeout(db,3000)
        try exec("""
        PRAGMA journal_mode=WAL;
        BEGIN IMMEDIATE;
        CREATE VIRTUAL TABLE IF NOT EXISTS memories USING fts5(scope UNINDEXED,body,source UNINDEXED,revision UNINDEXED,pinned UNINDEXED,tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS imported(scope TEXT PRIMARY KEY);
        COMMIT;
        """)
    }
    deinit {sqlite3_close(db)}
    private func exec(_ sql:String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw failure()}
    }
    private func failure() -> Failure { .message("Memory database: " + String(cString:sqlite3_errmsg(db))) }
    private func statement(_ sql:String,_ args:[String]) throws -> OpaquePointer {
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK, let stmt=stmt else {throw failure()}
        for (i,arg) in args.enumerated() {
            guard sqlite3_bind_text(stmt,Int32(i+1),arg,-1,Self.transient)==SQLITE_OK else {sqlite3_finalize(stmt);throw failure()}
        }
        return stmt
    }
    private func write(_ sql:String,_ args:[String]) throws {
        let stmt=try statement(sql,args); defer {sqlite3_finalize(stmt)}
        guard sqlite3_step(stmt)==SQLITE_DONE else {throw failure()}
    }
    func importNote(_ scope:String,_ note:String) throws {
        guard !note.isEmpty else {return}
        try exec("BEGIN IMMEDIATE")
        do {
            try write("INSERT OR IGNORE INTO imported VALUES(?)",[scope])
            if sqlite3_changes(db)>0 {
                try write("INSERT INTO memories(scope,body,source,revision,pinned) VALUES(?,?,?,?,'1')",
                          [scope,note,"Imported project note",UUID().uuidString])
            }
            try exec("COMMIT")
        } catch {try? exec("ROLLBACK");throw error}
    }
    func save(_ body:String,scope:String,source:String,original:MemoryEntry?) throws {
        let text=body.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else {throw Failure.message("Enter a memory before saving.")}
        let args=[scope,text,source,UUID().uuidString]
        if let old=original {
            try write("UPDATE memories SET scope=?,body=?,source=?,revision=? WHERE rowid=? AND revision=?",args+[String(old.id),old.revision])
            guard sqlite3_changes(db)==1 else {throw Failure.message("This memory changed. Reopen it before editing.")}
        } else {try write("INSERT INTO memories(scope,body,source,revision,pinned) VALUES(?,?,?,?,'0')",args)}
    }
    func remove(_ entry:MemoryEntry) throws {
        try write("DELETE FROM memories WHERE rowid=? AND revision=?",[String(entry.id),entry.revision])
        guard sqlite3_changes(db)==1 else {throw Failure.message("This memory changed. Refresh the search.")}
    }
    func search(_ query:String,scope:String,limit:Int=100,pinnedOnly:Bool=false) throws -> [MemoryEntry] {
        let tokens=query.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(32)
        var sql="SELECT rowid,scope,body,source,revision FROM memories WHERE scope IN ('shared',?)"
        var args=[scope]
        if pinnedOnly {sql += " AND pinned='1'"}
        if !tokens.isEmpty {
            sql += " AND memories MATCH ? ORDER BY rank,rowid DESC"
            args.append(tokens.map { "\"" + $0 + "\"" }.joined(separator:" OR "))
        } else {
            if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return []}
            sql += " ORDER BY rowid DESC"
        }
        let stmt=try statement(sql+" LIMIT ?",args+[String(limit)]); defer {sqlite3_finalize(stmt)}
        var rows=[MemoryEntry]()
        while true {
            let code=sqlite3_step(stmt)
            if code==SQLITE_DONE {return rows}
            guard code==SQLITE_ROW else {throw failure()}
            func col(_ i:Int32)->String {String(cString:sqlite3_column_text(stmt,i))}
            rows.append(MemoryEntry(id:sqlite3_column_int64(stmt,0),scope:col(1),body:col(2),source:col(3),revision:col(4)))
        }
    }
}

struct MacPlan: Decodable {
    struct Step: Decodable { let action:String; let value:String }
    let app:String
    let steps:[Step]
    let expected:String
}
func performMacPlan(_ raw:String, refine: (([String]) throws -> MacPlan)? = nil) throws -> String {
    guard let start=raw.firstIndex(of:"{"), let end=raw.lastIndex(of:"}"), start <= end,
          let plan=try? JSONDecoder().decode(MacPlan.self,from:Data(raw[start...end].utf8)),
          !plan.app.isEmpty else {throw Failure.message("The model could not identify the app and controls.")}
    let workspace = NSWorkspace.shared
    let appName = plan.app.trimmingCharacters(in:.whitespacesAndNewlines)
    let appURL = workspace.urlForApplication(withBundleIdentifier:appName)
        ?? workspace.fullPath(forApplication:appName).map { URL(fileURLWithPath:$0) }
    guard let url = appURL, let bundleID = Bundle(url:url)?.bundleIdentifier else {
        throw Failure.message("macOS could not find an installed app named “" + appName + "”.")
    }
    _ = try run("/usr/bin/open",["-a",url.path])
    var launched: NSRunningApplication?
    for _ in 0..<50 {
        launched = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first
        if launched?.isActive == true {break}
        Thread.sleep(forTimeInterval:0.1)
    }
    guard let running = launched else {throw Failure.message(appName + " did not finish launching.")}
    let pid = Int(running.processIdentifier)
    let name = running.localizedName ?? appName
    if plan.steps.isEmpty {
        guard running.isActive else {throw Failure.message(name + " is running, but its activation could not be verified.")}
        return "Opened " + name + "."
    }
    func window() throws -> [String:Any] {
        for _ in 0..<8 {
            let windows = try driver("list_windows",["pid":pid])["windows"] as? [[String:Any]] ?? []
            if let first=windows.first(where:{$0["layer"] as? Int == 0 && $0["is_on_screen"] as? Bool == true}) ?? windows.first(where:{$0["layer"] as? Int == 0}), let id=first["window_id"] {
                return ["pid":pid,"window_id":id]
            }
            Thread.sleep(forTimeInterval:0.15)
        }
        throw Failure.message(name + " has no accessible window.")
    }
    func elements(_ target:[String:Any]) throws -> [[String:Any]] {
        var query=target
        query["tree_format"]="elements"; query["include_screenshot"]=false
        return try driver("get_window_state",query)["elements"] as? [[String:Any]] ?? []
    }
    let labels = try elements(window()).compactMap { element in
        (element["label"] as? String) ?? (element["title"] as? String)
    }
    let grounded = try refine?(Array(labels.prefix(160))) ?? plan
    guard grounded.app.caseInsensitiveCompare(plan.app) == .orderedSame, !grounded.steps.isEmpty else {
        throw Failure.message("Could not resolve the requested controls in " + name + ".")
    }
    for step in grounded.steps {
        var args=try window()
        let tool:String
        switch step.action {
        case "key": tool="press_key"; args["key"]=step.value.lowercased() == "esc" ? "escape" : step.value
        case "hotkey": tool="hotkey"; args["keys"]=step.value.components(separatedBy:"+")
        case "type": tool="type_text"; args["text"]=step.value
        case "menu": tool="invoke_menu"; args["path"]=step.value.components(separatedBy:" > ")
        case "click":
            let literal = try JSONSerialization.data(withJSONObject:[step.value,args],options:[])
            let script = "const [name,target] = " + String(decoding:literal,as:UTF8.self) + """
            ; const app = await cua.getApp({pid:target.pid,windowId:target.window_id});
            const state = await app.getState({tree_format:'elements',include_screenshot:false});
            const matches = state.elements.filter(e => e.enabled !== false && ['label','title','description','value'].some(k => String(e[k] ?? '').toLowerCase() === name.toLowerCase()));
            const buttons = matches.filter(e => e.role === 'AXButton');
            const pool = buttons.length ? buttons : matches;
            const exact = pool.filter(e => e.label === name || e.title === name);
            const choices = exact.length ? exact : pool;
            if (choices.length !== 1) throw Error('Control missing or ambiguous');
            return await app.click(choices[0].element_token);
            """
            let response = try driver("run_script",["script":script])
            guard response["ok"] as? Bool == true else {throw Failure.message("Could not click “" + step.value + "” in " + name + ".")}
            Thread.sleep(forTimeInterval:0.18)
            continue
        default: throw Failure.message("Unsupported UI action in " + name + ": " + step.action)
        }
        args["delivery_mode"]="foreground"
        let result=try driver(tool,args)
        if result["error"] != nil || result["effect"] as? String == "refused" {throw Failure.message(name + " refused the " + step.action + " action.")}
        Thread.sleep(forTimeInterval:0.18)
    }
    let target=try window()
    let values=try elements(target).flatMap { e in ["value","label","title"].compactMap {e[$0] as? String} }
    func matches(_ text:String) -> Bool {
        !grounded.expected.isEmpty && text.range(of:grounded.expected,options:[.caseInsensitive,.diacriticInsensitive]) != nil
    }
    let finalWindows = try driver("list_windows",["pid":pid])["windows"] as? [[String:Any]] ?? []
    let title = finalWindows.first { ($0["window_id"] as? Int) == (target["window_id"] as? Int) }?["title"] as? String ?? ""
    var verified=matches(title) || values.contains(where:matches)
    if !verified, let id=target["window_id"], CGPreflightScreenCaptureAccess() {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer {try? FileManager.default.removeItem(at:url)}
        if (try? run("/usr/sbin/screencapture",["-x","-o","-l",String(describing:id),url.path])) != nil,
           let text=try? recognizeWindowText(url) {verified=matches(text)}
    }
    return verified ? name + " shows “" + grounded.expected + "”." : "Sent the requested controls to " + name + ". I could not verify the final result."
}

func mailOperation(_ arguments:[String]) throws -> [String:String] {
    guard let script = Bundle.main.path(forResource:"mail_reply",ofType:"js") else {throw Failure.message("FRIDAY’s Mail helper is missing.")}
    let raw = try run("/usr/bin/osascript", ["-l","JavaScript",script] + arguments)
    let result = try JSONDecoder().decode([String:String].self,from:Data(raw.utf8))
    if let error = result["error"] {throw Failure.message("Apple Mail: " + error)}
    return result
}

func upcomingCalendarConflicts() throws -> [String:Any] {
    let store = EKEventStore(), ready = DispatchSemaphore(value:0)
    if EKEventStore.authorizationStatus(for:.event) != .fullAccess {
        store.requestFullAccessToEvents { _,_ in ready.signal() }
        ready.wait()
    }
    guard EKEventStore.authorizationStatus(for:.event) == .fullAccess else {throw Failure.message("Allow FRIDAY full Calendar access in Privacy & Security to check availability.")}
    let start = Date(), end = Calendar.current.date(byAdding:.day,value:7,to:start)!
    let format = ISO8601DateFormatter()
    format.timeZone = .current
    let predicate = store.predicateForEvents(withStart:start,end:end,calendars:nil)
    let busy = store.events(matching:predicate).filter {$0.availability != .free && $0.status != .canceled}
    return ["from":format.string(from:start),"until":format.string(from:end),"timeZone":TimeZone.current.identifier,
            "busy":busy.map { [format.string(from:$0.startDate),format.string(from:$0.endDate)] }]
}

func draftMailReply(question:String, checkCalendar:Bool, launcher:String, provider:String, model:String) throws -> String {
    let message = try mailOperation(["read"])
    guard let identity=message["identity"], let body=message["body"], let subject=message["subject"] else {throw Failure.message("Could not read the selected email.")}
    var payload:[String:Any] = ["operation":"mailBody","question":question,"subject":subject,"body":body]
    if checkCalendar {payload["calendar"] = try upcomingCalendarConflicts()}
    let draft = try screenInference(payload, launcher:launcher, provider:provider, model:model)
    guard !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw Failure.message("The model returned an empty draft.")}
    let result = try mailOperation(["draft",identity,draft])
    return "Reply draft opened in Apple Mail for " + (result["recipients"] ?? "review") + ". Review it and use Send in Mail when ready."
}

struct ScreenRoute: Decodable {
    enum Source: String, Decodable { case active, editor, previous, control, remember, mailReply, calendarReply, chat }
    enum Mode: String, Decodable { case answer, verbatim }
    let source: Source
    let mode: Mode
}
func screenInference(_ request: [String:Any], launcher: String, provider: String, model: String) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject:request)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath:url.path, contents:payload, attributes:[.posixPermissions:0o600]) else {
        throw Failure.message("Could not prepare the screen summary.")
    }
    defer {try? FileManager.default.removeItem(at:url)}
    let handle = try FileHandle(forReadingFrom:url)
    defer {try? handle.close()}
    do {
        return try run("/usr/bin/python3", [launcher, "--screen-summary", provider, model], inputFile:handle)
    } catch {
        if request["operation"] as? String == "control" {
            throw Failure.message("FRIDAY could not get a usable action plan from the selected model. No controls were sent.")
        }
        throw error
    }
}

func recognizeWindowText(_ url: URL) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(url: url).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

struct ScreenRecordingRequired: LocalizedError {
    let source: String
    var errorDescription: String? { "FRIDAY needs Screen Recording access to read " + source + "." }
}

final class DraggableAppIcon: NSImageView, NSDraggingSource {
    let fileURL = Bundle.main.bundleURL
    override func mouseDown(with event: NSEvent) {
        guard let image = image else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with:[item], event:event, source:self)
    }
    func draggingSession(_ session:NSDraggingSession, sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
}

final class RecordingPermissionPanel: NSPanel {
    let hint = NSTextField(wrappingLabelWithString:"")
    init(source:String) {
        super.init(contentRect:NSRect(x:0,y:0,width:352,height:248),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        title = "Screen Recording access"
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        func place(_ v:NSView, _ x:Int,_ y:Int,_ w:Int,_ h:Int) {
            v.frame = NSRect(x:x,y:y,width:w,height:h); contentView?.addSubview(v)
        }
        place(NSTextField(wrappingLabelWithString:"To read " + source + ", drag FRIDAY into the Screen Recording list in System Settings and turn it on."),18,180,316,58)
        let icon = DraggableAppIcon()
        icon.image = NSWorkspace.shared.icon(forFile:Bundle.main.bundlePath)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Drag FRIDAY to System Settings")
        place(icon,144,110,64,64)
        let caption = NSTextField(labelWithString:"Drag Friday.app")
        caption.alignment = .center
        place(caption,18,86,316,20)
        hint.stringValue = "If FRIDAY is already listed, turn on its switch."
        place(hint,18,48,316,36)
        place(NSButton(title:"Open Settings",target:self,action:#selector(openSettings)),14,9,155,32)
        place(NSButton(title:"Check access",target:self,action:#selector(checkAccess)),182,9,155,32)
        if let frame = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x:frame.minX+16,y:frame.maxY-26))
        }
    }
    @objc func openSettings() {
        if !NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) {
            hint.stringValue = "Open System Settings → Privacy & Security → Screen Recording."
        }
    }
    @objc func checkAccess() {
        hint.stringValue = CGPreflightScreenCaptureAccess()
            ? "Access enabled. Return to your window and ask FRIDAY again."
            : "Access is pending. If already enabled, quit and reopen FRIDAY."
    }
}

func readActiveWindow() throws -> String {
    let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for entry in entries {
        guard entry[kCGWindowLayer as String] as? Int == 0,
              let pid = entry[kCGWindowOwnerPID as String] as? Int32,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              app.bundleIdentifier != "local.friday.assistant",
              let id = entry[kCGWindowNumber as String] as? Int else { continue }
        let appName = app.localizedName ?? "Application"
        _ = try? run("/usr/bin/open", ["-g", "-a", "/Applications/CuaDriver.app"])
        let state = try? driver("get_window_state", ["pid": Int(pid), "window_id": id, "tree_format": "elements", "include_screenshot": false])
        let title = state?["window_title"] as? String ?? entry[kCGWindowName as String] as? String ?? ""
        let source = title.isEmpty ? appName : appName + " — " + title
        var lines = [String](), seen = Set<String>()
        for element in state?["elements"] as? [[String: Any]] ?? [] {
            guard let role = element["role"] as? String,
                  ["AXStaticText","AXHeading","AXTextArea","AXTextField","AXCell","AXLink"].contains(role),
                  element["subrole"] as? String != "AXSecureTextField" else {continue}
            for key in ["value","label","title"] {
                guard let raw = element[key] as? String else {continue}
                let text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
                if !text.isEmpty && seen.insert(text).inserted {lines.append(text)}
            }
        }
        var content = lines.joined(separator:"\n")
        if content.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer {try? FileManager.default.removeItem(at:url)}
            guard CGPreflightScreenCaptureAccess() else {throw ScreenRecordingRequired(source:source)}
            do {
                _ = try run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), url.path])
                content = try recognizeWindowText(url)
            } catch {if !CGPreflightScreenCaptureAccess() {throw ScreenRecordingRequired(source:source)}
                throw Failure.message("Could not read " + source + ". Bring the window forward and try again.")}
        }
        return source + "\n" + (content.isEmpty ? "No readable text found." : String(content.prefix(4000)))
    }
    throw Failure.message("Bring the window you want to read to the front and try again.")
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
        guard let data = UserDefaults.standard.data(forKey:"namedGroups") else { return [:] }
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
                UserDefaults.standard.set(try JSONEncoder().encode(updated),forKey:"namedGroups")
                switchBot(id)
            } catch { status.stringValue = error.localizedDescription }
            break
        }
    }
    let memoryButton = NSButton()
    let privateNoteButton = NSButton()
    var memoryScope:String { (groupSelected ? "group:" : "private:") + activeBot }
    var memoryAudience:String { groupSelected ? "This group" : "This bot" }
    var memoryDatabase:MemoryStore?
    func openMemory() throws -> MemoryStore {
        if memoryDatabase == nil {
            let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            memoryDatabase=try MemoryStore(url:support.appendingPathComponent("Friday/Memory.sqlite"))
        }
        let store=memoryDatabase!
        let defaults=UserDefaults.standard
        try store.importNote("shared",defaults.string(forKey:"sharedProjectNote") ?? "")
        let key=(groupSelected ? "groupNote." : "privateNote.") + activeBot
        try store.importNote(memoryScope,defaults.string(forKey:key) ?? "")
        return store
    }
    func recalledMemory(_ query:String) throws -> String {
        let store=try openMemory()
        let pinned=try store.search("",scope:memoryScope,pinnedOnly:true)
        let matches=try store.search(query,scope:memoryScope,limit:5)
        var seen=Set<Int64>()
        return (pinned + matches).filter {seen.insert($0.id).inserted}.map {
            "[" + ($0.scope=="shared" ? "Shared" : memoryAudience) + ", " + $0.source + "] " + String($0.body.prefix(1500))
        }.joined(separator:"\n")
    }
    @objc func editMemory() { browseMemory() }
    @objc func editScopedNote() { do {try memoryEditor(try openMemory())} catch {status.stringValue=error.localizedDescription} }
    func browseMemory() {
        do {
            let store=try openMemory()
            var query=""
            while true {
                let rows=try store.search(query,scope:memoryScope)
                let panel=NSAlert();panel.messageText="Memory library"
                panel.informativeText="Search shared memories and memories for " + memoryAudience.lowercased() + "."
                let form=NSView(frame:NSRect(x:0,y:0,width:440,height:78))
                let field=NSSearchField(frame:NSRect(x:0,y:45,width:440,height:28))
                field.placeholderString="Search memories";field.stringValue=query;form.addSubview(field)
                let list=NSPopUpButton(frame:NSRect(x:0,y:4,width:440,height:30))
                for row in rows {
                    let audience=row.scope=="shared" ? "Shared" : memoryAudience
                    list.menu?.addItem(withTitle:audience + " · " + String(row.body.prefix(70)), action:nil,keyEquivalent:"")
                }
                if rows.isEmpty {list.addItem(withTitle:"No memories found");list.isEnabled=false}
                form.addSubview(list);panel.accessoryView=form;panel.window.initialFirstResponder=field
                panel.addButton(withTitle:"Search");panel.addButton(withTitle:"View / Edit").isEnabled = !rows.isEmpty
                panel.addButton(withTitle:"New");panel.addButton(withTitle:"Done").keyEquivalent="\u{1b}"
                let result=panel.runModal();query=field.stringValue
                if result == .alertFirstButtonReturn {continue}
                if result == .alertSecondButtonReturn, rows.indices.contains(list.indexOfSelectedItem) {try memoryEditor(store,entry:rows[list.indexOfSelectedItem]);continue}
                if result == .alertThirdButtonReturn {try memoryEditor(store);continue}
                return
            }
        } catch {status.stringValue=error.localizedDescription}
    }
    func memoryEditor(_ store:MemoryStore,entry:MemoryEntry?=nil,proposal:String="",source:String="Entered by you") throws {
        let panel=NSAlert();panel.messageText=entry == nil ? "Save a memory" : "Edit memory"
        panel.informativeText="Matching memories can be used by the selected audience’s chat models. Source: " + (entry?.source ?? source)
        let form=NSView(frame:NSRect(x:0,y:0,width:440,height:168))
        let audience=NSPopUpButton(frame:NSRect(x:0,y:132,width:300,height:30))
        audience.addItems(withTitles:[memoryAudience,"Shared with every bot"])
        audience.selectItem(at:entry?.scope=="shared" ? 1 : 0)
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:440,height:124))
        scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        let editor=NSTextView(frame:scroll.contentView.bounds);editor.isRichText=false;editor.autoresizingMask=[.width]
        editor.string=entry?.body ?? proposal;scroll.documentView=editor
        form.addSubview(scroll);form.addSubview(audience);panel.accessoryView=form;panel.window.initialFirstResponder=editor
        panel.addButton(withTitle:"Save");panel.addButton(withTitle:"Cancel")
        if entry != nil {panel.addButton(withTitle:"Delete")}
        let result=panel.runModal()
        if result == .alertFirstButtonReturn {
            try store.save(editor.string,scope:audience.indexOfSelectedItem==1 ? "shared" : memoryScope,source:entry?.source ?? source,original:entry)
            status.stringValue="Memory saved."
        } else if result == .alertThirdButtonReturn, let entry=entry {
            let confirm=NSAlert();confirm.messageText="Delete this memory?";confirm.addButton(withTitle:"Cancel");confirm.addButton(withTitle:"Delete")
            if confirm.runModal() == .alertSecondButtonReturn {try store.remove(entry);status.stringValue="Memory deleted."}
        }
    }
    var activeBot = UserDefaults.standard.string(forKey:"activeBot") ?? ""
    var scope: String { activeBot.isEmpty ? "" : "bot." + activeBot + "." }
    var profiles: [String:[String:String]] {
        UserDefaults.standard.dictionary(forKey:"fridayBots") as? [String:[String:String]] ?? [:]
    }
    func refreshBots() {
        bots.removeAllItems()
        let choices = [""] + profiles.keys.sorted() + (profiles.isEmpty ? [] : ["group"]) + groups.keys.sorted()
        privateNoteButton.title = "New memory"
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
    var sessionID: String {
        if let id = UserDefaults.standard.string(forKey:scope + "fridaySession") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey:scope + "fridaySession")
        return id
    }
    func showHistory() {
        let turns = UserDefaults.standard.stringArray(forKey:scope + "transcript." + sessionID) ?? []
        let defaults = UserDefaults.standard
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
        guard !capturing, let id = chats.selectedItem?.representedObject as? String else { return }
        saveDraft()
        UserDefaults.standard.set(id, forKey:scope + "fridaySession")
        input.stringValue = UserDefaults.standard.string(forKey:scope + "draft." + id) ?? ""
        speech.stopSpeaking()
        showHistory()
        status.stringValue = "Ready"
    }
    func saveDraft() {
        UserDefaults.standard.set(input.stringValue, forKey:scope + "draft." + sessionID)
    }
    @objc func beginChat() {
        saveDraft()
        speech.stopSpeaking()
        UserDefaults.standard.set(UUID().uuidString, forKey:scope + "fridaySession")
        input.stringValue = ""
        showHistory()
        status.stringValue = "Ready"
    }
    let provider = NSTextField(), model = NSTextField()
    let speech = NSSpeechSynthesizer()
    func applicationDidFinishLaunching(_ n:Notification) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:590),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "FRIDAY"; window.center(); window.delegate = self
        let root = window.contentView!
        func add(_ view:NSView,_ x:Int,_ y:Int,_ w:Int,_ h:Int) { view.frame = NSRect(x:x,y:y,width:w,height:h); root.addSubview(view) }
        let title = NSTextField(labelWithString:"Ask FRIDAY"); title.font = .systemFont(ofSize:25,weight:.semibold); add(title,24,412,450,36)
        add(NSTextField(labelWithString:"Chat provider"),24,383,160,20)
        add(NSTextField(labelWithString:"Model"),215,383,340,20)
        provider.placeholderString = "Hermes default"
        model.placeholderString = "Provider default"
        provider.stringValue = UserDefaults.standard.string(forKey:scope + "chatProvider") ?? ""
        model.stringValue = UserDefaults.standard.string(forKey:scope + "chatModel") ?? ""
        add(provider,24,352,178,28)
        add(model,215,352,361,28)
        input.placeholderString = "Read the verification code in TextEdit"; input.target=self; input.action=#selector(send); add(input,24,278,552,34)
        record.title="Record headset"; record.target=self; record.action=#selector(toggle); add(record,24,225,145,36)
        submit.title="Send"; submit.target=self; submit.action=#selector(send); add(submit,172,225,82,36)
        add(scheduleReplyButton,270,225,200,36)
        add(status,24,190,552,25)
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; answer.isEditable=false; answer.font = .systemFont(ofSize:17); answer.autoresizingMask = [.width]; scroll.documentView=answer; add(scroll,24,20,552,162)
        chats.target = self
        chats.action = #selector(selectChat)
        chats.setAccessibilityLabel("Saved chats")
        add(chats,205,414,250,34)
        input.stringValue = UserDefaults.standard.string(forKey:scope + "draft." + sessionID) ?? ""
        newChat.title = "New chat"
        newChat.target = self
        newChat.action = #selector(beginChat)
        add(newChat,466,414,110,34)
        bots.target = self
        bots.action = #selector(pickBot)
        bots.setAccessibilityLabel("Active bot")
        add(NSTextField(labelWithString:"Bot"),24,469,42,24)
        add(bots,65,465,245,30)
        memoryButton.title = "Memory library"
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
        privateNoteButton.title = "New memory"
        privateNoteButton.target = self
        privateNoteButton.action = #selector(editScopedNote)
        add(privateNoteButton,165,316,125,32)
        refreshBots()
        showHistory()
        let remindersButton = NSButton(title:"Reminders",target:self,action:#selector(manageReminders))
        add(remindersButton,460,316,116,32)
        let historyButton = NSButton(title:"Activity",target:self,action:#selector(showActivity))
        add(historyButton,356,316,98,32)
        Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.pollReminders() }
        setupVoice()
        Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.arm() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if CommandLine.arguments.contains("--screen-recording-settings") {
            presentRecordingPermission("the active window")
            permissionPanel?.openSettings()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func busy(_ value:Bool) { scheduleReplyButton.isEnabled = !value; newGroup.isEnabled = !value; bots.isEnabled = !value; addBot.isEnabled = !value; chats.isEnabled = !value; newChat.isEnabled = !value; record.isEnabled = !value; submit.isEnabled = !value; input.isEnabled = !value }
    var permissionPanel: RecordingPermissionPanel?
    func presentRecordingPermission(_ source:String) {
        permissionPanel?.close()
        let panel = RecordingPermissionPanel(source:source)
        permissionPanel = panel
        panel.orderFrontRegardless()
    }
    func job(_ label:String,_ work:@escaping () throws ->String,_ done:@escaping(String)->Void) {
        busy(true); status.stringValue=label
        DispatchQueue.global().async { let result=Result { try work() }; DispatchQueue.main.async { self.busy(false); switch result { case .success(let s): done(s); case .failure(let e):self.status.stringValue="Needs attention"; self.answer.string=e.localizedDescription; if let permission = e as? ScreenRecordingRequired {self.presentRecordingPermission(permission.source)} } } }
    }
    func sendGroup(_ question:String) {
        let defaults = UserDefaults.standard
        let key = scope + "transcript." + sessionID
        let previous = defaults.stringArray(forKey:key) ?? []
        let members = groupMembers
        var entries = previous + ["You\n" + question]
        defaults.set(entries, forKey:key)
        input.stringValue = ""
        saveDraft()
        showHistory()
        let note:String
        do {note=try recalledMemory(question)} catch {status.stringValue=error.localizedDescription;return}
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
        guard !capturing, submit.isEnabled else {return}
        let q=input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); guard !q.isEmpty else {return}
        stopCapture(); suppressReply=false
        let providerID = provider.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let modelID = model.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let key = scope + "transcript." + sessionID
        let cacheKey = scope + "screen." + sessionID
        let history = (UserDefaults.standard.stringArray(forKey:key) ?? []).suffix(3).map { String($0.prefix(2000)) }
        let previous = UserDefaults.standard.string(forKey:cacheKey)
        let request: [String:Any] = ["question":q, "history":history, "hasPreviousCapture":previous != nil]
        job("Understanding request…", {
            var routing = request
            routing["operation"] = "route"
            return try screenInference(routing, launcher:self.launcher, provider:providerID, model:modelID)
        }) { raw in
            guard let decision = try? JSONDecoder().decode(ScreenRoute.self,from:Data(raw.utf8)) else {
                self.status.stringValue="The model returned an unclear routing decision. Please retry."; return
            }
            if decision.source == .remember {
                var proposal=request
                proposal["operation"]="memoryProposal"
                self.job("Preparing memory for review…", {
                    try screenInference(proposal,launcher:self.launcher,provider:providerID,model:modelID)
                }) { text in
                    do {try self.memoryEditor(try self.openMemory(),proposal:text,source:"Chat " + self.sessionID)} catch {self.status.stringValue=error.localizedDescription}
                }
                return
            }
            if decision.source == .chat && self.groupSelected {self.sendGroup(q); return}
            self.respond(q, decision, request, previous, cacheKey, providerID, modelID)
        }
    }
    lazy var scheduleReplyButton = NSButton(title:"Draft scheduling reply",target:self,action:#selector(startSchedulingReply))
    @objc func startSchedulingReply() {
        guard !capturing, submit.isEnabled else {return}
        stopCapture()
        let q = "Check my availability and draft a scheduling reply to the selected email."
        respond(q, ScreenRoute(source:.calendarReply,mode:.answer), [:], nil, scope+"screen."+sessionID,
                provider.stringValue, model.stringValue)
    }
    func respond(_ q:String, _ decision:ScreenRoute, _ request:[String:Any], _ previous:String?, _ cacheKey:String, _ providerID:String, _ modelID:String) {
        var route = ["chat", "--quiet"]
        if !providerID.isEmpty { route += ["--provider", providerID] }
        if !modelID.isEmpty { route += ["--model", modelID] }
        UserDefaults.standard.set(providerID, forKey:scope + "chatProvider")
        UserDefaults.standard.set(modelID, forKey:scope + "chatModel")
        let resumeKey = "hermesSession." + sessionID
        if let id = UserDefaults.standard.string(forKey:resumeKey) { route += ["--resume", id] }
        let profile = profiles[activeBot]
        let speaker = profile?["name"] ?? "FRIDAY"
        let prompt = profile.map { "Your name is " + speaker + ". " + ($0["instructions"] ?? "") + "\n\nUser request:\n" + q } ?? q
        var memory=""
        if decision.source == .chat {
            do {memory=try recalledMemory(q)} catch {status.stringValue=error.localizedDescription;return}
        }
        let arguments = route + ["-q", memory.isEmpty ? prompt : "User-approved memory for context:\n" + memory + "\n\n" + prompt]
        job([.mailReply,.calendarReply].contains(decision.source) ? "Preparing Mail draft…" : decision.source == .control ? "Operating Mac app…" : decision.source == .chat ? "Waiting for the model…" : "Understanding window…", {
            if decision.source == .mailReply || decision.source == .calendarReply {
                return try draftMailReply(question:q, checkCalendar:decision.source == .calendarReply, launcher:self.launcher, provider:providerID, model:modelID)
            }
            if decision.source == .control {
                var payload = request
                payload["operation"] = "control"
                let plan = try screenInference(payload, launcher:self.launcher, provider:providerID, model:modelID)
                return try performMacPlan(plan) { labels in
                    payload["visibleControls"] = labels
                    payload["initialPlan"] = plan
                    let revised = try screenInference(payload, launcher:self.launcher, provider:providerID, model:modelID)
                    guard let start=revised.firstIndex(of:"{"), let end=revised.lastIndex(of:"}"), start <= end else {throw Failure.message("Could not interpret the controls.")}
                    return try JSONDecoder().decode(MacPlan.self,from:Data(revised[start...end].utf8))
                }
            }
            if decision.source != .chat {
                let capture: String
                switch decision.source {
                case .previous:
                    guard let previous = previous else {throw Failure.message("This chat has no previous screen capture.")}
                    capture = previous
                case .editor: capture = "TextEdit\n" + (try readEditor(""))
                case .active: capture = try readActiveWindow()
                case .remember, .mailReply, .calendarReply, .control, .chat: throw Failure.message("Unexpected screen request.")
                }
                UserDefaults.standard.set(String(capture.prefix(12000)), forKey:cacheKey)
                if decision.mode == .verbatim {return capture}
                var payload = request
                payload["operation"] = "answer"
                payload["capture"] = String(capture.prefix(12000))
                let answer = try screenInference(payload, launcher:self.launcher, provider:providerID, model:modelID)
                return String(capture.prefix(while:{!$0.isNewline})) + "\n" + answer
            }
            let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath:log.path, contents:nil, attributes:[.posixPermissions:0o600]) else { throw Failure.message("Could not create session log.") }
            defer { try? FileManager.default.removeItem(at:log) }
            let handle = try FileHandle(forWritingTo:log)
            defer { try? handle.close() }
            let reply = try run(NSHomeDirectory()+"/.local/bin/hermes",arguments,errors:handle)
            let lines = try String(contentsOf:log, encoding:.utf8).components(separatedBy:.newlines)
            if let marker = lines.last(where:{ $0.hasPrefix("session_id: ") }) {
                UserDefaults.standard.set(String(marker.dropFirst(12)), forKey:resumeKey)
            }
            return reply
        }) { s in
            let key = self.scope + "transcript." + self.sessionID
            var turns = UserDefaults.standard.stringArray(forKey:key) ?? []
            turns.append("You\n" + q + "\n\n" + speaker + "\n" + s)
            UserDefaults.standard.set(turns, forKey:key)
            self.showHistory()
            self.input.stringValue = ""
            self.saveDraft()
             self.status.stringValue="Ready"; self.speech.stopSpeaking(); if !self.suppressReply {self.speech.startSpeaking(String(s.prefix(1500)))} }
    }
    var recorder: Process?
    var commands: Pipe?
    var capturing = false
    var requesting = false
    var generation = 0
    let mic = NSPopUpButton(), wake = NSButton(checkboxWithTitle:"Hey Friday",target:nil,action:nil)
    let meter = NSProgressIndicator(), voiceStatus = NSTextField(labelWithString:"Microphone idle")
    let launcher = Bundle.main.path(forResource:"launch_voice",ofType:"py") ?? ""
    func setupVoice() {
        func place(_ v:NSView,_ x:Int,_ y:Int,_ w:Int,_ h:Int) {
            v.frame = NSRect(x:x,y:y,width:w,height:h); window.contentView?.addSubview(v)
        }
        mic.addItem(withTitle:"System microphone")
        mic.setAccessibilityLabel("Microphone")
        mic.target=self; mic.action=#selector(changeMic)
        place(mic,24,548,235,30)
        wake.target=self; wake.action=#selector(changeWake); place(wake,270,548,115,30)
        let mute = NSButton(title:"Mute / interrupt",target:self,action:#selector(muteVoice))
        place(mute,390,548,186,30)
        meter.isIndeterminate=false; meter.minValue=0; meter.maxValue=1
        place(meter,24,513,235,16); place(voiceStatus,270,505,306,30)
        DispatchQueue.global().async {
            let result = try? run("/usr/bin/python3",[self.launcher,"devices"])
            DispatchQueue.main.async {
                guard let result=result, let names=try? JSONDecoder().decode([String].self,from:Data(result.utf8)) else {self.voiceStatus.stringValue="Could not list microphones"; return}
                self.mic.addItems(withTitles:names)
                if let name=UserDefaults.standard.string(forKey:"fridayMic"), names.contains(name) {self.mic.selectItem(withTitle:name)}
            }
        }
    }
    @objc func changeMic() {
        UserDefaults.standard.set(mic.selectedItem?.title,forKey:"fridayMic")
        stopCapture(); arm()
    }
    func stopCapture() {
        generation += 1; requesting=false
        if let p=recorder, p.isRunning {p.terminate()}
        recorder=nil; commands=nil
        if capturing {busy(false)}
        capturing=false; meter.doubleValue=0; record.title="Record headset"; voiceStatus.stringValue="Microphone idle"
    }
    @objc func muteVoice() {wake.state = .off; stopCapture(); speech.stopSpeaking(); suppressReply=true}
    var suppressReply=false
    @objc func changeWake() {stopCapture(); arm()}
    func arm() {
        if wake.state == .on && recorder == nil && !requesting && submit.isEnabled && !speech.isSpeaking {startCapture(true)}
    }
    @objc func toggle() {
        if capturing {commands?.fileHandleForWriting.write(Data([10]));return}
        stopCapture(); speech.stopSpeaking(); startCapture(false)
    }
    func startCapture(_ handsFree:Bool) {
        requesting=true
        let token=generation
        AVCaptureDevice.requestAccess(for:.audio) { ok in DispatchQueue.main.async {
            guard self.generation == token else {return}
            self.requesting=false
            guard ok else {self.wake.state = .off; self.voiceStatus.stringValue="Allow microphone in System Settings";return}
            let p=Process(), out=Pipe(), control=Pipe()
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
            p.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            p.arguments=[self.launcher,handsFree ? "wake":"manual",self.mic.indexOfSelectedItem > 0 ? self.mic.titleOfSelectedItem ?? "" : "",url.path]
            p.standardOutput=out; p.standardInput=control; p.standardError=FileHandle.nullDevice
            do {try p.run()} catch {self.wake.state = .off; self.voiceStatus.stringValue=error.localizedDescription;return}
            self.recorder=p; self.commands=control; self.voiceStatus.stringValue="Starting microphone…"
            DispatchQueue.global().async {
                var buffer=Data(), complete=false, issue=""
                while true {
                    let data=out.fileHandleForReading.availableData
                    if data.isEmpty {break}
                    buffer.append(data)
                    while let end=buffer.firstIndex(of:10) {
                        let line=Data(buffer[..<end]); buffer.removeSubrange(...end)
                        guard let event=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else {continue}
                        if let error=event["error"] as? String {issue=error}
                        if event["complete"] as? Bool == true {complete=true}
                        DispatchQueue.main.async {
                            guard self.generation==token else {return}
                            if let level=event["level"] as? Double {self.meter.doubleValue=level}
                            if let state=event["state"] as? String {
                                self.voiceStatus.stringValue=state
                                if state=="Listening" {self.capturing=true;self.busy(true);self.record.isEnabled=true;self.record.title="Finish recording"}
                            }
                        }
                    }
                }
                p.waitUntilExit()
                let failure=issue, ready=complete
                DispatchQueue.main.async {
                    guard self.generation==token else {try? FileManager.default.removeItem(at:url);return}
                    self.stopCapture()
                    guard ready else {self.wake.state = .off;self.voiceStatus.stringValue=failure.isEmpty ? "Recording ended without audio" : failure;return}
                    let revision=self.generation
                    let dir=NSHomeDirectory()+"/.hermes/tools/friday-whisper/"
                    self.job("Transcribing locally…", { defer {try? FileManager.default.removeItem(at:url)}
                        return try run(dir+"whisper-cli",["-m",dir+"ggml-small.en.bin","-f",url.path,"-l","en","-ng","-nt","-np"])
                    }) { transcript in
                        guard revision==self.generation else {return}
                        self.input.stringValue=transcript;self.saveDraft()
                        self.status.stringValue="Review the transcript, then press Send."
                        if handsFree && self.wake.state == .on {self.send()}
                    }
                }
            }
        }}
    }
    func applicationWillTerminate(_ n:Notification) {stopCapture()}

}
if CommandLine.arguments.contains("--test-editor") {print(try readEditor("verification code"));exit(0)}
let app=NSApplication.shared, delegate=Friday()
app.setActivationPolicy(.regular); app.delegate=delegate; app.run()
