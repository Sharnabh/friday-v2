import Foundation

public enum OpenRouterCatalogDefaults {
    public static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=all")!

    public static let roleChains: [ModelRole: [String]] = [
        .orchestrator: [
            "nvidia/nemotron-3-ultra-550b-a55b:free",
            "baidu/ernie-5.5-flash-preview:free"
        ],
        .fastChat: [
            "nvidia/nemotron-3.5-lightning:free",
            "google/gemma-4-26b-a4b-it:free",
            "baidu/ernie-5.5-flash-preview:free"
        ],
        .coding: [
            "particle-ai/particle-1:free",
            "baidu/ernie-5.5-flash-preview:free",
            "nvidia/nemotron-3-ultra-550b-a55b:free"
        ],
        .vision: [
            "nvidia/nemotron-3.5-super-vl:free",
            "google/gemma-4-26b-a4b-it:free"
        ],
        .decisions: [
            "perplexity/pplx-decider-v1.3:free",
            "perplexity/pplx-decider-flash-v1.3:free",
            "respan/span-01-lite:free"
        ],
        .decisionsFast: [
            "perplexity/pplx-decider-flash-v1.3:free",
            "perplexity/pplx-decider-v1.3:free",
            "respan/span-01-lite:free"
        ],
        .embeddings: [
            "nvidia/nemotron-3.5-embed-8b:free",
            "nvidia/nemotron-3.5-embed-1b:free"
        ],
        .rerank: [
            "nvidia/nemotron-3.5-rerank-8b:free"
        ],
        .imageGen: [
            "recraft/recraft-v4.1-flash-v2:free"
        ]
    ]
}

/// Thread-safe registry for OpenRouter models across all modalities, role resolution, fallbacks, and daily quota tracking.
public final class OpenRouterModelRegistry: @unchecked Sendable {
    public static let shared = OpenRouterModelRegistry()

    public typealias CatalogFetcher = @Sendable (URL) async throws -> Data

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let cacheURL: URL
    private let fetcher: CatalogFetcher
    private let nowProvider: @Sendable () -> Date
    private var descriptors: [OpenRouterModelDescriptor] = []
    private var descriptorMap: [String: OpenRouterModelDescriptor] = [:]
    private var cooldowns: [String: Date] = [:]
    private var lastLoadedAt: Date?

    private static let cacheTTL: TimeInterval = 6 * 3600
    private static let usageDateKey = "openrouter.quota.date"
    private static let usageCountKey = "openrouter.quota.count"
    private static let roleOverridePrefix = "openrouter.roleOverride."

