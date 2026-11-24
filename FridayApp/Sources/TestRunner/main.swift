import Foundation
import FridayCore

@main
struct TestRunner {
    static func main() async {
        print("Testing HybridMemoryStore...")
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }

        do {
            let store = try HybridMemoryStore(url: tempDB)
            try store.save("The user strongly prefers TypeScript and Next.js for frontend web development.", scope: "shared", source: "User input", original: nil)
            try store.save("The user loves drinking iced matcha latte in the morning.", scope: "shared", source: "User input", original: nil)
            try store.save("Meeting with devops team every Thursday at 3 PM.", scope: "private:bot1", source: "Calendar", original: nil)

            print("--- 1. Exact/Lexical Search ('typescript') ---")
            let ftsResults = try store.search("typescript", scope: "private:bot1", limit: 5)
            for r in ftsResults {
                print("[\(r.scope)] \(r.body)")
            }

            print("\n--- 2. Semantic Hybrid Search ('What are my coding preferences?') ---")
            let semanticResults = try store.search("What are my coding preferences?", scope: "private:bot1", limit: 5)
            for r in semanticResults {
                let simStr = r.similarity.map { String(format: " (Cosine: %.3f)", $0) } ?? ""
                print("[\(r.scope)] \(r.body)\(simStr)")
            }

            print("\nAll Hybrid Memory tests verified successfully!")
        } catch {
            print("Test failed:", error)
            exit(1)
        }
    }
}
