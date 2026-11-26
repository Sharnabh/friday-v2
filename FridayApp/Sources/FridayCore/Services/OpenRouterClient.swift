import Foundation
import AppKit

public struct OpenRouterDecisionAnswer: Sendable, Equatable {
    public let type: String
    public let choice: String?
    public let decision: Bool?
    public let confidence: Double
    public let probabilities: [String: Double]
}

public struct OpenRouterRerankResult: Sendable, Equatable {
    public let index: Int
    public let relevanceScore: Double
}

public struct OpenRouterGeneratedImage: Sendable, Equatable {
    public let fileURL: URL
    public let model: String
}

/// Multi-endpoint HTTP client for OpenRouter (chat/vision, decisions, embeddings, rerank, image generation)
/// with automatic `:free` model fallback and cooldown tracking via `OpenRouterModelRegistry`.
public final class OpenRouterClient: @unchecked Sendable {
    public static let shared = OpenRouterClient()

    public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let decisionsURL = URL(string: "https://openrouter.ai/api/alpha/decisions")!
    private static let embeddingsURL = URL(string: "https://openrouter.ai/api/v1/embeddings")!
    private static let rerankURL = URL(string: "https://openrouter.ai/api/v1/rerank")!
    private static let imagesURL = URL(string: "https://openrouter.ai/api/v1/images/generations")!

    private let registry: OpenRouterModelRegistry
    private let transport: HTTPTransport
    private let apiKeyProvider: @Sendable () -> String?
    private let generatedImagesDir: URL

