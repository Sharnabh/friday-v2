import Foundation

public final class ScreenInferenceRouter {
    private static var launcherPath: String {
        return AppResources.path("launch_voice","py")
    }

    public static func infer(_ request: [String: Any], provider: String, model: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: request)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: payload, attributes: [.posixPermissions: 0o600]) else {
            throw FridayError.message("Could not prepare request payload.")
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let launcher = launcherPath
        guard !launcher.isEmpty else {
            throw FridayError.message("launch_voice.py launcher is missing.")
        }

        do {
            return try ProcessRunner.run("/usr/bin/python3", [launcher, "--screen-summary", provider, model], inputFile: handle)
        } catch {
            if request["operation"] as? String == "control" {
                throw FridayError.message("FRIDAY could not get a usable action plan from the selected model. No controls were sent.")
            }
            throw error
        }
    }

    public static func routeQuestion(_ question: String, history: [String], hasPreviousCapture: Bool, provider: String, model: String) throws -> ScreenRoute {
        let lower = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Fast-path unambiguous conversational turns so chat doesn't stall behind a pre-route LLM call,
        // while keeping full routing for any screen, visual, editor, mail, calendar, message, memory, or UI control intent.
        let actionKeywords = [
            "screen", "window", "display", "look", "see", "read", "visible", "screenshot",
            "chart", "graph", "diagram", "image", "picture", "layout",
            "textedit", "editor", "document", "file",
            "mail", "email", "inbox", "reply", "calendar", "schedule", "meeting", "availability", "free", "busy", "remind", "follow up", "followup",
            "imessage", "sms", "message", "text ", "draft", "remember", "save",
            "open", "launch", "switch", "click", "press", "type", "scroll", "close", "quit", "control", "calculator", "safari", "notes", "finder", "app"
        ]
        let contextualFollowUpWords = ["that", "this", "it", "previous", "above"]
        let needsActionRoute = actionKeywords.contains { lower.contains($0) }
            || (hasPreviousCapture && contextualFollowUpWords.contains { lower.contains($0) })

        if !needsActionRoute {
            return ScreenRoute(source: .chat, mode: .answer)
        }

        let request: [String: Any] = [
            "operation": "route",
            "question": question,
            "history": history,
            "hasPreviousCapture": hasPreviousCapture,
            "now": ISO8601DateFormatter().string(from: Date()),
            "timeZone": TimeZone.current.identifier
        ]
        let raw = try infer(request, provider: provider, model: model)
        guard let data = raw.data(using: .utf8),
              let route = try? JSONDecoder().decode(ScreenRoute.self, from: data) else {
            throw FridayError.message("The model returned an unclear routing decision.")
        }
        return route
    }
}
