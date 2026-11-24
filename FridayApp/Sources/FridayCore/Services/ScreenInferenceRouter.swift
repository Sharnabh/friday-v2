import Foundation

public final class ScreenInferenceRouter {
    private static var launcherPath: String {
        if let path = Bundle.main.path(forResource: "launch_voice", ofType: "py") {
            return path
        }
        let fallback = "/Users/user/Documents/Codex/2026-11-23/i-w/FridayApp/.build/Friday.app/Contents/Resources/launch_voice.py"
        if FileManager.default.fileExists(atPath: fallback) { return fallback }
        let outputsFallback = "/Users/user/Documents/Codex/2026-11-23/i-w/outputs/Friday.app/Contents/Resources/launch_voice.py"
        return FileManager.default.fileExists(atPath: outputsFallback) ? outputsFallback : ""
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
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Fast-path conversational greetings & assistant persona inquiries
        let isConversation = lower == "hi" || lower == "hello" || lower == "heyy" || lower == "hey" ||
                             lower.contains("tell me about yourself") ||
                             lower.contains("who are you") ||
                             lower.contains("what is your name") ||
                             lower.contains("what's your name") ||
                             lower.contains("introduce yourself") ||
                             lower.contains("what can you do") ||
                             lower.contains("how are you") ||
                             lower.contains("what is my name") ||
                             lower.contains("what's my name") ||
                             lower.contains("who am i")

        // Explicit screen inspection keywords
        let screenKeywords = ["screen", "window", "display", "active window", "look at", "what do you see", "read this", "read the screen", "on my screen"]
        let hasExplicitScreenRequest = screenKeywords.contains { lower.contains($0) }

        if isConversation && !hasExplicitScreenRequest {
            return ScreenRoute(source: .chat, mode: .answer)
        }

        let request: [String: Any] = [
            "operation": "route",
            "question": question,
            "history": history,
            "hasPreviousCapture": hasPreviousCapture
        ]
        let raw = try infer(request, provider: provider, model: model)
        guard let data = raw.data(using: .utf8),
              let route = try? JSONDecoder().decode(ScreenRoute.self, from: data) else {
            throw FridayError.message("The model returned an unclear routing decision.")
        }
        return route
    }
}
