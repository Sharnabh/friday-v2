import Foundation
import AppKit
import Vision

public final class ProcessRunner {
    public static func run(
        _ path: String,
        _ args: [String],
        errors: FileHandle = .nullDevice,
        inputFile: FileHandle? = nil,
        driverAction: String? = nil
    ) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        if let inputFile = inputFile { p.standardInput = inputFile }
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = driverAction == nil ? errors : pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if let action = driverAction, p.terminationStatus != 0 {
            let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (response?["refusal"] as? [String: Any])?["message"] as? String
                ?? (response?["error"] as? [String: Any])?["message"] as? String
                ?? response?["message"] as? String ?? response?["error"] as? String
            let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FridayError.message("Mac control (" + action + "): " + (detail ?? (raw.isEmpty ? "Driver exited with status " + String(p.terminationStatus) : String(raw.prefix(400)))))
        }
        guard p.terminationStatus == 0 else {
            throw FridayError.message("Could not complete " + URL(fileURLWithPath: path).lastPathComponent + ". Check its installation and permissions.")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class MacAutomationDriver {
    public static func callDriver(_ action: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let json = try JSONSerialization.data(withJSONObject: arguments)
        let result = try ProcessRunner.run(
            "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
            ["call", action, String(decoding: json, as: UTF8.self)],
            driverAction: action
        )
        return (try JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] ?? [:]
    }

    public static func recognizeWindowText(_ url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(url: url).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    public static func readActiveWindow() throws -> String {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in entries {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  app.bundleIdentifier != "local.friday.assistant",
                  let id = entry[kCGWindowNumber as String] as? Int else { continue }
            let appName = app.localizedName ?? "Application"
            _ = try? ProcessRunner.run("/usr/bin/open", ["-g", "-a", "/Applications/CuaDriver.app"])
            let state = try? callDriver("get_window_state", ["pid": Int(pid), "window_id": id, "tree_format": "elements", "include_screenshot": false])
            let title = state?["window_title"] as? String ?? entry[kCGWindowName as String] as? String ?? ""
            let source = title.isEmpty ? appName : appName + " — " + title
            var lines = [String](), seen = Set<String>()
            for element in state?["elements"] as? [[String: Any]] ?? [] {
                guard let role = element["role"] as? String,
                      ["AXStaticText", "AXHeading", "AXTextArea", "AXTextField", "AXCell", "AXLink"].contains(role),
                      element["subrole"] as? String != "AXSecureTextField" else { continue }
                for key in ["value", "label", "title"] {
                    guard let raw = element[key] as? String else { continue }
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty && seen.insert(text).inserted { lines.append(text) }
                }
            }
            var content = lines.joined(separator: "\n")
            if content.isEmpty {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: url) }
                guard CGPreflightScreenCaptureAccess() else {
                    throw FridayError.message("Screen Recording access needed to read " + source + ".")
                }
                do {
                    _ = try ProcessRunner.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), url.path])
                    content = try recognizeWindowText(url)
                } catch {
                    throw FridayError.message("Could not read " + source + ". Bring the window forward and try again.")
                }
            }
            return source + "\n" + (content.isEmpty ? "No readable text found." : String(content.prefix(4000)))
        }
        throw FridayError.message("Bring the window you want to read to the front and try again.")
    }

    public static func readEditor(_ query: String, windowTitle: String? = nil) throws -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            throw FridayError.message("Open a document in TextEdit first.")
        }
        _ = try ProcessRunner.run("/usr/bin/open", ["-g", "-a", "/Applications/CuaDriver.app"])
        let pid = Int(app.processIdentifier)
        var listing: [String: Any]?
        for _ in 0..<10 {
            listing = try? callDriver("list_windows", ["pid": pid])
            if listing != nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let windows = listing?["windows"] as? [[String: Any]] ?? []
        let documents = windows.filter { ($0["layer"] as? Int) == 0 }
        let matches = windowTitle.map { title in documents.filter { $0["title"] as? String == title } } ?? documents
        if let title = windowTitle, matches.count != 1 {
            throw FridayError.message(matches.isEmpty ? "Open the TextEdit document named “" + title + "” to run this check." : "Multiple TextEdit windows share that title.")
        }
        guard let window = matches.first, let id = window["window_id"] else {
            throw FridayError.message("No TextEdit document window was found.")
        }
        let state = try callDriver("get_window_state", ["pid": pid, "window_id": id, "include_screenshot": false, "tree_format": "elements"])
        let elements = state["elements"] as? [[String: Any]] ?? []
        guard let area = elements.first(where: { $0["role"] as? String == "AXTextArea" }),
              let body = (area["value"] as? String) ?? (area["label"] as? String), !body.isEmpty else {
            throw FridayError.message("Could not read the TextEdit text area. Check CuaDriver Accessibility permission.")
        }
        if query.localizedCaseInsensitiveContains("code"), let range = body.range(of: "verification code:", options: .caseInsensitive) {
            return String(body[range.upperBound...].prefix(while: { !$0.isNewline })).trimmingCharacters(in: .whitespaces)
        }
        return body
    }

    public static func performMacPlan(_ raw: String, locate: ((URL,String) throws -> [String:Double])? = nil, refine: (([String],[String],String) throws -> MacPlan)? = nil) throws -> String {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end,
              let plan = try? JSONDecoder().decode(MacPlan.self, from: Data(raw[start...end].utf8)),
              !plan.app.isEmpty else {
            throw FridayError.message("The model could not identify the app and controls.")
        }
        func activate(_ requested:String) throws -> NSRunningApplication {
        let workspace = NSWorkspace.shared
        let appName = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let appURL = workspace.urlForApplication(withBundleIdentifier: appName)
            ?? workspace.fullPath(forApplication: appName).map { URL(fileURLWithPath: $0) }
        guard let url = appURL, let bundleID = Bundle(url: url)?.bundleIdentifier else {
            throw FridayError.message("macOS could not find an installed app named “" + appName + "”.")
        }
        _ = try ProcessRunner.run("/usr/bin/open", ["-a", url.path])
        var launched: NSRunningApplication?
        for _ in 0..<50 {
            launched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            if launched?.isActive == true { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let running = launched else { throw FridayError.message(appName + " did not finish launching.") }
        return running
        }
        var running = try activate(plan.app)
        var pid = Int(running.processIdentifier)
        var name = running.localizedName ?? plan.app
        if plan.steps.isEmpty {
            guard running.isActive else { throw FridayError.message(name + " is running, but its activation could not be verified.") }
            return "Opened " + name + "."
        }

        // Launch the local driver before planning the first UI mutation. Only retry a read.
        if (try? callDriver("list_windows",["pid":pid])) == nil {
            _ = try ProcessRunner.run("/usr/bin/open",["-g","-a","/Applications/CuaDriver.app"])
            for _ in 0..<20 {
                if (try? callDriver("list_windows",["pid":pid])) != nil {break}
                Thread.sleep(forTimeInterval:0.15)
            }
        }
        func window() throws -> [String: Any] {
            for _ in 0..<8 {
                let windows = try callDriver("list_windows", ["pid": pid])["windows"] as? [[String: Any]] ?? []
                if let first = windows.first(where: { $0["layer"] as? Int == 0 && $0["is_on_screen"] as? Bool == true }) ?? windows.first(where: { $0["layer"] as? Int == 0 }), let id = first["window_id"] {
                    return ["pid": pid, "window_id": id]
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            throw FridayError.message(name + " has no accessible window.")
        }

        func elements(_ target: [String: Any]) throws -> [[String: Any]] {
            var query = target
            query["tree_format"] = "elements"
            query["include_screenshot"] = false
            return try callDriver("get_window_state", query)["elements"] as? [[String: Any]] ?? []
        }

        let labels = try elements(window()).compactMap { element in
            (element["label"] as? String) ?? (element["title"] as? String)
        }
        let grounded = try refine?(Array(labels.prefix(160)),[],plan.app) ?? plan
        guard grounded.app.caseInsensitiveCompare(plan.app) == .orderedSame, !grounded.steps.isEmpty else {
            throw FridayError.message("Could not resolve the requested controls in " + name + ".")
        }

        var remaining = ArraySlice(grounded.steps)
        var completed = [String]()
        var expected = grounded.expected
        var lastWindow = try window()["window_id"] as? Int
        func modalSignature(_ items:[[String:Any]]) -> String {
            items.filter { ["AXSheet","AXDialog"].contains($0["role"] as? String ?? "") || ($0["subrole"] as? String)=="AXDialog" }
                .map { ($0["role"] as? String ?? "") + ($0["title"] as? String ?? "") }.joined(separator:"|")
        }
        var modal = modalSignature(try elements(window()))
        var replans = 0
        while let step = remaining.first {
            try Task.checkCancellation()
            var args = try window()
            let observed = try elements(args)
            let newModal = modalSignature(observed)
            let missingClick = step.action == "click" && !observed.contains { item in
                ["label","description","title","value"].contains { (item[$0] as? String)?.caseInsensitiveCompare(step.value) == .orderedSame }
            }
            if (args["window_id"] as? Int != lastWindow || modal != newModal || missingClick), let refine {
                guard replans < 5 else {throw FridayError.message("The active window kept changing.")}
                replans += 1
                let current = observed.compactMap {$0["label"] as? String}
                let revised = try refine(Array(current.prefix(160)),completed,name)
                guard revised.app.caseInsensitiveCompare(name) == .orderedSame else {throw FridayError.message("Unexpected app during recovery.")}
                modal = newModal
                remaining = ArraySlice(revised.steps);expected = revised.expected
                lastWindow = args["window_id"] as? Int
                continue
            }
            remaining = remaining.dropFirst()
            let tool: String
            switch step.action {
            case "switchApp":
                running = try activate(step.value);pid = Int(running.processIdentifier);name = running.localizedName ?? step.value
                lastWindow = nil;completed.append("Activated "+name);continue
            case "visualClick":
                guard let locate else {throw FridayError.message("Visual targeting unavailable.")}
                let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
                defer {try? FileManager.default.removeItem(at:url)}
                var query=args;query["screenshot_out_file"]=url.path;query["include_accessibility_tree"]=false
                let snapshot=try callDriver("get_window_state",query)
                guard let capture=snapshot["capture_id"],let width=snapshot["screenshot_width"] as? Int,let height=snapshot["screenshot_height"] as? Int else {throw FridayError.message("No actionable screenshot.")}
                let point=try locate(url,step.value)
                guard let x=point["x"],let y=point["y"],x>=0,x<1,y>=0,y<1 else {throw FridayError.message("No unique visual match for "+step.value)}
                args["capture_id"]=capture;args["x"]=Int(x*Double(width));args["y"]=Int(y*Double(height));tool="click"
            case "key":
                tool = "press_key"
                args["key"] = step.value.lowercased() == "esc" ? "escape" : step.value
            case "hotkey":
                tool = "hotkey"
                args["keys"] = step.value.components(separatedBy: "+")
            case "type":
                tool = "type_text"
                args["text"] = step.value
            case "menu":
                tool = "invoke_menu"
                args["path"] = step.value.components(separatedBy: " > ")
            case "click":
                let literal = try JSONSerialization.data(withJSONObject: [step.value, args], options: [])
                let script = "const [name,target] = " + String(decoding: literal, as: UTF8.self) + """
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
                let response = try callDriver("run_script", ["script": script])
                guard response["ok"] as? Bool == true else {
                    throw FridayError.message("Could not click “" + step.value + "” in " + name + ".")
                }
                completed.append("click "+step.value)
                Thread.sleep(forTimeInterval: 0.18)
                continue
            default:
                throw FridayError.message("Unsupported UI action in " + name + ": " + step.action)
            }
            args["delivery_mode"] = "foreground"
            try Task.checkCancellation()
            let result = try callDriver(tool, args)
            if result["error"] != nil || result["effect"] as? String == "refused" {
                throw FridayError.message(name + " refused the " + step.action + " action.")
            }
            completed.append(step.action+" "+step.value)
            Thread.sleep(forTimeInterval: 0.18)
        }

        let target = try window()
        let values = try elements(target).flatMap { e in ["value", "label", "title"].compactMap { e[$0] as? String } }
        func matches(_ text: String) -> Bool {
            !expected.isEmpty && text.range(of: expected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let finalWindows = try callDriver("list_windows", ["pid": pid])["windows"] as? [[String: Any]] ?? []
        let title = finalWindows.first { ($0["window_id"] as? Int) == (target["window_id"] as? Int) }?["title"] as? String ?? ""
        if completed.last == "Activated " + name,
           running.isActive, expected.caseInsensitiveCompare(name) == .orderedSame {
            return name + " is the active application."
        }
        var verified = matches(title) || values.contains(where: matches)
        if !verified, let id = target["window_id"], CGPreflightScreenCaptureAccess() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: url) }
            if (try? ProcessRunner.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(describing: id), url.path])) != nil,
               let text = try? recognizeWindowText(url) { verified = matches(text) }
        }
        return verified ? name + " shows “" + expected + "”." : "Sent the requested controls to " + name + ". I could not verify the final result."
    }
}
