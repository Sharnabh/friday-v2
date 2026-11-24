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
}

/// Asynchronous background fact and graph triple extractor (zero user latency)
public final class BackgroundFactExtractor: Sendable {
    public static let shared = BackgroundFactExtractor()

    private init() {}

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
            Extract any durable facts, personal attributes, or preferences about the USER mentioned in this turn.
            CRITICAL:
            - Distinguish between the human USER and the AI assistant (\(botName)).
            - Never confuse the AI assistant's name (\(botName)) or system identity with the human user.
            - If the user states their own name, attribute it to the User.
            - General user identity facts (like the user's name, email, job, location) should be marked with "scope": "shared".
            - Bot-specific discussion notes should be marked with "scope": "\(scope)".

            Output JSON only in this format:
            {
              "facts": [{"text": "User's name is Sharnabh", "scope": "shared"}],
              "triples": [{"subject":"User", "predicate":"name", "object":"Sharnabh", "scope":"shared"}],
              "importance": 8
            }
            If nothing durable was mentioned, return {"facts":[], "triples":[]}.

            Human User said: "\(userPrompt)"
            AI Assistant (\(botName)) replied: "\(assistantResponse.prefix(400))"
            """

            do {
                let hermes = NSHomeDirectory() + "/.local/bin/hermes"
                var args = ["chat", "--quiet", "--reasoning", "none"]
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

                // 1. Save atomic facts with extracted importance
                let imp = payload.importance ?? 5
                for item in payload.facts {
                    let factText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !factText.isEmpty else { continue }

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

                // 2. Save graph relation triples (GraphRAG)
                for triple in payload.triples {
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
