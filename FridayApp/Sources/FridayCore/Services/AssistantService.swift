import Foundation
import AVFoundation

public final class AssistantService: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    public static let shared = AssistantService()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let ttsLock = NSLock()
    private var isMuted = false
    private var speechGeneration: Int = 0
    private var activeSpeechTask: Task<Void, Never>?
    private var isPlayingPCM: Bool = false
    private var audioFormatSampleRate: Double = 0
    public var onSpeechError: (@Sendable (String) -> Void)?

    override private init() {
        super.init()
        speechSynthesizer.delegate = self
        audioEngine.attach(playerNode)
    }

    public var isSpeaking: Bool {
        ttsLock.lock()
        let pcmActive = isPlayingPCM
        ttsLock.unlock()
        return speechSynthesizer.isSpeaking || pcmActive
    }

    public var isMutedState: Bool {
        ttsLock.withLock { isMuted }
    }

    @MainActor public func setMuted(_ muted: Bool) {
        ttsLock.lock()
        self.isMuted = muted
        ttsLock.unlock()
        if muted {
            stopSpeaking()
        }
    }

    @MainActor public func speak(_ text: String, voice: String = "", force: Bool = false) {
        speakSequence([(text: text, voice: voice)], force: force)
    }

    @MainActor public func speakSequence(_ items: [(text: String, voice: String)], force: Bool = false) {
        let prepared = items.compactMap { item -> (text: String, voice: String)? in
            let cleaned = Self.stripMarkdownForSpeech(item.text)
            guard !cleaned.isEmpty else { return nil }
            return (text: String(cleaned.prefix(1800)), voice: item.voice.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !prepared.isEmpty else { return }

        ttsLock.lock()
        let muted = isMuted
        if muted && !force {
            ttsLock.unlock()
            return
        }
        speechGeneration += 1
        let gen = speechGeneration
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        isPlayingPCM = false
        ttsLock.unlock()

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        playerNode.stop()

        let task = Task { [weak self] in
            guard let self else { return }
            for item in prepared {
                if Task.isCancelled || !self.isCurrentGeneration(gen) { return }
                let chosenVoice = item.voice
                if !chosenVoice.isEmpty, let apiKey = Self.resolveOpenRouterAPIKey() {
                    do {
                        let (pcmData, sampleRate) = try await Self.fetchHeyGenSpeechPCM(
                            text: item.text,
                            voice: chosenVoice,
                            model: Self.selectedOpenRouterTTSModel(),
                            apiKey: apiKey
                        )
                        if Task.isCancelled || !self.isCurrentGeneration(gen) { return }
                        try await self.playPCMData(pcmData, sampleRate: sampleRate, generation: gen)
                        continue
                    } catch {
                        if Task.isCancelled || !self.isCurrentGeneration(gen) { return }
                        self.onSpeechError?("HeyGen TTS fallback to system voice: \(error.localizedDescription)")
                    }
                }
                if Task.isCancelled || !self.isCurrentGeneration(gen) { return }
                await self.speakWithSystemSynthesizer(item.text, generation: gen)
            }
        }

        ttsLock.lock()
        if speechGeneration == gen {
            activeSpeechTask = task
        } else {
            task.cancel()
        }
        ttsLock.unlock()
    }

    @MainActor public func stopSpeaking() {
        ttsLock.lock()
        speechGeneration += 1
        activeSpeechTask?.cancel()
        activeSpeechTask = nil
        isPlayingPCM = false
        ttsLock.unlock()

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        playerNode.stop()
    }

    private func isCurrentGeneration(_ gen: Int) -> Bool {
        ttsLock.lock()
        defer { ttsLock.unlock() }
        return speechGeneration == gen
    }

    @MainActor private func speakWithSystemSynthesizer(_ text: String, generation: Int) async {
        guard isCurrentGeneration(generation) else { return }
        await MainActor.run {
            guard self.isCurrentGeneration(generation) else { return }
            let utterance = AVSpeechUtterance(string: String(text.prefix(1500)))
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.speechSynthesizer.speak(utterance)
        }
        while !Task.isCancelled && isCurrentGeneration(generation) && speechSynthesizer.isSpeaking {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    public static func selectedOpenRouterTTSModel() -> String {
        let saved = UserDefaults.standard.string(forKey: "friday.openrouterTTSModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? HeyGenTTSCatalog.defaultModel : saved
    }

    public static func hasOpenRouterAPIKey() -> Bool {
        resolveOpenRouterAPIKey() != nil
    }

    public static func resolveOpenRouterAPIKey() -> String? {
        if let custom = SpeechCredential.read(),
           !custom.isEmpty {
            return custom
        }
        if let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return envKey
        }
        let envURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/.env")
        if let rawEnv = try? String(contentsOf: envURL, encoding: .utf8) {
            for line in rawEnv.components(separatedBy: .newlines) {
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if trimmed.hasPrefix("export ") {
                    trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                }
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                if k == "OPENROUTER_API_KEY" {
                    var val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                        val = String(val.dropFirst().dropLast())
                    }
                    if !val.isEmpty { return val }
                }
            }
        }
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/auth.json")
        if let data = try? Data(contentsOf: authURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let providers = root["providers"] as? [String: Any],
               let orProvider = providers["openrouter"] as? [String: Any],
               let key = (orProvider["api_key"] as? String ?? orProvider["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
            if let pool = root["credential_pool"] as? [String: Any],
               let entries = pool["openrouter"] as? [[String: Any]] {
                for entry in entries {
                    if let key = (entry["api_key"] as? String ?? entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !key.isEmpty {
                        return key
                    }
                }
            }
        }
        return nil
    }

    public static func stripMarkdownForSpeech(_ raw: String) -> String {
        var s = raw
        if let fenceRx = try? NSRegularExpression(pattern: "```[\\s\\S]*?```", options: []) {
            s = fenceRx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " Code block omitted. ")
        }
        for sym in ["**", "__", "`", "### ", "## ", "# "] {
            s = s.replacingOccurrences(of: sym, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseOpenRouterSampleRate(contentType: String?) -> Double {
        guard let contentType else { return 44100 }
        if let rx = try? NSRegularExpression(pattern: "rate=(\\d+)", options: [.caseInsensitive]),
           let match = rx.firstMatch(in: contentType, range: NSRange(location: 0, length: (contentType as NSString).length)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: contentType),
           let rate = Double(contentType[range]), rate >= 8000, rate <= 192000 {
            return rate
        }
        return 44100
    }

    public static func pcm16ToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for i in 0..<sampleCount {
                let lo = UInt16(bytes[i * 2])
                let hi = UInt16(bytes[i * 2 + 1]) << 8
                let sample = Int16(bitPattern: lo | hi)
                output[i] = Float(sample) / 32768.0
            }
        }
        return output
    }

    private static func fetchHeyGenSpeechPCM(text: String, voice: String, model: String, apiKey: String) async throws -> (Data, Double) {
        guard let url = URL(string: HeyGenTTSCatalog.speechEndpoint) else {
            throw FridayError.message("Invalid OpenRouter speech URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Friday", forHTTPHeaderField: "X-Title")
        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "pcm"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FridayError.message("Unexpected non-HTTP response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            OpenRouterModelRegistry.shared.markFailure(model: model, statusCode: http.statusCode)
            throw FridayError.message("OpenRouter TTS failed (\(http.statusCode)): \(String(msg.prefix(200)))")
        }
        OpenRouterModelRegistry.shared.recordRequest(isFreeVariant: model.hasSuffix(":free"))
        let sampleRate = parseOpenRouterSampleRate(contentType: http.value(forHTTPHeaderField: "Content-Type"))
        return (data, sampleRate)
    }

    @MainActor private func playPCMData(_ data: Data, sampleRate: Double, generation: Int) async throws {
        let floats = Self.pcm16ToFloat32(data)
        guard !floats.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floats.count)) else {
            throw FridayError.message("Empty or unsupported PCM audio returned by OpenRouter.")
        }
        buffer.frameLength = AVAudioFrameCount(floats.count)
        if let channel = buffer.floatChannelData?[0] {
            floats.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channel.update(from: base, count: floats.count)
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let stateLock = ttsLock
            final class OnceGate: @unchecked Sendable {
                var done = false
            }
            let gate = OnceGate()
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
                stateLock.lock()
                let shouldResume = !gate.done
                if shouldResume { gate.done = true }
                if self?.speechGeneration == generation {
                    self?.isPlayingPCM = false
                }
                stateLock.unlock()
                if shouldResume {
                    continuation.resume(with: result)
                }
            }

            do {
                try startEngineIfNeeded(format: format)
                stateLock.lock()
                guard speechGeneration == generation else {
                    stateLock.unlock()
                    resumeOnce(.success(()))
                    return
                }
                isPlayingPCM = true
                stateLock.unlock()

                playerNode.stop()
                playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    resumeOnce(.success(()))
                }
                playerNode.play()
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }

    private func startEngineIfNeeded(format: AVAudioFormat) throws {
        ttsLock.lock()
        defer { ttsLock.unlock() }
        if abs(audioFormatSampleRate - format.sampleRate) > 1 {
            if audioEngine.isRunning { audioEngine.stop() }
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            audioFormatSampleRate = format.sampleRate
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
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

    /// Strips leading reasoning preambles, self-name labels, and truncates simulated dialogue for other bots
    public static func cleanBotReply(_ raw: String, botName: String, otherBotNames: [String] = []) -> String {
        var text = cleanHermesOutput(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip leading reasoning preambles (e.g. "Let me respond directly...")
        let reasoningPatterns = [
            "^Let me respond directly[^\\n]*[\\.:]?\\s*",
            "^I will respond directly[^\\n]*[\\.:]?\\s*",
            "^Here is what I would say[^\\n]*[\\.:]?\\s*",
            "^Let me address this[^\\n]*[\\.:]?\\s*",
            "^Here is my response[^\\n]*[\\.:]?\\s*",
            "^Sure! Let me answer[^\\n]*[\\.:]?\\s*",
            "^As an AI assistant[^\\n]*[\\.:]?\\s*"
        ]
        for pat in reasoningPatterns {
            if let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (text as NSString).length)
                text = rx.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 2. Strip leading self bot name prefix (e.g. "Kiara:\n" or "**Kiara**:\n" or "Kiara - ")
        let selfEscaped = NSRegularExpression.escapedPattern(for: botName)
        let selfPrefixPattern = "^(\\*\\*|\\[|@)?\(selfEscaped)(\\*\\*|\\])?\\s*[:\\-]\\s*"
        if let rx = try? NSRegularExpression(pattern: selfPrefixPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = rx.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Also handle standalone bot name on its own first line
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(botName) == .orderedSame {
            text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Truncate if the bot simulated a subsequent bot turn in script format
        var earliestCutIndex: String.Index? = nil
        for other in otherBotNames {
            let trimmedOther = other.trimmingCharacters(in: .whitespaces)
            guard !trimmedOther.isEmpty, trimmedOther.caseInsensitiveCompare(botName) != .orderedSame else { continue }

            let otherEscaped = NSRegularExpression.escapedPattern(for: trimmedOther)
            // Matches newline followed by another bot name as a dialogue header (e.g. "\nJarvis:" or "\n**Jarvis**:")
            let pattern = "\\n+(\\*\\*|\\[|@)?\(otherEscaped)(\\*\\*|\\])?\\s*[:\\-]\\s*"
            if let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = text as NSString
                if let match = rx.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
                   let matchRange = Range(match.range, in: text) {
                    if earliestCutIndex == nil || matchRange.lowerBound < earliestCutIndex! {
                        earliestCutIndex = matchRange.lowerBound
                    }
                }
            }
        }

        if let cut = earliestCutIndex {
            text = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runHermesStream(
        args: [String],
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> (output: String, stderr: String, terminationStatus: Int32) {
        let hermesPath = NSHomeDirectory() + "/.local/bin/hermes"
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        process.environment = env
        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let errTask = Task.detached {
            String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let output = try await Task.detached(priority: .userInitiated) {
            var accumulated = ""
            var resultText: String? = nil
            var fallbackPlain = ""
            let outHandle = stdoutPipe.fileHandleForReading

            for try await line in outHandle.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
                   let data = trimmed.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String {
                    if type == "text", let chunk = json["text"] as? String {
                        accumulated += chunk
                        onChunk?(chunk)
                    } else if type == "result", let text = json["text"] as? String {
                        resultText = text
                    }
                } else {
                    if line.hasPrefix("Resume this session with:") || line.hasPrefix("Session: ") || line.hasPrefix("Duration: ") || line.hasPrefix("Messages: ") || line.hasPrefix("▼ Hermes") || line.hasPrefix("session_id: ") || line.hasPrefix("↻ Resumed session") {
                        continue
                    }
                    if resultText == nil && accumulated.isEmpty {
                        fallbackPlain += line + "\n"
                        onChunk?(line + "\n")
                    }
                }
            }

            process.waitUntilExit()
            return resultText ?? (accumulated.isEmpty ? fallbackPlain : accumulated)
        }.value

        let errText = await errTask.value
        return (output, errText, process.terminationStatus)
    }

    /// Executes a clean, direct prompt without artificial wrapper templates
    public func executeRawChat(
        prompt: String,
        provider: String,
        model: String,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var args = ["chat", "--format", "stream-json", "--reasoning", "none", "--ignore-rules"]
        if !provider.isEmpty { args += ["--provider", provider] }
        if !model.isEmpty { args += ["--model", model] }
        args += ["-q", prompt]

        let result = try await runHermesStream(args: args, onChunk: onChunk)
        return Self.cleanHermesOutput(result.output)
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
            let eff = MultiModelRouter.effectiveProviderAndModel(for: .fastChat, botProvider: provider, botModel: model)
            let raw = try await executeRawChat(prompt: prompt, provider: eff.provider, model: eff.model)
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
        history: [String] = [],
        provider: String,
        model: String,
        sessionID: String,
        contextMemory: String,
        botName: String,
        botInstructions: String,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var args = ["chat", "--format", "stream-json", "--reasoning", "none", "--ignore-rules"]
        if !provider.isEmpty { args += ["--provider", provider] }
        if !model.isEmpty { args += ["--model", model] }

        let cleanInstructions = botInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveInstructions = cleanInstructions.isEmpty
            ? "You are a helpful, thoughtful, and intelligent AI assistant."
            : cleanInstructions

        let recentHistory = history.suffix(8).joined(separator: "\n\n")

        let fullPrompt = """
        [SYSTEM DIRECTIVE: STRICT CHARACTER & ROLEPLAY PERSONA]
        You are \(botName).
        Core Identity, Tone, & Instructions:
        \(effectiveInstructions)

        CRITICAL PERSONA RULES:
        1. Embody this persona and tone completely. Every perspective, self-description, opinion, and response you provide must authentically reflect your persona (\(effectiveInstructions)).
        2. When asked about yourself, your background, or your personality, explain who you are through your persona.
        3. NEVER revert to generic corporate assistant boilerplate (do NOT say "I am an AI assistant built to help with research, writing..." or "I have no feelings/opinions/personality").
        4. Speak in the first person ("I") directly as \(botName).
        5. Do not output internal thought commentary, meta-descriptions, or preambles like "Let me respond directly...". Answer directly.
        \(contextMemory.isEmpty ? "" : "\nDurable User Profile & Memory:\n" + contextMemory + "\n")
        \(recentHistory.isEmpty ? "" : "Conversation History so far:\n" + recentHistory + "\n\n")
        User:
        \(prompt)
        """
        args += ["-q", fullPrompt]

        let result = try await runHermesStream(args: args, onChunk: onChunk)
        let cleaned = Self.cleanBotReply(result.output, botName: botName)
        if result.terminationStatus != 0 && cleaned.isEmpty {
            throw FridayError.message("Inference failed: " + result.stderr)
        }

        return cleaned
    }
}
