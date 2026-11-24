import Foundation
import SQLite3
import NaturalLanguage

public final class HybridMemoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let embeddingModel: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw FridayError.message("Could not open the memory database at \(url.path).")
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("""
        PRAGMA journal_mode=WAL;
        BEGIN IMMEDIATE;
        CREATE VIRTUAL TABLE IF NOT EXISTS memories USING fts5(
            scope UNINDEXED,
            body,
            source UNINDEXED,
            revision UNINDEXED,
            pinned UNINDEXED,
            tokenize='porter unicode61'
        );
        CREATE TABLE IF NOT EXISTS memory_vectors (
            rowid INTEGER PRIMARY KEY,
            scope TEXT,
            vector BLOB
        );
        CREATE TABLE IF NOT EXISTS imported (
            scope TEXT PRIMARY KEY
        );
        COMMIT;
        """)
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure()
        }
    }

    private func failure() -> FridayError {
        .message("Memory database error: " + String(cString: sqlite3_errmsg(db)))
    }

    private func statement(_ sql: String, _ args: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        for (i, arg) in args.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, Self.transient) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw failure()
            }
        }
        return stmt
    }

    private func write(_ sql: String, _ args: [String]) throws {
        let stmt = try statement(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    private func encodeVector(_ vector: [Double]) -> Data {
        let floatArray = vector.map { Float($0) }
        return floatArray.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func decodeVector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? (dot / denom) : 0
    }

    public func importNote(_ scope: String, _ note: String) throws {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE")
        do {
            try write("INSERT OR IGNORE INTO imported VALUES(?)", [scope])
            if sqlite3_changes(db) > 0 {
                let revision = UUID().uuidString
                try write("INSERT INTO memories(scope,body,source,revision,pinned) VALUES(?,?,?,?,'1')",
                          [scope, text, "Imported project note", revision])
                let rowid = sqlite3_last_insert_rowid(db)
                if let emb = embeddingModel?.vector(for: text) {
                    try storeVector(rowid: rowid, scope: scope, vector: emb)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func storeVector(rowid: Int64, scope: String, vector: [Double]) throws {
        let blob = encodeVector(vector)
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO memory_vectors(rowid, scope, vector) VALUES(?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, rowid)
        sqlite3_bind_text(stmt, 2, scope, -1, Self.transient)
        _ = blob.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(blob.count), Self.transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    public func save(_ body: String, scope: String, source: String, original: MemoryEntry?) throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FridayError.message("Enter a memory before saving.") }

        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE")
        do {
            let revision = UUID().uuidString
            let args = [scope, text, source, revision]

            let targetRowid: Int64
            if let old = original {
                try write("UPDATE memories SET scope=?,body=?,source=?,revision=? WHERE rowid=? AND revision=?",
                          args + [String(old.id), old.revision])
                guard sqlite3_changes(db) == 1 else {
                    throw FridayError.message("This memory changed. Reopen it before editing.")
                }
                targetRowid = old.id
            } else {
                try write("INSERT INTO memories(scope,body,source,revision,pinned) VALUES(?,?,?,?,'0')", args)
                targetRowid = sqlite3_last_insert_rowid(db)
            }

            if let vector = embeddingModel?.vector(for: text) {
                try storeVector(rowid: targetRowid, scope: scope, vector: vector)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func remove(_ entry: MemoryEntry) throws {
        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE")
        do {
            try write("DELETE FROM memories WHERE rowid=? AND revision=?", [String(entry.id), entry.revision])
            guard sqlite3_changes(db) == 1 else {
                throw FridayError.message("This memory changed. Refresh the search.")
            }
            try write("DELETE FROM memory_vectors WHERE rowid=?", [String(entry.id)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Hybrid Search: Combines BM25 / FTS5 ranking and Sentence Embedding Cosine Similarity via RRF (Reciprocal Rank Fusion)
    public func search(_ query: String, scope: String, limit: Int = 100, pinnedOnly: Bool = false) throws -> [MemoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Lexical Search (FTS5)
        let lexicalResults = try ftsSearch(cleanQuery, scope: scope, limit: limit, pinnedOnly: pinnedOnly)
        
        // If query is empty or pinnedOnly, lexical results (recent / pinned) are sufficient
        if cleanQuery.isEmpty || pinnedOnly || embeddingModel == nil {
            return lexicalResults
        }

        // 2. Semantic Search (Dense Cosine Similarity on Sentence Embeddings)
        guard let queryVector = embeddingModel?.vector(for: cleanQuery)?.map({ Float($0) }) else {
            return lexicalResults
        }

        let vectorResults = try vectorSearch(queryVector, scope: scope, limit: limit)

        // 3. Reciprocal Rank Fusion (RRF)
        // RRF Score = SUM( 1 / (60 + rank_i) )
        var rrfScores = [Int64: Double]()
        var entryMap = [Int64: MemoryEntry]()

        for (rank, entry) in lexicalResults.enumerated() {
            entryMap[entry.id] = entry
            rrfScores[entry.id, default: 0.0] += 1.0 / Double(60 + rank + 1)
        }

        for (rank, entry) in vectorResults.enumerated() {
            entryMap[entry.id] = entry
            rrfScores[entry.id, default: 0.0] += 1.0 / Double(60 + rank + 1)
        }

        let sortedEntries = rrfScores.sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { entryMap[$0.key] }

        return sortedEntries
    }

    private func ftsSearch(_ query: String, scope: String, limit: Int, pinnedOnly: Bool) throws -> [MemoryEntry] {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(32)
        var sql = "SELECT rowid, scope, body, source, revision FROM memories WHERE scope IN ('shared', ?)"
        var args = [scope]
        if pinnedOnly { sql += " AND pinned='1'" }

        if !tokens.isEmpty {
            sql += " AND memories MATCH ? ORDER BY rank, rowid DESC"
            args.append(tokens.map { "\"" + $0 + "\"" }.joined(separator: " OR "))
        } else {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
            sql += " ORDER BY rowid DESC"
        }

        let stmt = try statement(sql + " LIMIT ?", args + [String(limit)])
        defer { sqlite3_finalize(stmt) }

        var rows = [MemoryEntry]()
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            func col(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
            rows.append(MemoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                scope: col(1),
                body: col(2),
                source: col(3),
                revision: col(4)
            ))
        }
    }

    private func vectorSearch(_ queryVector: [Float], scope: String, limit: Int) throws -> [MemoryEntry] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT m.rowid, m.scope, m.body, m.source, m.revision, v.vector 
        FROM memories m
        JOIN memory_vectors v ON m.rowid = v.rowid
        WHERE m.scope IN ('shared', ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, scope, -1, Self.transient)

        var scored = [(entry: MemoryEntry, score: Float)]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let entryScope = String(cString: sqlite3_column_text(stmt, 1))
            let body = String(cString: sqlite3_column_text(stmt, 2))
            let source = String(cString: sqlite3_column_text(stmt, 3))
            let revision = String(cString: sqlite3_column_text(stmt, 4))

            if let blobPtr = sqlite3_column_blob(stmt, 5) {
                let blobBytes = sqlite3_column_bytes(stmt, 5)
                let data = Data(bytes: blobPtr, count: Int(blobBytes))
                let candidateVector = decodeVector(data)
                let sim = cosineSimilarity(queryVector, candidateVector)
                let entry = MemoryEntry(id: rowid, scope: entryScope, body: body, source: source, revision: revision, similarity: Double(sim))
                scored.append((entry, sim))
            }
        }

        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0.entry }
    }
}
