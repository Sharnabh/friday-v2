import Foundation

/// Fast in-memory LRU cache for working memory / active turn facts (<1ms lookup)
public final class WorkingMemoryCache: @unchecked Sendable {
    public static let shared = WorkingMemoryCache()

    private let lock = NSLock()
    private var capacity: Int
    private var cache = [String: [MemoryEntry]]()
    private var keysOrder = [String]()

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    public func get(key: String) -> [MemoryEntry]? {
        lock.lock()
        defer { lock.unlock() }
        guard let items = cache[key] else { return nil }
        if let idx = keysOrder.firstIndex(of: key) {
            keysOrder.remove(at: idx)
            keysOrder.append(key)
        }
        return items
    }

    public func set(key: String, entries: [MemoryEntry]) {
        lock.lock()
        defer { lock.unlock() }
        if cache[key] != nil {
            cache[key] = entries
            if let idx = keysOrder.firstIndex(of: key) {
                keysOrder.remove(at: idx)
                keysOrder.append(key)
            }
        } else {
            if keysOrder.count >= capacity {
                let oldest = keysOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            cache[key] = entries
            keysOrder.append(key)
        }
    }

    public func invalidate(scope: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        keysOrder.removeAll()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        keysOrder.removeAll()
    }
}

/// Asynchronous background fact and graph triple extractor (zero user latency)
public final class BackgroundFactExtractor: Sendable {
    public static let shared = BackgroundFactExtractor()

    private init() {}

    private static func isValidDurableFact(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty || lower.count < 6 { return false }

        // 1. Filter out negative non-facts
        let negativePhrases = [
            "no durable", "not stated", "not mentioned", "nothing mentioned",
            "no facts", "no information", "no personal", "none mentioned",
            "is not stated", "was not stated", "n/a", "none", "unknown", "unspecified"
        ]
        for phrase in negativePhrases {
            if lower.contains(phrase) { return false }
        }
        if lower.hasPrefix("no ") { return false }

        // 2. Filter out conversational actions and turn mechanics
        let ephemeralPhrases = [
            "is speaking with", "speaking to", "talking to", "asked a question",
            "asked this view", "message directed to", "directed to @", "in this turn",
            "user said", "user greeted", "user asked", "addressed to", "wants an answer",
            "in a message directed", "addressed to @"
        ]
        for phrase in ephemeralPhrases {
            if lower.contains(phrase) { return false }
        }

        // 3. Filter out assistant/bot self-descriptions and persona
        if lower.hasPrefix("kiara ") || lower.hasPrefix("jarvis ") || lower.hasPrefix("friday ") ||
           lower.hasPrefix("the bot ") || lower.hasPrefix("the assistant ") || lower.hasPrefix("user's assistant") {
            return false
        }
        let botPhrases = [
            "ai assistant", "hermes agent", "solar mini", "assistant built",
            "assistant helps", "tools for browsing", "file reading", "workflow coordination",
            "assistant identifies", "assistant believes", "kiara believes", "kiara identifies",
            "jarvis believes", "bot believes"
        ]
        for phrase in botPhrases {
            if lower.contains(phrase) { return false }
        }

        // 4. Filter out transient roleplay, banter, and commands
        let roleplayPhrases = [
            "mistress", "slave", "dominate", "submissive", "submission", "subordinate",
            "kink", "roleplay", "bitch", "mercy", "punish", "master"
        ]
        for phrase in roleplayPhrases {
            if lower.contains(phrase) { return false }
        }

        // 5. Must actually anchor to the human user
        let hasUserAnchor = lower.hasPrefix("user") || lower.hasPrefix("the user") ||
                            lower.contains("user's") || lower.contains("user ")
        if !hasUserAnchor {
            return false
        }

        return true
    }

    private static func isValidDurableTriple(_ triple: ExtractedFactPayload.TriplePayload) -> Bool {
        let subLower = triple.subject.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let predLower = triple.predicate.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let objLower = triple.object.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !subLower.isEmpty && !predLower.isEmpty && !objLower.isEmpty else { return false }

        // Subject MUST be the human user
        let validUserSubjects = ["user", "human", "speaker", "person"]
        if !validUserSubjects.contains(subLower) && !subLower.hasPrefix("user") {
            return false
        }

        // Reject bot subjects
        let botSubjects = ["kiara", "jarvis", "friday", "assistant", "bot", "ai"]
        if botSubjects.contains(subLower) { return false }

        // Reject negative objects
        let negativeObjects = ["not stated", "none", "unknown", "n/a", "not mentioned", "unspecified", "nothing"]
        for neg in negativeObjects {
            if objLower == neg || objLower.contains(neg) { return false }
        }

        // Reject ephemeral predicates
        let ephemeralPreds = ["addressed_to", "is_speaking_with", "speaking_with", "directed_to", "talks_to", "greeted", "asked", "said"]
        for ep in ephemeralPreds {
            if predLower.contains(ep) { return false }
        }

        // Reject roleplay terms
        let roleplayTerms = ["slave", "mistress", "submits_to", "dominates", "master", "subordinate"]
        for term in roleplayTerms {
            if predLower.contains(term) || objLower.contains(term) { return false }
        }

        if objLower.contains("assistant") || objLower.contains("hermes") || objLower.contains("turn") {
            return false
        }

        return true
    }

