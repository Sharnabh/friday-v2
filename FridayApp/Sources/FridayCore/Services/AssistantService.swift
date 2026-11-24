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

    /// Strips Hermes telemetry, internal chain of thought, and session summaries
    public static func cleanHermesOutput(_ raw: String) -> String {
        var text = raw

        // If "▼ Hermes" exists, the actual response begins after that marker
        if let range = text.range(of: "▼ Hermes\n") {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "▼ Hermes") {
            text = String(text[range.upperBound...])
        }

        // If "Resume this session with:" exists, strip it and everything after
        if let range = text.range(of: "Resume this session with:") {
            text = String(text[..<range.lowerBound])
        }

        let lines = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("Session:") &&
                   !trimmed.hasPrefix("Duration:") &&
                   !trimmed.hasPrefix("Messages:") &&
                   !trimmed.hasPrefix("session_id:") &&
                   !trimmed.hasPrefix("Thought for ") &&
                   !trimmed.hasPrefix("∴ Thought")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
        return Self.cleanHermesOutput(accumulated)
    }

    /// Context-aware turn orchestrator: decides which candidate bot(s) should speak given the conversation context and user message
    public func resolveRespondingBots(
        transcript: [String],
        userMessage: String,
        candidateBots: [(name: String, instructions: String)],
        provider: String,
        model: String
    ) async throws -> [String] {
        guard candidateBots.count > 1 else {
            return candidateBots.map { $0.name }
        }

        let botListDesc = candidateBots.map { "- \($0.name): \($0.instructions.isEmpty ? "AI Assistant" : String($0.instructions.prefix(120)))" }.joined(separator: "\n")
        let transcriptContext = transcript.suffix(6).joined(separator: "\n\n")

        let prompt = """
        You are a multi-agent conversation orchestrator.
        Available candidate bots:
        \(botListDesc)

        Recent conversation:
        \(transcriptContext.isEmpty ? "(No previous messages)" : transcriptContext)

        User's latest message:
        "\(userMessage)"

        Task: Determine which bot(s) should speak in response to the user's latest message and in what order.
        Principles:
        - If the user addresses or asks a specific bot exclusively (e.g. "@Kiara tell me this only", or "@Kiara what is X?"), select ONLY that bot.
        - If the user asks one bot to delegate/hand off a task to another bot (e.g. "BotA, ask @BotB to write a poem"), include the delegating bot and/or the delegated bot in execution order.
        - If the user cites what one bot said to ask others (e.g. "@Kiara said X, what do you think?"), select the other relevant bot(s).
        - If addressing multiple bots or the group generally, select the relevant bots that should respond.

        Respond with a JSON array of exact bot names ONLY, for example ["Kiara"] or ["Jarvis", "Kiara"].
        """

        do {
            let raw = try await executeRawChat(prompt: prompt, provider: provider, model: model)
            guard let start = raw.firstIndex(of: "["),
                  let end = raw.lastIndex(of: "]"), start <= end,
                  let data = raw[start...end].data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data),
                  !names.isEmpty else {
                let mentioned = candidateBots.map { $0.name }.filter { userMessage.localizedCaseInsensitiveContains("@" + $0) }
                return mentioned.isEmpty ? candidateBots.map { $0.name } : mentioned
            }

            var validated = [String]()
            for name in names {
                if let match = candidateBots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    if !validated.contains(match.name) {
                        validated.append(match.name)
                    }
                }
            }
            return validated.isEmpty ? candidateBots.map { $0.name } : validated
        } catch {
            let mentioned = candidateBots.map { $0.name }.filter { userMessage.localizedCaseInsensitiveContains("@" + $0) }
            return mentioned.isEmpty ? candidateBots.map { $0.name } : mentioned
        }
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
        You are \(botName), an AI assistant. \(botInstructions)
        \(contextMemory.isEmpty ? "" : "User Profile & Memory Context:\n" + contextMemory + "\n\n")
        Always remember: You are \(botName) (the assistant). The person speaking to you is the human User.
        Respond directly, helpfully, and concisely. Never output internal thought processes, meta-descriptions, or reasoning preambles.

        User:
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

        let cleaned = Self.cleanHermesOutput(accumulated)
        if process.terminationStatus != 0 && cleaned.isEmpty {
            throw FridayError.message("Inference failed: " + errText)
        }

        return cleaned
    }
}
