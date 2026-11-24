import Foundation
import SQLite3
import NaturalLanguage
import Accelerate

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
        CREATE TABLE IF NOT EXISTS memory_metadata (
            rowid INTEGER PRIMARY KEY,
            importance INTEGER DEFAULT 5,
            created_at REAL,
            last_accessed_at REAL
        );
        CREATE TABLE IF NOT EXISTS memory_vectors (
            rowid INTEGER PRIMARY KEY,
            scope TEXT,
            vector BLOB
        );
        CREATE TABLE IF NOT EXISTS graph_triples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scope TEXT,
            subject TEXT,
            predicate TEXT,
            object TEXT,
            confidence REAL DEFAULT 1.0,
            created_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_graph_triples_sub ON graph_triples(scope, subject);
        CREATE INDEX IF NOT EXISTS idx_graph_triples_obj ON graph_triples(scope, object);
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

    /// SIMD-Accelerated Cosine Similarity using Apple Accelerate (vDSP)
    private func vdspCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        let count = vDSP_Length(a.count)
        vDSP_dotpr(a, 1, b, 1, &dot, count)
        vDSP_svesq(a, 1, &normA, count)
        vDSP_svesq(b, 1, &normB, count)
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? (dot / denom) : 0
    }

    // MARK: - Graph Triples (GraphRAG)

    public func saveTriple(_ triple: GraphTriple) throws {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO graph_triples(scope, subject, predicate, object, confidence, created_at)
        VALUES(?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, triple.scope, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, triple.subject, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, triple.predicate, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, triple.object, -1, Self.transient)
        sqlite3_bind_double(stmt, 5, triple.confidence)
        sqlite3_bind_double(stmt, 6, triple.createdAt.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    public func queryTriples(query: String, scope: String, limit: Int = 10) throws -> [GraphTriple] {
        lock.lock()
        defer { lock.unlock() }

        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return [] }

        var stmt: OpaquePointer?
        let sql = """
        SELECT id, scope, subject, predicate, object, confidence, created_at
        FROM graph_triples
        WHERE scope IN ('shared', ?)
          AND (lower(subject) LIKE ? OR lower(predicate) LIKE ? OR lower(object) LIKE ?)
        ORDER BY id DESC LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }

        let wildcard = "%\(clean)%"
        sqlite3_bind_text(stmt, 1, scope, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, wildcard, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, wildcard, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, wildcard, -1, Self.transient)
        sqlite3_bind_int(stmt, 5, Int32(limit))

        var results = [GraphTriple]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sScope = String(cString: sqlite3_column_text(stmt, 1))
            let sub = String(cString: sqlite3_column_text(stmt, 2))
            let pred = String(cString: sqlite3_column_text(stmt, 3))
            let obj = String(cString: sqlite3_column_text(stmt, 4))
            let conf = sqlite3_column_double(stmt, 5)
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

            results.append(GraphTriple(id: id, scope: sScope, subject: sub, predicate: pred, object: obj, confidence: conf, createdAt: created))
        }
        return results
    }

    // MARK: - Save and Invalidation

    public func save(_ body: String, scope: String, source: String, importance: Int = 5, original: MemoryEntry?) throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FridayError.message("Enter a memory before saving.") }

        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE")
        do {
            let revision = UUID().uuidString
            let args = [scope, text, source, revision]

            let targetRowid: Int64
            let now = Date().timeIntervalSince1970
            if let old = original {
                try write("UPDATE memories SET scope=?,body=?,source=?,revision=? WHERE rowid=? AND revision=?",
                          args + [String(old.id), old.revision])
                guard sqlite3_changes(db) == 1 else {
                    throw FridayError.message("This memory changed. Reopen it before editing.")
                }
                targetRowid = old.id
                try write("UPDATE memory_metadata SET importance=?, last_accessed_at=? WHERE rowid=?",
                          [String(importance), String(now), String(old.id)])
            } else {
                try write("INSERT INTO memories(scope,body,source,revision,pinned) VALUES(?,?,?,?,'0')", args)
                targetRowid = sqlite3_last_insert_rowid(db)
                try write("INSERT OR REPLACE INTO memory_metadata(rowid, importance, created_at, last_accessed_at) VALUES(?,?,?,?)",
                          [String(targetRowid), String(importance), String(now), String(now)])
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
            try write("DELETE FROM memory_metadata WHERE rowid=?", [String(entry.id)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Stanford Generative Agents Composite Search

    public func search(_ query: String, scope: String, limit: Int = 100, pinnedOnly: Bool = false) throws -> [MemoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lexicalResults = try ftsSearch(cleanQuery, scope: scope, limit: limit, pinnedOnly: pinnedOnly)

        if cleanQuery.isEmpty || pinnedOnly || embeddingModel == nil {
            return lexicalResults
        }

        guard let queryVector = embeddingModel?.vector(for: cleanQuery)?.map({ Float($0) }) else {
            return lexicalResults
        }

        // SIMD-Accelerated vector search
        let vectorResults = try vdspVectorSearch(queryVector, scope: scope, limit: limit)

        // Composite Stanford Scoring: Score = 0.5 * RRF_Relevance + 0.3 * Recency + 0.2 * Importance
        var compositeMap = [Int64: Double]()
        var entryMap = [Int64: MemoryEntry]()
        let now = Date().timeIntervalSince1970

        for (rank, entry) in lexicalResults.enumerated() {
            entryMap[entry.id] = entry
            let rrfRelevance = 1.0 / Double(60 + rank + 1)
            compositeMap[entry.id, default: 0.0] += 0.5 * rrfRelevance
        }

        for (rank, entry) in vectorResults.enumerated() {
            entryMap[entry.id] = entry
            let rrfRelevance = 1.0 / Double(60 + rank + 1)
            compositeMap[entry.id, default: 0.0] += 0.5 * rrfRelevance
        }

        // Apply Exponential Recency Decay & Importance
        for (id, entry) in entryMap {
            let daysSinceAccess = max(0, (now - entry.lastAccessedAt.timeIntervalSince1970) / 86400.0)
            let recencyScore = exp(-0.05 * daysSinceAccess)
            let normalizedImportance = Double(entry.importance) / 10.0
            compositeMap[id, default: 0.0] += (0.3 * recencyScore) + (0.2 * normalizedImportance)
        }

        let sorted = compositeMap.sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { pair -> MemoryEntry? in
                guard let base = entryMap[pair.key] else { return nil }
                return MemoryEntry(
                    id: base.id,
                    scope: base.scope,
                    body: base.body,
                    source: base.source,
                    revision: base.revision,
                    importance: base.importance,
                    createdAt: base.createdAt,
                    lastAccessedAt: Date(), // Update access time
                    similarity: base.similarity,
                    compositeScore: pair.value
                )
            }

        // Touch last_accessed_at in DB asynchronously/lazily
        if let firstId = sorted.first?.id {
            _ = try? write("UPDATE memory_metadata SET last_accessed_at=? WHERE rowid=?", [String(now), String(firstId)])
        }

        return sorted
    }

    private func ftsSearch(_ query: String, scope: String, limit: Int, pinnedOnly: Bool) throws -> [MemoryEntry] {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(32)
        var sql = """
        SELECT m.rowid, m.scope, m.body, m.source, m.revision, 
               COALESCE(d.importance, 5), COALESCE(d.created_at, 0), COALESCE(d.last_accessed_at, 0)
        FROM memories m
        LEFT JOIN memory_metadata d ON m.rowid = d.rowid
        WHERE m.scope IN ('shared', ?)
        """
        var args = [scope]
        if pinnedOnly { sql += " AND m.pinned='1'" }

        if !tokens.isEmpty {
            sql += " AND memories MATCH ? ORDER BY rank, m.rowid DESC"
            args.append(tokens.map { "\"" + $0 + "\"" }.joined(separator: " OR "))
        } else {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
            sql += " ORDER BY m.rowid DESC"
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
                revision: col(4),
                importance: Int(sqlite3_column_int(stmt, 5)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                lastAccessedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            ))
        }
    }

    private func vdspVectorSearch(_ queryVector: [Float], scope: String, limit: Int) throws -> [MemoryEntry] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT m.rowid, m.scope, m.body, m.source, m.revision, 
               COALESCE(d.importance, 5), COALESCE(d.created_at, 0), COALESCE(d.last_accessed_at, 0), v.vector 
        FROM memories m
        JOIN memory_vectors v ON m.rowid = v.rowid
        LEFT JOIN memory_metadata d ON m.rowid = d.rowid
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
            let importance = Int(sqlite3_column_int(stmt, 5))
            let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let accessed = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))

            if let blobPtr = sqlite3_column_blob(stmt, 8) {
                let blobBytes = sqlite3_column_bytes(stmt, 8)
                let data = Data(bytes: blobPtr, count: Int(blobBytes))
                let candidateVector = decodeVector(data)
                let sim = vdspCosineSimilarity(queryVector, candidateVector)
                let entry = MemoryEntry(
                    id: rowid,
                    scope: entryScope,
                    body: body,
                    source: source,
                    revision: revision,
                    importance: importance,
                    createdAt: created,
                    lastAccessedAt: accessed,
                    similarity: Double(sim)
                )
                scored.append((entry, sim))
            }
        }

        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0.entry }
    }
}
