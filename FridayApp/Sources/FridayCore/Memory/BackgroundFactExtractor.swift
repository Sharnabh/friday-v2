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
        scope: String,
        store: HybridMemoryStore,
        provider: String,
        model: String
    ) {
        Task.detached(priority: .utility) {
            let prompt = """
            Extract any durable user preferences, facts, or entities mentioned in this turn.
            Ignore casual greetings and small talk.
            Output JSON only in this format:
            {
              "facts": ["concise atomic fact sentence"],
              "triples": [{"subject":"EntityA", "predicate":"prefers", "object":"EntityB"}],
              "importance": 7
            }
            If nothing durable was mentioned, return {"facts":[], "triples":[]}.

            User said: "\(userPrompt)"
            Assistant replied: "\(assistantResponse.prefix(400))"
            """

            do {
                let hermes = NSHomeDirectory() + "/.local/bin/hermes"
                var args = ["chat", "--quiet"]
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
                for fact in payload.facts where !fact.trimmingCharacters(in: .whitespaces).isEmpty {
                    try? store.save(fact, scope: scope, source: "Autonomous Extractor", importance: imp, original: nil)
                }

                // 2. Save graph relation triples (GraphRAG)
                for triple in payload.triples {
                    let graphItem = GraphTriple(
                        scope: scope,
                        subject: triple.subject,
                        predicate: triple.predicate,
                        object: triple.object,
                        confidence: 0.95
                    )
                    try? store.saveTriple(graphItem)
                }

                // Invalidate working memory cache on new state
                WorkingMemoryCache.shared.invalidate(scope: scope)

            } catch {
                // Background extraction fails silently without interrupting user
            }
        }
    }
}
