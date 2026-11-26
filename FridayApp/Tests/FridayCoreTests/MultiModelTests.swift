import XCTest
import SQLite3
@testable import FridayCore

final class MultiModelTests: XCTestCase {
    func testParseAllModalitiesCatalogAndFreeFiltering() throws {
        let sampleJSON = """
        {
          "data": [
            {
              "id": "nvidia/nemotron-3-ultra-550b-a55b:free",
              "name": "Nemotron 3 Ultra (free)",
              "context_length": 1000000,
              "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
              "pricing": {"prompt": "0", "completion": "0"}
            },
            {
              "id": "nvidia/nemotron-3.5-super-vl:free",
              "name": "Nemotron 3.5 Super VL (free)",
              "context_length": 1048576,
              "architecture": {"input_modalities": ["text", "image", "video"], "output_modalities": ["text"]},
              "pricing": {"prompt": "0", "completion": "0"}
            },
            {
              "id": "perplexity/pplx-decider-flash-v1.3:free",
              "name": "Perplexity Decider Flash V1.3 (free)",
              "context_length": 262144,
              "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["decisions"]},
              "pricing": {"prompt": "0", "completion": "0"}
            },
            {
              "id": "parallel/decisions-fast",
              "name": "Parallel Paid Per Request",
              "context_length": 128000,
              "architecture": {"input_modalities": ["text"], "output_modalities": ["decisions"]},
              "pricing": {"prompt": "0", "completion": "0", "request": "0.001"}
            },
            {
              "id": "nvidia/nemotron-3.5-embed-8b:free",
              "name": "Nemotron 3.5 Embed 8B (free)",
              "context_length": 32768,
              "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["embeddings"]},
              "pricing": {"prompt": "0", "completion": "0"}
            },
            {
              "id": "nvidia/nemotron-3.5-rerank-8b:free",
              "name": "Nemotron 3.5 Rerank 8B (free)",
              "context_length": 32768,
              "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["rerank"]},
              "pricing": {"prompt": "0", "completion": "0"}
            },
            {
              "id": "recraft/recraft-v4.1-flash-v2:free",
              "name": "Recraft V4.1 Flash V2 (free)",
              "context_length": 65536,
              "architecture": {"input_modalities": ["text"], "output_modalities": ["image"]},
              "pricing": {"prompt": "0", "completion": "0"}
            },
            {
              "id": "recraft/recraft-v4.1-flash-v2",
              "name": "Recraft Paid",
              "context_length": 65536,
              "architecture": {"input_modalities": ["text"], "output_modalities": ["image"]},
              "pricing": {"prompt": "0", "completion": "0", "image_output": "0.0000016"}
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try OpenRouterModelRegistry.parseCatalogJSON(sampleJSON)
        XCTAssertEqual(parsed.count, 8)
        XCTAssertTrue(parsed.first(where: { $0.id == "perplexity/pplx-decider-flash-v1.3:free" })?.isFree == true)
        XCTAssertFalse(parsed.first(where: { $0.id == "parallel/decisions-fast" })?.isFree ?? true)
        XCTAssertFalse(parsed.first(where: { $0.id == "recraft/recraft-v4.1-flash-v2" })?.isFree ?? true)

        let domain = "test.registry." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".json")
        defer { prefs.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: cache) }

        let registry = OpenRouterModelRegistry(defaults: prefs, cacheURL: cache)
        registry.seedDescriptors(parsed)

        XCTAssertEqual(registry.freeModels(for: .decisions).map(\.id), ["perplexity/pplx-decider-flash-v1.3:free"])
        XCTAssertEqual(registry.freeModels(for: .rerank).map(\.id), ["nvidia/nemotron-3.5-rerank-8b:free"])
        XCTAssertEqual(registry.freeModels(for: .embeddings).map(\.id), ["nvidia/nemotron-3.5-embed-8b:free"])
        XCTAssertEqual(registry.freeModels(for: .imageGen).map(\.id), ["recraft/recraft-v4.1-flash-v2:free"])
        XCTAssertEqual(registry.freeModels(for: .vision).map(\.id), ["nvidia/nemotron-3.5-super-vl:free"])
    }

    func testRoleOverrideCooldownAndQuotaCounter() throws {
        let domain = "test.registry.cooldown." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".json")
        defer { prefs.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: cache) }

        let registry = OpenRouterModelRegistry(defaults: prefs, cacheURL: cache)
        registry.setPreferredModel("custom/coder:free", for: .coding)
        let candidates = registry.candidates(for: .coding)
        XCTAssertEqual(candidates.first, "custom/coder:free")
        XCTAssertTrue(candidates.contains("particle-ai/particle-1:free"))

        registry.markFailure(model: "custom/coder:free", statusCode: 429)
        let afterCooldown = registry.candidates(for: .coding)
        XCTAssertEqual(afterCooldown.first, "particle-ai/particle-1:free")

        registry.recordRequest(isFreeVariant: true)
        registry.recordRequest(isFreeVariant: true)
        XCTAssertEqual(registry.todayFreeRequestCount(), 2)
    }

    func testOpenRouterClientAdaptersFallbackAndParsing() async throws {
        let domain = "test.client." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".json")
        let imgDir = FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-imgs")
        defer {
            prefs.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: imgDir)
        }

        let registry = OpenRouterModelRegistry(defaults: prefs, cacheURL: cache)

        actor CallLog {
            var models: [String] = []
            func append(_ m: String) { models.append(m) }
            func all() -> [String] { models }
        }
        let log = CallLog()

        let client = OpenRouterClient(
            registry: registry,
            generatedImagesDir: imgDir,
            apiKeyProvider: { "test-key" },
            transport: { req in
                let path = req.url?.path ?? ""
                let bodyObj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
                let model = (bodyObj["model"] as? String) ?? ""
                await log.append("\(path):\(model)")

                func resp(_ code: Int, _ json: String) -> (Data, HTTPURLResponse) {
                    let r = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                    return (Data(json.utf8), r)
                }

                if path == "/api/alpha/decisions" {
                    if model == "perplexity/pplx-decider-flash-v1.3:free" {
                        return resp(429, #"{"error":"rate limited"}"#)
                    }
                    return resp(200, """
                    {"answers":{"route":{"type":"choice","choice":"active","confidence":0.95,"probabilities":{"active":0.97,"chat":0.03}}}}
                    """)
                } else if path == "/api/v1/embeddings" {
                    // Include leading keepalive whitespace like live OpenRouter
                    return resp(200, "\n\n  " + #"{"data":[{"index":0,"embedding":[0.25,0.5,-0.25]}]}"#)
                } else if path == "/api/v1/rerank" {
                    return resp(200, "\n" + #"{"results":[{"index":1,"relevance_score":0.88},{"index":0,"relevance_score":0.12}]}"#)
                } else if path == "/api/v1/images/generations" {
                    // Minimal WebP RIFF header
                    let webp = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]).base64EncodedString()
                    return resp(200, #"{"data":[{"b64_json":"\#(webp)"}]}"#)
                } else {
                    return resp(200, #"{"choices":[{"message":{"content":"OK from \#(model)"}}]}"#)
                }
            }
        )

        // 1. Decisions with 429 fallback
        let (answers, usedDecider) = try await client.decide(
            fast: true,
            state: ["question": "Read screen"],
            questions: ["route": ["type": "choice", "instructions": "Pick", "criteria": ["active": "a", "chat": "c"]]]
        )
        XCTAssertEqual(usedDecider, "perplexity/pplx-decider-v1.3:free")
        XCTAssertEqual(answers["route"]?.choice, "active")
        XCTAssertEqual(answers["route"]?.confidence ?? 0, 0.95, accuracy: 0.001)

        // 2. Embeddings with leading whitespace keepalive
        let (vecs, usedEmbed) = try await client.embed(inputs: ["hello"])
        XCTAssertEqual(usedEmbed, "nvidia/nemotron-3.5-embed-8b:free")
        XCTAssertEqual(vecs.count, 1)
        XCTAssertEqual(vecs[0], [0.25, 0.5, -0.25])

        // 3. Rerank with leading whitespace keepalive
        let (ranked, usedRerank) = try await client.rerank(query: "capital", documents: ["Berlin", "Paris"], topN: 2)
        XCTAssertEqual(usedRerank, "nvidia/nemotron-3.5-rerank-8b:free")
        XCTAssertEqual(ranked.map(\.index), [1, 0])

        // 4. Image generation (WebP detection + write)
        let img = try await client.generateImage(prompt: "blue icon")
        XCTAssertEqual(img.model, "recraft/recraft-v4.1-flash-v2:free")
        XCTAssertEqual(img.fileURL.pathExtension, "webp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: img.fileURL.path))

        // 5. Chat completion
        let (reply, usedChat) = try await client.chatCompletion(role: .coding, messages: [["role": "user", "content": "hi"]])
        XCTAssertEqual(usedChat, "particle-ai/particle-1:free")
        XCTAssertEqual(reply, "OK from particle-ai/particle-1:free")

        let calls = await log.all()
        XCTAssertTrue(calls.contains("/api/alpha/decisions:perplexity/pplx-decider-flash-v1.3:free"))
        XCTAssertTrue(calls.contains("/api/alpha/decisions:perplexity/pplx-decider-v1.3:free"))
        XCTAssertEqual(registry.todayFreeRequestCount(), 5)
    }

    func testHybridMemoryCloudVectorsDimensionIsolationAndRerank() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("test.rag." + UUID().uuidString)
        let prefsDomain = "test.rag.prefs." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: prefsDomain))
        defer {
            try? FileManager.default.removeItem(at: dir)
            prefs.removePersistentDomain(forName: prefsDomain)
        }

        let dbURL = dir.appendingPathComponent("Memory.sqlite")
        let store = try HybridMemoryStore(url: dbURL)

        // Store two memories (NLEmbedding writes 512-dim local vectors automatically)
        try store.save("User works primarily in Python and FastAPI.", scope: "shared", source: "test", importance: 8, original: nil)
        try store.save("User prefers dark espresso in the morning.", scope: "shared", source: "test", importance: 5, original: nil)

        // Store a 4096-dim-like synthetic vector (say 4 dims) for a cloud embedding alongside local vectors
        if let row1 = try store.latestMemoryRowID(scope: "shared", body: "User works primarily in Python and FastAPI.") {
            try store.storeCloudMemoryVector(rowid: row1, scope: "shared", modelId: "nvidia/nemotron-3.5-embed-8b:free", vector: [1, 0, 0, 0])
        }
        if let row2 = try store.latestMemoryRowID(scope: "shared", body: "User prefers dark espresso in the morning.") {
            try store.storeCloudMemoryVector(rowid: row2, scope: "shared", modelId: "nvidia/nemotron-3.5-embed-8b:free", vector: [0, 1, 0, 0])
        }

        // Different dimension vectors must not crash or mix with 4-dim vectors
        let res = try store.searchWithOptionalCloudVector(
            "coffee",
            cloudQueryVector: [0, 1, 0, 0],
            modelId: "nvidia/nemotron-3.5-embed-8b:free",
            scope: "shared",
            limit: 2
        )
        XCTAssertEqual(res.first?.body, "User prefers dark espresso in the morning.")

        // Index a RAG document and retrieve with mocked OpenRouter embed + rerank
        let registry = OpenRouterModelRegistry(defaults: prefs, cacheURL: dir.appendingPathComponent("reg.json"))
        let mockClient = OpenRouterClient(
            registry: registry,
            generatedImagesDir: dir.appendingPathComponent("imgs"),
            apiKeyProvider: { "test-key" },
            transport: { req in
                let path = req.url?.path ?? ""
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if path == "/api/v1/embeddings" {
                    return (Data(#"{"data":[{"index":0,"embedding":[0.9,0.1,0,0]}]}"#.utf8), resp)
                } else if path == "/api/v1/rerank" {
                    return (Data(#"{"results":[{"index":1,"relevance_score":0.99},{"index":0,"relevance_score":0.20}]}"#.utf8), resp)
                }
                return (Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8), resp)
            }
        )

        _ = try await HybridMemoryCloudHelper.indexDocument(
            store: store,
            scope: "shared",
            title: "Q4 Architecture PDF",
            body: "OpenRouter handles Nemotron and Recraft workloads.",
            mediaType: "pdf",
            useCloudEmbedding: true,
            client: mockClient
        )

        let ctx = await HybridMemoryCloudHelper.retrieveContext(
            store: store,
            query: "OpenRouter Nemotron",
            scope: "shared",
            limit: 2,
            embeddingMode: .cloudAll,
            useCloudRerank: true,
            client: mockClient
        )
        XCTAssertEqual(ctx.memories.count, 2)
        // Mock rerank put index 1 first
        XCTAssertEqual(ctx.memories.first?.body, "User prefers dark espresso in the morning.")
        XCTAssertTrue(ctx.ragSnippets.contains { $0.contains("Q4 Architecture PDF") })
    }

    func testAttachmentsResolveOnlyInsideOwnedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = UUID().uuidString + ".png"
        let file = dir.appendingPathComponent(name)
        try Data([1]).write(to: file)
        XCTAssertNotNil(OpenRouterClient.attachmentURL(name, in: dir))
        XCTAssertNotNil(OpenRouterClient.attachmentURL("/old/mac/generated-images/" + name, in: dir))
        XCTAssertNil(OpenRouterClient.attachmentURL("/private/" + name, in: dir))
        let link = dir.appendingPathComponent(UUID().uuidString + ".png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(OpenRouterClient.attachmentURL(link.lastPathComponent, in: dir))
    }

    func testLateVectorCannotReplaceEditedMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vault.sqlite")
        let store = try HybridMemoryStore(url: url)
        try store.save("First wording", scope: "shared", source: "test", original: nil)
        let old = try XCTUnwrap(store.embeddingTarget(scope: "shared", body: "First wording"))
        let entry = try XCTUnwrap(store.search("First wording", scope: "shared").first)
        try store.save("Second wording", scope: "shared", source: "test", original: entry)
        let new = try XCTUnwrap(store.embeddingTarget(scope: "shared", body: "Second wording"))
        try store.storeCloudMemoryVector(rowid: new.id, scope: "shared", modelId: "current", vector: [1], revision: new.revision)
        try store.storeCloudMemoryVector(rowid: old.id, scope: "shared", modelId: "stale", vector: [1], revision: old.revision)
        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT model_id FROM cloud_memory_vectors", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(stmt, 0).map(String.init(cString:)), "current")
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    func testLocalChatFindsEndOfLongDocument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HybridMemoryStore(url: dir.appendingPathComponent("db"))
        _ = try await HybridMemoryCloudHelper.indexDocument(store: store, scope: "private:a", title: "Notes",
            body: String(repeating: "Ordinary notes. ", count: 2200) + "Zircon deadline", useCloudEmbedding: false)
        let result = await HybridMemoryCloudHelper.retrieveContext(store: store, query: "Zircon", scope: "private:a",
            embeddingMode: .localOnly, useCloudRerank: false)
        XCTAssertTrue(result.ragSnippets.contains { $0.contains("Zircon deadline") })
        XCTAssertLessThan(result.ragSnippets.joined().count, 6000)
    }

    func testMultiModelRouterClassificationAndDeciderRouting() async throws {
        XCTAssertEqual(MultiModelRouter.classifyChatRole(botPreset: .auto, inferred: .coding), .coding)
        XCTAssertEqual(MultiModelRouter.classifyChatRole(botPreset: .auto, inferred: .orchestrator), .orchestrator)
        XCTAssertEqual(MultiModelRouter.classifyChatRole(botPreset: .auto, inferred: nil), .fastChat)
        XCTAssertEqual(MultiModelRouter.classifyChatRole(botPreset: .coding, inferred: .fastChat), .coding)

        let domain = "test.router." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".json")
        defer { prefs.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: cache) }

        let registry = OpenRouterModelRegistry(defaults: prefs, cacheURL: cache)
        let autoCoding = MultiModelRouter.effectiveProviderAndModel(for: .coding, botProvider: "", botModel: "", registry: registry, hasOpenRouterKey: true)
        XCTAssertEqual(autoCoding.provider, "")
        XCTAssertEqual(autoCoding.model, "")

        let pinned = MultiModelRouter.effectiveProviderAndModel(for: .coding, botProvider: "nous", botModel: "custom-model", registry: registry, hasOpenRouterKey: true)
        XCTAssertEqual(pinned.provider, "nous")
        XCTAssertEqual(pinned.model, "custom-model")

        let client = OpenRouterClient(
            registry: registry,
            apiKeyProvider: { "test-key" },
            transport: { req in
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = """
                {"answers":{"source":{"type":"choice","choice":"generateImage","confidence":0.92},"mode":{"type":"choice","choice":"answer","confidence":0.99}}}
                """
                return (Data(body.utf8), resp)
            }
        )
        let route = try await MultiModelRouter.routeQuestion(
            "Draw a minimal geometric mountain logo",
            history: [],
            hasPreviousCapture: false,
            provider: "",
            model: "",
            usePerplexityDecider: true,
            client: client,
            registry: registry
        )
        XCTAssertEqual(route.source, .generateImage)
        XCTAssertEqual(route.mode, .answer)
    }
}