    public init(
        defaults: UserDefaults = .standard,
        cacheURL: URL? = nil,
        fetcher: CatalogFetcher? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        let fallbackCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FRIDAY/openrouter_models_cache.json")
        self.cacheURL = cacheURL ?? fallbackCache
        self.nowProvider = nowProvider
        self.fetcher = fetcher ?? { url in
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("Friday", forHTTPHeaderField: "X-Title")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw FridayError.message("OpenRouter model catalog returned HTTP \(code).")
            }
            return data
        }
        loadDiskCache()
    }

    // MARK: - Catalog Parsing & Refresh

    public static func parseCatalogJSON(_ data: Data) throws -> [OpenRouterModelDescriptor] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw FridayError.message("Invalid OpenRouter catalog JSON.")
        }

        return items.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String) ?? id
            let ctx = (row["context_length"] as? Int) ?? 0
            let arch = row["architecture"] as? [String: Any]
            let inputs = (arch?["input_modalities"] as? [String]) ?? []
            let outputs = (arch?["output_modalities"] as? [String]) ?? []
            let params = (row["supported_parameters"] as? [String]) ?? []
            let pricing = row["pricing"] as? [String: Any]
            let isFree = isZeroPriced(id: id, pricing: pricing)
            return OpenRouterModelDescriptor(
                id: id,
                name: name,
                contextLength: ctx,
                inputModalities: inputs,
                outputModalities: outputs,
                supportedParameters: params,
                isFree: isFree
            )
        }
    }

    private static func isZeroPriced(id: String, pricing: [String: Any]?) -> Bool {
        if id.hasSuffix(":free") {
            return true
        }
        guard let pricing else { return false }
        let keysToCheck = ["prompt", "completion", "request", "image", "image_token", "image_output", "web_search", "audio"]
        var sawZeroPrompt = false
        for key in keysToCheck {
            guard let raw = pricing[key] else { continue }
            let val: Double?
            if let d = raw as? Double { val = d }
            else if let i = raw as? Int { val = Double(i) }
            else if let s = raw as? String { val = Double(s.trimmingCharacters(in: .whitespaces)) }
            else { val = nil }
            guard let numeric = val else { return false }
            if numeric > 0 { return false }
            if key == "prompt" { sawZeroPrompt = true }
        }
        return sawZeroPrompt
    }

    @discardableResult
    public func refreshIfNeeded(force: Bool = false) async throws -> [OpenRouterModelDescriptor] {
        if !force, let validCached = freshCachedDescriptors() {
            return validCached
        }
        let data = try await fetcher(OpenRouterCatalogDefaults.catalogURL)
        let parsed = try Self.parseCatalogJSON(data)
        storeRefreshedDescriptors(parsed)
        saveDiskCache(parsed)
        return parsed
    }

    private func freshCachedDescriptors() -> [OpenRouterModelDescriptor]? {
        lock.withLock {
            if !descriptors.isEmpty, let loadedAt = lastLoadedAt,
               nowProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
                return descriptors
            }
            return nil
        }
    }

    private func storeRefreshedDescriptors(_ parsed: [OpenRouterModelDescriptor]) {
        lock.withLock {
            descriptors = parsed
            descriptorMap = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
            lastLoadedAt = nowProvider()
        }
    }

    public func seedDescriptors(_ items: [OpenRouterModelDescriptor]) {
        lock.lock()
        descriptors = items
        descriptorMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        lastLoadedAt = nowProvider()
        lock.unlock()
    }

    public func allModels() -> [OpenRouterModelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return descriptors
    }

    public func freeModels(for role: ModelRole) -> [OpenRouterModelDescriptor] {
        let reqOut = role.requiredOutputModality
        let current = allModels().filter { $0.isFree && $0.outputModalities.contains(reqOut) }
        if role == .vision {
            return current.filter { $0.inputModalities.contains("image") || $0.inputModalities.contains("video") }
        }
        return current
    }

    // MARK: - Role Override & Fallback Chain Resolution

    public func preferredModel(for role: ModelRole) -> String? {
        let val = defaults.string(forKey: Self.roleOverridePrefix + role.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return val.isEmpty ? nil : val
    }

    public func setPreferredModel(_ modelId: String, for role: ModelRole) {
        let clean = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            defaults.removeObject(forKey: Self.roleOverridePrefix + role.rawValue)
        } else {
            defaults.set(clean, forKey: Self.roleOverridePrefix + role.rawValue)
        }
    }

    /// Returns ordered model IDs for a role: user override first, then verified defaults, then dynamically discovered free models for that modality.
    public func candidates(for role: ModelRole, explicitOverride: String? = nil) -> [String] {
        let now = nowProvider()
        lock.lock()
        let map = descriptorMap
        let all = descriptors
        let activeCooldowns = cooldowns.filter { $0.value > now }
        cooldowns = activeCooldowns
        lock.unlock()

        var ordered = [String]()
        func appendUnique(_ id: String?) {
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return }
            if !ordered.contains(id) { ordered.append(id) }
        }

        appendUnique(explicitOverride)
        appendUnique(preferredModel(for: role))
        for defId in OpenRouterCatalogDefaults.roleChains[role] ?? [] {
            appendUnique(defId)
        }

        // Append dynamically discovered free models matching this role's modality (excluding paid/disallowed when catalog present)
        let reqOut = role.requiredOutputModality
        let dynamic = all
            .filter { $0.isFree && $0.outputModalities.contains(reqOut) }
            .filter { role != .vision || $0.inputModalities.contains("image") || $0.inputModalities.contains("video") }
            .sorted { $0.contextLength > $1.contextLength }
        for desc in dynamic.prefix(4) {
            appendUnique(desc.id)
        }

        // If catalog is populated, keep entries that exist in catalog (or explicit overrides)
        let filtered: [String]
        if map.isEmpty {
            filtered = ordered
        } else {
            filtered = ordered.filter { id in
                id == explicitOverride || id == preferredModel(for: role) || map[id] != nil
            }
        }

        let notCooling = filtered.filter { activeCooldowns[$0] == nil }
        return notCooling.isEmpty ? filtered : notCooling
    }

    public func primaryModel(for role: ModelRole, explicitOverride: String? = nil) -> String {
        candidates(for: role, explicitOverride: explicitOverride).first
            ?? OpenRouterCatalogDefaults.roleChains[role]?.first
            ?? "nvidia/nemotron-3-ultra-550b-a55b:free"
    }

    public func markFailure(model: String, statusCode: Int) {
        let duration: TimeInterval
        switch statusCode {
        case 402: duration = 900
        case 429: duration = 60
        case 500...599: duration = 30
        default: duration = 20
        }
        lock.lock()
        cooldowns[model] = nowProvider().addingTimeInterval(duration)
        lock.unlock()
    }

    // MARK: - Daily Free-Variant Usage Counter

    public func recordRequest(isFreeVariant: Bool = true) {
        guard isFreeVariant else { return }
        lock.lock()
        defer { lock.unlock() }
        let today = Self.dayString(nowProvider())
        let storedDay = defaults.string(forKey: Self.usageDateKey)
        let current = (storedDay == today) ? defaults.integer(forKey: Self.usageCountKey) : 0
        defaults.set(today, forKey: Self.usageDateKey)
        defaults.set(current + 1, forKey: Self.usageCountKey)
    }

    public func todayFreeRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let today = Self.dayString(nowProvider())
        guard defaults.string(forKey: Self.usageDateKey) == today else { return 0 }
        return defaults.integer(forKey: Self.usageCountKey)
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: - Disk Cache

    private struct DiskPayload: Codable {
        let savedAt: Date
        let descriptors: [OpenRouterModelDescriptor]
    }

    private func loadDiskCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data),
              !payload.descriptors.isEmpty else { return }
        descriptors = payload.descriptors
        descriptorMap = Dictionary(uniqueKeysWithValues: payload.descriptors.map { ($0.id, $0) })
        lastLoadedAt = payload.savedAt
    }

    private func saveDiskCache(_ items: [OpenRouterModelDescriptor]) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(DiskPayload(savedAt: nowProvider(), descriptors: items)) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
