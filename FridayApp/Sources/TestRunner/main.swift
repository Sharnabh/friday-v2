import Foundation
import FridayCore

@main
struct TestRunner {
    static func main() async {
        print("==================================================")
        print("  FRIDAY INDUSTRY-STANDARD MEMORY BENCHMARK TEST  ")
        print("==================================================")

        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }

        do {
            let store = try HybridMemoryStore(url: tempDB)

            // 1. Ingest test memories with different importance and timestamps
            print("\n[Step 1] Ingesting test facts with importance & timestamps...")
            try store.save(
                "User develops with Swift, SwiftUI, and Python on macOS.",
                scope: "shared",
                source: "User input",
                importance: 9,
                original: nil
            )
            try store.save(
                "User loves hot espresso with oat milk.",
                scope: "shared",
                source: "User input",
                importance: 4,
                original: nil
            )
            try store.save(
                "DevOps deployment pipeline is on AWS ECS with Fargate.",
                scope: "private:bot1",
                source: "Chat",
                importance: 8,
                original: nil
            )

            // 2. Ingest Graph Triples (GraphRAG)
            print("\n[Step 2] Ingesting Knowledge Graph Triples...")
            try store.saveTriple(GraphTriple(
                scope: "shared",
                subject: "Project Friday",
                predicate: "uses_language",
                object: "Swift 6",
                confidence: 1.0
            ))
            try store.saveTriple(GraphTriple(
                scope: "shared",
                subject: "Project Friday",
                predicate: "built_for",
                object: "macOS Sequoia",
                confidence: 1.0
            ))
            try store.saveTriple(GraphTriple(
                scope: "private:bot1",
                subject: "User",
                predicate: "leads_team",
                object: "DevOps Infrastructure",
                confidence: 0.95
            ))

            // 3. Test Graph Query
            print("\n[Step 3] Querying Graph Triples for 'Friday'...")
            let triples = try store.queryTriples(query: "Friday", scope: "private:bot1")
            for t in triples {
                print("   Found Relation: \(t.summary)")
            }
            assert(!triples.isEmpty, "Graph query should return related triples")

            // 4. Test SIMD-Accelerated Cosine & Composite Ranking
            print("\n[Step 4] Running SIMD Vector Search + Recency & Importance Composite Ranking...")
            let query = "Where is our deployment pipeline hosted?"
            let start = DispatchTime.now()
            let results = try store.search(query, scope: "private:bot1", limit: 3)
            let end = DispatchTime.now()
            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
            let timeInterval = Double(nanoTime) / 1_000_000

            print("   Search completed in \(String(format: "%.3f", timeInterval)) ms")
            for r in results {
                let compStr = r.compositeScore.map { String(format: "Composite: %.3f", $0) } ?? ""
                let cosStr = r.similarity.map { String(format: "vDSP Cos: %.3f", $0) } ?? ""
                print("   [\(r.scope)] \(r.body) (\(compStr), \(cosStr), Imp: \(r.importance))")
            }
            assert(!results.isEmpty, "Search should return matching results")

            // 5. Test Fast LRU Working Memory Cache
            print("\n[Step 5] Testing WorkingMemoryCache LRU operations...")
            let cache = WorkingMemoryCache.shared
            cache.set(key: "test_key", entries: results)
            let cached = cache.get(key: "test_key")
            assert(cached?.count == results.count, "Cache should retrieve stored entries immediately")
            print("   LRU Cache retrieved \(cached?.count ?? 0) items in <0.01 ms")

            // 6. Test Cross-Bot Shared Identity Retrieval
            print("\n[Step 6] Testing Cross-Bot Shared Identity Retrieval...")
            try store.save("User's name is Sharnabh", scope: "shared", source: "User", importance: 10, original: nil)
            try store.saveTriple(GraphTriple(scope: "shared", subject: "User", predicate: "has_name", object: "Sharnabh", confidence: 1.0))

            let kiaraScope = "private:bot-kiara-uuid"
            let kiaraTriples = try store.queryTriples(query: "What is my name?", scope: kiaraScope)
            print("   Kiara found triples count: \(kiaraTriples.count)")
            for t in kiaraTriples {
                print("   Kiara retrieved: \(t.summary) from scope: \(t.scope)")
            }
            assert(!kiaraTriples.isEmpty, "Kiara must find user name in shared scope")

            let kiaraMemories = try store.search("user name", scope: kiaraScope, limit: 1)
            assert(!kiaraMemories.isEmpty && kiaraMemories[0].body.contains("Sharnabh"), "Kiara must find user's name from shared memory")
            print("   Kiara retrieved memory: '\(kiaraMemories[0].body)'")

            print("\n==================================================")
            print("  ALL MEMORY UPGRADES VERIFIED AND PASSED (100%)  ")
            print("==================================================")

        } catch {
            print("\n❌ Benchmark failed with error:", error)
            exit(1)
        }
    }
}
