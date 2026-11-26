import Foundation

/// Coordinates optional OpenRouter embeddings and reranking around local SQLite/FTS5 `HybridMemoryStore`
/// without holding database locks across network calls.
public enum HybridMemoryCloudHelper {
    public static func retrieveContext(
        store: HybridMemoryStore,
        query: String,
        scope: String,
        limit: Int = 3,
        embeddingMode: MemoryEmbeddingMode,
        useCloudRerank: Bool,
        client: OpenRouterClient = .shared
    ) async -> (memories: [MemoryEntry], ragSnippets: [String]) {
        var cloudQueryVector: [Float]? = nil
        var embedModelId: String? = nil

        if embeddingMode != .localOnly {
            if let (vecs, usedModel) = try? await client.embed(inputs: [query]),
               let first = vecs.first {
                cloudQueryVector = first
                embedModelId = usedModel
            }
        }

        let candidatePool = useCloudRerank ? max(limit * 5, 15) : limit
        var memories = (try? store.searchWithOptionalCloudVector(
            query,
            cloudQueryVector: embeddingMode == .cloudAll ? cloudQueryVector : nil,
            modelId: embedModelId,
            scope: scope,
            limit: candidatePool
        )) ?? []

        if useCloudRerank, memories.count > 1 {
            let docs = memories.map(\.body)
            if let (ranked, _) = try? await client.rerank(query: query, documents: docs, topN: limit),
               !ranked.isEmpty {
                memories = ranked.compactMap { item in
                    memories.indices.contains(item.index) ? memories[item.index] : nil
                }
            } else {
                memories = Array(memories.prefix(limit))
            }
        } else {
            memories = Array(memories.prefix(limit))
        }

        var ragHits = (try? store.searchRAGDocuments(
            query: query,
            queryVector: cloudQueryVector,
            modelId: embedModelId,
            scope: scope,
            limit: useCloudRerank ? 10 : 3
        )) ?? []

        if useCloudRerank, ragHits.count > 1 {
            let docs = ragHits.map { "\($0.title): \($0.body)" }
            if let (ranked, _) = try? await client.rerank(query: query, documents: docs, topN: 3),
               !ranked.isEmpty {
                ragHits = ranked.compactMap { item in
                    ragHits.indices.contains(item.index) ? ragHits[item.index] : nil
                }
            } else {
                ragHits = Array(ragHits.prefix(3))
            }
        }

        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let ragLines = ragHits.prefix(3).map { hit in
            var remaining = hit.body[...], best = "", score = -1
            while !remaining.isEmpty {
                let excerpt = String(remaining.prefix(1800))
                remaining = remaining.dropFirst(excerpt.count)
                let lower = excerpt.lowercased()
                let matches = words.filter { lower.contains($0) }.count
                if matches > score { best = excerpt; score = matches }
            }
            return "[RAG:\(hit.title.prefix(160))] " + best
        }
        return (memories, ragLines)
    }

    public static func attachCloudEmbeddingToMemoryIfSaved(
        store: HybridMemoryStore,
        scope: String,
        body: String,
        client: OpenRouterClient = .shared
    ) async {
        guard let target = try? store.embeddingTarget(scope: scope, body: body),
              let (vecs, modelId) = try? await client.embed(inputs: [body]),
              let vec = vecs.first else {
            return
        }
        try? store.storeCloudMemoryVector(rowid: target.id, scope: scope, modelId: modelId, vector: vec, revision: target.revision)
    }

    public static func indexDocument(
        store: HybridMemoryStore,
        scope: String,
        title: String,
        body: String,
        mediaType: String = "text",
        sourcePath: String? = nil,
        useCloudEmbedding: Bool,
        client: OpenRouterClient = .shared
    ) async throws -> Int64 {
        var chunks = [(text: String, model: String, vector: [Float]?)]()
        var rest = body[...]
        repeat {
            let chunk = String(rest.prefix(1800))
            rest = rest.dropFirst(chunk.count)
            var model = ""
            var vector: [Float]?
            if useCloudEmbedding, let result = try? await client.embed(inputs: [title + "\n" + chunk]) {
                model = result.1
                vector = result.0.first
            }
            chunks.append((chunk, model, vector))
        } while !rest.isEmpty
        return try store.saveDocumentChunks(chunks, scope: scope, title: title, mediaType: mediaType, sourcePath: sourcePath)
    }
}
