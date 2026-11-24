import Foundation

public final class ScreenInferenceRouter {
    private static var summaryScriptPath: String {
        if let path = Bundle.main.path(forResource: "screen_summary", ofType: "py") {
            return path
        }
        let fallback = "/Users/user/Documents/Codex/2026-11-23/i-w/outputs/Friday.app/Contents/Resources/screen_summary.py"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : ""
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

        let script = summaryScriptPath
        guard !script.isEmpty else {
            throw FridayError.message("screen_summary.py helper is missing.")
        }

        do {
            return try ProcessRunner.run("/usr/bin/python3", [script, provider, model], inputFile: handle)
        } catch {
            if request["operation"] as? String == "control" {
                throw FridayError.message("FRIDAY could not get a usable action plan from the selected model. No controls were sent.")
            }
            throw error
        }
    }

    public static func routeQuestion(_ question: String, history: [String], hasPreviousCapture: Bool, provider: String, model: String) throws -> ScreenRoute {
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