    public static var imagesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FRIDAY/generated-images")
    }

    public static func attachmentURL(_ reference: String, in directory: URL = imagesDirectory) -> URL? {
        let name = (reference as NSString).lastPathComponent
        let file = directory.appendingPathComponent(name)
        guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
              ["png", "jpg", "jpeg", "webp", "gif"].contains(file.pathExtension.lowercased()),
              reference == name || (reference.hasPrefix("/") && (reference as NSString).deletingLastPathComponent.hasSuffix("/generated-images")),
              file.resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().appendingPathComponent(name).standardizedFileURL.path,
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    public init(
        registry: OpenRouterModelRegistry = .shared,
        generatedImagesDir: URL? = nil,
        apiKeyProvider: (@Sendable () -> String?)? = nil,
        transport: HTTPTransport? = nil
    ) {
        self.registry = registry
        let defaultImagesDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FRIDAY/generated-images")
        self.generatedImagesDir = generatedImagesDir ?? defaultImagesDir
        self.apiKeyProvider = apiKeyProvider ?? { AssistantService.resolveOpenRouterAPIKey() }
        self.transport = transport ?? { req in
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FridayError.message("Unexpected non-HTTP response from OpenRouter.")
            }
            return (data, http)
        }
    }

    // MARK: - 1. Chat Completions (Text or Vision)

    public func chatCompletion(
        role: ModelRole,
        messages: [[String: Any]],
        explicitModel: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        timeout: TimeInterval = 45
    ) async throws -> (text: String, usedModel: String) {
        let key = try requireAPIKey()
        let candidates = registry.candidates(for: role, explicitOverride: explicitModel)
        var lastError: Error = FridayError.message("No OpenRouter models available for \(role.displayName).")

        for model in candidates {
            var body: [String: Any] = [
                "model": model,
                "messages": messages
            ]
            if let temperature { body["temperature"] = temperature }
            if let maxTokens { body["max_tokens"] = maxTokens }

            do {
                let data = try await postJSON(url: Self.chatURL, payload: body, apiKey: key, model: model, timeout: timeout)
                guard let root = try JSONSerialization.jsonObject(with: Self.trimmedJSONData(data)) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let msg = first["message"] as? [String: Any] else {
                    throw FridayError.message("Malformed chat completion payload from \(model).")
                }
                let content = extractMessageText(msg["content"])
                return (content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), model)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - 2. Perplexity Decisions (/api/alpha/decisions)

    public func decide(
        fast: Bool = true,
        state: Any,
        questions: [String: [String: Any]],
        explicitModel: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (answers: [String: OpenRouterDecisionAnswer], usedModel: String) {
        let key = try requireAPIKey()
        let role: ModelRole = fast ? .decisionsFast : .decisions
        let candidates = registry.candidates(for: role, explicitOverride: explicitModel)
        var lastError: Error = FridayError.message("No OpenRouter decision models available.")

        for model in candidates {
            let body: [String: Any] = [
                "model": model,
                "state": state,
                "questions": questions
            ]
            do {
                let data = try await postJSON(url: Self.decisionsURL, payload: body, apiKey: key, model: model, timeout: timeout)
                let answers = try Self.parseDecisionsResponse(data)
                return (answers, model)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parseDecisionsResponse(_ data: Data) throws -> [String: OpenRouterDecisionAnswer] {
        guard let root = try JSONSerialization.jsonObject(with: trimmedJSONData(data)) as? [String: Any],
              let rawAnswers = root["answers"] as? [String: [String: Any]] else {
            throw FridayError.message("Malformed OpenRouter decisions response.")
        }
        var parsed = [String: OpenRouterDecisionAnswer]()
        for (qKey, obj) in rawAnswers {
            let type = (obj["type"] as? String) ?? "choice"
            let choice = obj["choice"] as? String
            let decision = obj["decision"] as? Bool ?? obj["answer"] as? Bool
            let confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0.0
            var probs = [String: Double]()
            if let rawProbs = obj["probabilities"] as? [String: Any] {
                for (k, v) in rawProbs {
                    if let num = (v as? NSNumber)?.doubleValue {
                        probs[k] = num
                    }
                }
            }
            parsed[qKey] = OpenRouterDecisionAnswer(
                type: type,
                choice: choice,
                decision: decision,
                confidence: confidence,
                probabilities: probs
            )
        }
        return parsed
    }

    // MARK: - 3. Multimodal Embeddings (/api/v1/embeddings)

    public func embed(
        inputs: [String],
        explicitModel: String? = nil,
        timeout: TimeInterval = 25
    ) async throws -> (vectors: [[Float]], usedModel: String) {
        guard !inputs.isEmpty else { return ([], "") }
        let key = try requireAPIKey()
        let candidates = registry.candidates(for: .embeddings, explicitOverride: explicitModel)
        var lastError: Error = FridayError.message("No OpenRouter embedding models available.")

        for model in candidates {
            let body: [String: Any] = [
                "model": model,
                "input": inputs.count == 1 ? inputs[0] : inputs
            ]
            do {
                let data = try await postJSON(url: Self.embeddingsURL, payload: body, apiKey: key, model: model, timeout: timeout)
                let vectors = try Self.parseEmbeddingsResponse(data)
                return (vectors, model)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parseEmbeddingsResponse(_ data: Data) throws -> [[Float]] {
        guard let root = try JSONSerialization.jsonObject(with: trimmedJSONData(data)) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            throw FridayError.message("Malformed OpenRouter embeddings response.")
        }
        let sorted = rows.sorted {
            (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0)
        }
        return try sorted.map { row in
            guard let rawVec = row["embedding"] as? [NSNumber], !rawVec.isEmpty else {
                throw FridayError.message("Empty embedding vector returned by OpenRouter.")
            }
            return rawVec.map { $0.floatValue }
        }
    }

    // MARK: - 4. Reranking (/api/v1/rerank)

    public func rerank(
        query: String,
        documents: [String],
        topN: Int? = nil,
        explicitModel: String? = nil,
        timeout: TimeInterval = 25
    ) async throws -> (results: [OpenRouterRerankResult], usedModel: String) {
        guard !documents.isEmpty else { return ([], "") }
        let key = try requireAPIKey()
        let candidates = registry.candidates(for: .rerank, explicitOverride: explicitModel)
        var lastError: Error = FridayError.message("No OpenRouter rerank models available.")

        for model in candidates {
            var body: [String: Any] = [
                "model": model,
                "query": query,
                "documents": documents
            ]
            if let topN { body["top_n"] = max(1, min(topN, documents.count)) }
            do {
                let data = try await postJSON(url: Self.rerankURL, payload: body, apiKey: key, model: model, timeout: timeout)
                let results = try Self.parseRerankResponse(data)
                return (results, model)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parseRerankResponse(_ data: Data) throws -> [OpenRouterRerankResult] {
        guard let root = try JSONSerialization.jsonObject(with: trimmedJSONData(data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw FridayError.message("Malformed OpenRouter rerank response.")
        }
        return results.compactMap { item in
            guard let index = item["index"] as? Int,
                  let score = (item["relevance_score"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return OpenRouterRerankResult(index: index, relevanceScore: score)
        }.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    // MARK: - 5. Image Generation (/api/v1/images/generations)

    public func generateImage(
        prompt: String,
        aspectRatio: String? = nil,
        background: String? = nil,
        explicitModel: String? = nil,
        timeout: TimeInterval = 45
    ) async throws -> OpenRouterGeneratedImage {
        let key = try requireAPIKey()
        let candidates = registry.candidates(for: .imageGen, explicitOverride: explicitModel)
        var lastError: Error = FridayError.message("No OpenRouter image generation models available.")

        for model in candidates {
            var body: [String: Any] = [
                "model": model,
                "prompt": prompt,
                "n": 1
            ]
            if let aspectRatio, !aspectRatio.isEmpty { body["aspect_ratio"] = aspectRatio }
            if let background, !background.isEmpty { body["background"] = background }

            do {
                let data = try await postJSON(url: Self.imagesURL, payload: body, apiKey: key, model: model, timeout: timeout)
                let imageBytes = try await extractGeneratedImageBytes(from: data)
                try FileManager.default.createDirectory(at: generatedImagesDir, withIntermediateDirectories: true)
                let ext = Self.sniffImageExtension(imageBytes)
                let fileURL = generatedImagesDir.appendingPathComponent(UUID().uuidString + "." + ext)
                try imageBytes.write(to: fileURL, options: .atomic)
                return OpenRouterGeneratedImage(fileURL: fileURL, model: model)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func extractGeneratedImageBytes(from data: Data) async throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: Self.trimmedJSONData(data)) as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let first = items.first else {
            throw FridayError.message("Malformed image generation response from OpenRouter.")
        }
        if let b64 = first["b64_json"] as? String,
           let raw = Data(base64Encoded: b64) {
            return raw
        }
        if let urlStr = first["url"] as? String, let url = URL(string: urlStr) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 25
            let (imgData, resp) = try await transport(req)
            guard (200..<300).contains(resp.statusCode), !imgData.isEmpty else {
                throw FridayError.message("Failed to download generated image (\(resp.statusCode)).")
            }
            return imgData
        }
        throw FridayError.message("Image payload did not include base64 data or URL.")
    }

    public static func sniffImageExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        return "png"
    }

    // MARK: - Helpers

    private func requireAPIKey() throws -> String {
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw FridayError.message("OpenRouter API key missing. Add OPENROUTER_API_KEY in Tools & workspaces or ~/.hermes/.env.")
        }
        return key
    }

    private func postJSON(
        url: URL,
        payload: [String: Any],
        apiKey: String,
        model: String,
        timeout: TimeInterval
    ) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Friday", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await transport(req)
        let isFree = model.hasSuffix(":free")
        if (200..<300).contains(http.statusCode) {
            registry.recordRequest(isFreeVariant: isFree)
            return data
        }
        registry.markFailure(model: model, statusCode: http.statusCode)
        let bodyText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw FridayError.message("OpenRouter (\(model)) HTTP \(http.statusCode): \(String(bodyText.prefix(240)))")
    }

    /// OpenRouter embeddings and rerank endpoints sometimes prepend keepalive newlines before JSON.
    private static func trimmedJSONData(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.data(using: .utf8) ?? data
    }

    private func extractMessageText(_ raw: Any?) -> String {
        if let str = raw as? String { return str }
        if let parts = raw as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