    /// Runs in background after every completed conversation turn to extract atomic facts & graph triples
    public func processTurn(
        userPrompt: String,
        assistantResponse: String,
        botName: String,
        scope: String,
        store: HybridMemoryStore,
        provider: String,
        model: String
    ) {
        Task.detached(priority: .utility) {
            let prompt = """
            [TASK: PERMANENT USER PROFILE FACT EXTRACTION]
            Extract ONLY enduring, permanent facts about the HUMAN USER explicitly stated by the user themselves in their message (e.g. user's name, email, job, city, or long-term preferences).

            STRICT FILTERING RULES:
            1. ONLY extract information that the Human User explicitly stated about themselves.
            2. NEVER extract conversational actions, turn mechanics, or routing (do NOT extract "User asked...", "User spoke to...", "User addressed @...").
            3. NEVER extract facts about the AI assistant, its persona, or its beliefs (do NOT extract what Kiara, Jarvis, or FRIDAY believes or says).
            4. NEVER extract conversational roleplay, jokes, banter, or commands (do NOT extract master/slave, mistress, submission, or dominance roleplay).
            5. NEVER return negative statements (NEVER output "No facts mentioned", "User's name is not stated", or "None").
            6. If no permanent personal facts about the user were explicitly revealed, return {"facts":[], "triples":[]}.

            Output JSON only in this format:
            {
              "facts": [{"text": "User's name is Sharnabh", "scope": "shared"}],
              "triples": [{"subject":"User", "predicate":"name", "object":"Sharnabh", "scope":"shared"}],
              "importance": 8
            }

            Human User said: "\(userPrompt)"
            """

            do {
                let hermes = NSHomeDirectory() + "/.local/bin/hermes"
                var args = ["chat", "--quiet", "--reasoning", "none", "--ignore-rules"]
                if !provider.isEmpty { args += ["--provider", provider] }
                if !model.isEmpty { args += ["--model", model] }
                args += ["-q", prompt]

                let result = try ProcessRunner.run(hermes, args)
                guard let start = result.firstIndex(of: "{"),
                      let end = result.lastIndex(of: "}"), start <= end,
                      let data = result[start...end].data(using: .utf8),
                      let payload = try? JSONDecoder().decode(ExtractedFactPayload.self, from: data) else {
                    return
                }

                // 1. Save validated atomic facts with extracted importance
                let imp = payload.importance ?? 5
                for item in payload.facts {
                    let factText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard Self.isValidDurableFact(factText) else { continue }

                    // Determine scope: if item has explicit scope, use it; otherwise check if it's general user identity
                    let lower = factText.lowercased()
                    let isUserIdentity = lower.contains("user's name") || lower.contains("user is named") ||
                                         lower.contains("user's email") || lower.contains("user's job") ||
                                         lower.contains("user lives in") || lower.contains("user's role") ||
                                         lower.contains("user is a") || lower.hasPrefix("user prefers")

                    let factScope = item.scope ?? (isUserIdentity ? "shared" : scope)
                    try? store.save(factText, scope: factScope, source: "Autonomous Extractor", importance: imp, original: nil)
                    WorkingMemoryCache.shared.invalidate(scope: factScope)
                }

                // 2. Save validated graph relation triples (GraphRAG)
                for triple in payload.triples {
                    guard Self.isValidDurableTriple(triple) else { continue }
                    let subLower = triple.subject.lowercased()
                    let isUserTriple = subLower == "user" || subLower == "human"
                    let tripleScope = triple.scope ?? (isUserTriple ? "shared" : scope)

                    let graphItem = GraphTriple(
                        scope: tripleScope,
                        subject: triple.subject,
                        predicate: triple.predicate,
                        object: triple.object,
                        confidence: 0.95
                    )
                    try? store.saveTriple(graphItem)
                }

                // Invalidate working memory cache on new state
                WorkingMemoryCache.shared.invalidate(scope: scope)
                WorkingMemoryCache.shared.invalidate(scope: "shared")

            } catch {
                // Background extraction fails silently without interrupting user
            }
        }
    }
}
