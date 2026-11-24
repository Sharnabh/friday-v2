import Foundation
import AVFoundation

public final class AssistantService: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    public static let shared = AssistantService()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var isMuted = false

    override private init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
        if muted {
            stopSpeaking()
        }
    }

    public func speak(_ text: String) {
        guard !isMuted else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: String(text.prefix(1500)))
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Executes a clean, direct prompt without artificial wrapper templates
    public func executeRawChat(
        prompt: String,
        provider: String,
        model: String
    ) async throws -> String {
        var args = ["chat", "--quiet", "--reasoning", "none"]
        if !provider.isEmpty { args += ["--provider", provider] }
        if !model.isEmpty { args += ["--model", model] }
        args += ["-q", prompt]

        let hermesPath = NSHomeDirectory() + "/.local/bin/hermes"
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var accumulated = ""
        let outHandle = stdoutPipe.fileHandleForReading
        try process.run()

        for try await line in outHandle.bytes.lines {
            if line.hasPrefix("Resume this session with:") || line.hasPrefix("Session: ") || line.hasPrefix("Duration: ") || line.hasPrefix("Messages: ") || line.hasPrefix("▼ Hermes") || line.hasPrefix("session_id: ") {
                continue
            }
            accumulated += line + "\n"
        }

        process.waitUntilExit()
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Executes inference with streaming callback chunks
    public func streamChat(
        prompt: String,
        provider: String,
        model: String,
        sessionID: String,
        contextMemory: String,
        botName: String,
        botInstructions: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var args = ["chat", "--quiet", "--reasoning", "none"]
        if !provider.isEmpty { args += ["--provider", provider] }
        if !model.isEmpty { args += ["--model", model] }

        let resumeKey = "hermesSession." + sessionID
        if let id = UserDefaults.standard.string(forKey: resumeKey) {
            args += ["--resume", id]
        }

        let fullPrompt = """
        Your name is \(botName). \(botInstructions)
        \(contextMemory.isEmpty ? "" : "User-approved context memories:\n" + contextMemory + "\n\n")
        User request:
        \(prompt)
        """
        args += ["-q", fullPrompt]

        let hermesPath = NSHomeDirectory() + "/.local/bin/hermes"
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var accumulated = ""
        let outHandle = stdoutPipe.fileHandleForReading

        try process.run()

        for try await line in outHandle.bytes.lines {
            // Strip out internal debug headers or session footer markers if present
            if line.hasPrefix("Resume this session with:") || line.hasPrefix("Session: ") || line.hasPrefix("Duration: ") || line.hasPrefix("Messages: ") || line.hasPrefix("▼ Hermes") || line.hasPrefix("session_id: ") {
                continue
            }
            accumulated += line + "\n"
            onChunk(line + "\n")
        }

        process.waitUntilExit()

        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: errData, as: UTF8.self)
        for line in errText.components(separatedBy: .newlines) {
            if line.hasPrefix("session_id: ") {
                UserDefaults.standard.set(String(line.dropFirst(12)), forKey: resumeKey)
            }
        }

        if process.terminationStatus != 0 && accumulated.isEmpty {
            throw FridayError.message("Inference failed: " + errText)
        }

        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
