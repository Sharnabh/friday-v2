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

        // 1. Single-valued attribute superseding for User
        let subLower = triple.subject.lowercased()
        let predLower = triple.predicate.lowercased()
        let singleValuedPredicates: Set<String> = [
            "name", "has_name", "first_name", "last_name", "full_name",
            "gender_identity", "gender", "sex",
            "email", "email_address",
            "phone", "phone_number",
            "birth_date", "birthday", "age",
            "occupation", "job_title", "job", "profession", "employer", "company",
            "current_city", "residence", "lives_in", "location", "home_town"
        ]

        if subLower == "user" || subLower == "human", singleValuedPredicates.contains(predLower) {
            var checkExistingStmt: OpaquePointer?
            let isNamePred = predLower == "name" || predLower == "has_name"
            let checkSql = isNamePred
                ? "SELECT id, object FROM graph_triples WHERE scope = ? AND (lower(subject) = 'user' OR lower(subject) = 'human') AND lower(predicate) IN ('name', 'has_name') LIMIT 1"
                : "SELECT id, object FROM graph_triples WHERE scope = ? AND (lower(subject) = 'user' OR lower(subject) = 'human') AND lower(predicate) = ? LIMIT 1"

            if sqlite3_prepare_v2(db, checkSql, -1, &checkExistingStmt, nil) == SQLITE_OK, let checkExistingStmt = checkExistingStmt {
                sqlite3_bind_text(checkExistingStmt, 1, triple.scope, -1, Self.transient)
                if !isNamePred {
                    sqlite3_bind_text(checkExistingStmt, 2, predLower, -1, Self.transient)
                }
                if sqlite3_step(checkExistingStmt) == SQLITE_ROW {
                    let existingId = sqlite3_column_int64(checkExistingStmt, 0)
                    let existingObj = String(cString: sqlite3_column_text(checkExistingStmt, 1))
                    sqlite3_finalize(checkExistingStmt)

                    if existingObj.caseInsensitiveCompare(triple.object) == .orderedSame {
                        return // Same value, deduplicated
                    }

                    // Conflict resolution: supersede old attribute with new object!
                    let now = Date().timeIntervalSince1970
                    try write("UPDATE graph_triples SET predicate = ?, object = ?, confidence = ?, created_at = ? WHERE id = ?",
                              [triple.predicate, triple.object, String(triple.confidence), String(now), String(existingId)])
                    return
                }
                sqlite3_finalize(checkExistingStmt)
            }
        }

        // Deduplication check: do not insert identical triples
        var checkStmt: OpaquePointer?
        let checkSql = "SELECT id FROM graph_triples WHERE scope = ? AND subject = ? AND predicate = ? AND object = ? LIMIT 1"
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK, let checkStmt = checkStmt {
            sqlite3_bind_text(checkStmt, 1, triple.scope, -1, Self.transient)
            sqlite3_bind_text(checkStmt, 2, triple.subject, -1, Self.transient)
            sqlite3_bind_text(checkStmt, 3, triple.predicate, -1, Self.transient)
            sqlite3_bind_text(checkStmt, 4, triple.object, -1, Self.transient)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                sqlite3_finalize(checkStmt)
                return // Triple already exists
            }
            sqlite3_finalize(checkStmt)
        }

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

        // Tokenize query words, filtering common stop words
        let rawTokens = clean.split { !$0.isLetter && !$0.isNumber }.map { String($0) }
        let stopWords: Set<String> = ["what", "is", "a", "an", "the", "and", "or", "in", "on", "at", "to", "for", "of", "with", "do", "you", "tell", "me"]
        var tokens = rawTokens.filter { !stopWords.contains($0) && $0.count >= 2 }
        if tokens.isEmpty {
            tokens = rawTokens
        }
        guard !tokens.isEmpty else { return [] }

        let clauses = tokens.map { _ in "(lower(subject) LIKE ? OR lower(predicate) LIKE ? OR lower(object) LIKE ?)" }
        let whereClause = clauses.joined(separator: " OR ")

        let sql = """
        SELECT id, scope, subject, predicate, object, confidence, created_at
        FROM graph_triples
        WHERE scope IN ('shared', ?)
          AND (\(whereClause))
        ORDER BY id DESC LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        sqlite3_bind_text(stmt, bindIdx, scope, -1, Self.transient)
        bindIdx += 1

        for token in tokens {
            let wildcard = "%\(token)%"
            sqlite3_bind_text(stmt, bindIdx, wildcard, -1, Self.transient)
            sqlite3_bind_text(stmt, bindIdx + 1, wildcard, -1, Self.transient)
            sqlite3_bind_text(stmt, bindIdx + 2, wildcard, -1, Self.transient)
            bindIdx += 3
        }

        sqlite3_bind_int(stmt, bindIdx, Int32(limit))

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
                // 1. Conflict resolution / Superseding: check if an identity memory with the same attribute prefix exists
                let lowerText = text.lowercased()
                let identityPrefixes = [
                    "user's name is", "user is named", "user identifies as a", "the user identifies as a",
                    "user's email is", "user's job is", "user works as", "the user works as",
                    "user lives in", "the user lives in", "user's city is", "user's age is"
                ]

                var supersededId: Int64? = nil
                for prefix in identityPrefixes {
                    if lowerText.hasPrefix(prefix) {
                        var pStmt: OpaquePointer?
                        let pSql = "SELECT rowid FROM memories WHERE scope = ? AND lower(body) LIKE ? LIMIT 1"
                        if sqlite3_prepare_v2(db, pSql, -1, &pStmt, nil) == SQLITE_OK, let pStmt = pStmt {
                            sqlite3_bind_text(pStmt, 1, scope, -1, Self.transient)
                            sqlite3_bind_text(pStmt, 2, "\(prefix)%", -1, Self.transient)
                            if sqlite3_step(pStmt) == SQLITE_ROW {
                                supersededId = sqlite3_column_int64(pStmt, 0)
                            }
                            sqlite3_finalize(pStmt)
                        }
                        if supersededId != nil { break }
                    }
                }

                if let supId = supersededId {
                    // Update/supersede existing attribute memory in-place
                    targetRowid = supId
                    try write("UPDATE memories SET body=?, source=?, revision=? WHERE rowid=?",
                              [text, source, revision, String(supId)])
                    try write("UPDATE memory_metadata SET importance=?, last_accessed_at=? WHERE rowid=?",
                              [String(importance), String(now), String(supId)])
                } else {
                    // Deduplication check: if memory text already exists in this scope, update timestamp/importance and don't duplicate
                    var checkStmt: OpaquePointer?
                    let checkSql = "SELECT rowid FROM memories WHERE scope = ? AND body = ? LIMIT 1"
                    var existingId: Int64? = nil
                    if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK, let checkStmt = checkStmt {
                        sqlite3_bind_text(checkStmt, 1, scope, -1, Self.transient)
                        sqlite3_bind_text(checkStmt, 2, text, -1, Self.transient)
                        if sqlite3_step(checkStmt) == SQLITE_ROW {
                            existingId = sqlite3_column_int64(checkStmt, 0)
                        }
                        sqlite3_finalize(checkStmt)
                    }

                    if let existing = existingId {
                        targetRowid = existing
                        try write("UPDATE memory_metadata SET importance=max(importance, ?), last_accessed_at=? WHERE rowid=?",
                                  [String(importance), String(now), String(existing)])
                    } else {
                        try write("INSERT INTO memories(scope,body,source,revision,pinned) VALUES(?,?,?,?,'0')", args)
                        targetRowid = sqlite3_last_insert_rowid(db)
                        try write("INSERT OR REPLACE INTO memory_metadata(rowid, importance, created_at, last_accessed_at) VALUES(?,?,?,?)",
                                  [String(targetRowid), String(importance), String(now), String(now)])
                    }
                }
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

    public func remove(id: Int64) throws {
        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE")
        do {
            try write("DELETE FROM memories WHERE rowid=?", [String(id)])
            try write("DELETE FROM memory_vectors WHERE rowid=?", [String(id)])
            try write("DELETE FROM memory_metadata WHERE rowid=?", [String(id)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func deleteTriple(id: Int64) throws {
        lock.lock()
        defer { lock.unlock() }

        try write("DELETE FROM graph_triples WHERE id=?", [String(id)])
    }

    public func listTriples(scope: String = "all", limit: Int = 100) throws -> [GraphTriple] {
        lock.lock()
        defer { lock.unlock() }

        var sql = "SELECT id, scope, subject, predicate, object, confidence, created_at FROM graph_triples"
        var args = [String]()

        if scope == "all" {
            sql += " ORDER BY id DESC LIMIT ?"
            args.append(String(limit))
        } else if scope == "shared" {
            sql += " WHERE scope = 'shared' ORDER BY id DESC LIMIT ?"
            args.append(String(limit))
        } else {
            sql += " WHERE scope IN ('shared', ?) ORDER BY id DESC LIMIT ?"
            args.append(scope)
            args.append(String(limit))
        }

        let stmt = try statement(sql, args)
        defer { sqlite3_finalize(stmt) }

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

    public func clearAll(scope: String = "all") throws {
        lock.lock()
        defer { lock.unlock() }

        try exec("BEGIN IMMEDIATE")
        do {
            if scope == "all" {
                try exec("""
                DELETE FROM memories;
                DELETE FROM memory_vectors;
                DELETE FROM memory_metadata;
                DELETE FROM graph_triples;
                """)
            } else if scope == "shared" {
                try exec("""
                DELETE FROM memory_vectors WHERE rowid IN (SELECT rowid FROM memories WHERE scope = 'shared');
                DELETE FROM memory_metadata WHERE rowid IN (SELECT rowid FROM memories WHERE scope = 'shared');
                DELETE FROM memories WHERE scope = 'shared';
                DELETE FROM graph_triples WHERE scope = 'shared';
                """)
            } else {
                try write("""
                DELETE FROM memory_vectors WHERE rowid IN (SELECT rowid FROM memories WHERE scope = ?);
                DELETE FROM memory_metadata WHERE rowid IN (SELECT rowid FROM memories WHERE scope = ?);
                DELETE FROM memories WHERE scope = ?;
                DELETE FROM graph_triples WHERE scope = ?;
                """, [scope, scope, scope, scope])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func deleteMatching(topic: String, scope: String = "all") throws -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let clean = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return [] }

        // Find matching memories
        var selectSql = "SELECT m.rowid, m.body FROM memories m WHERE (lower(m.body) LIKE ?"
        let wildcard = "%\(clean)%"
        var args = [wildcard]
        if scope != "all" {
            selectSql += " AND m.scope IN ('shared', ?))"
            args.append(scope)
        } else {
            selectSql += ")"
        }

        let stmt = try statement(selectSql, args)
        defer { sqlite3_finalize(stmt) }

        var matchingIds = [Int64]()
        var matchingBodies = [String]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let body = String(cString: sqlite3_column_text(stmt, 1))
            matchingIds.append(id)
            matchingBodies.append(body)
        }

        // Delete matched memories & corresponding vectors/metadata
        try exec("BEGIN IMMEDIATE")
        do {
            for id in matchingIds {
                try write("DELETE FROM memories WHERE rowid=?", [String(id)])
                try write("DELETE FROM memory_vectors WHERE rowid=?", [String(id)])
                try write("DELETE FROM memory_metadata WHERE rowid=?", [String(id)])
            }

            // Delete matching graph triples
            var tripleSql = "DELETE FROM graph_triples WHERE (lower(subject) LIKE ? OR lower(predicate) LIKE ? OR lower(object) LIKE ?)"
            var tripleArgs = [wildcard, wildcard, wildcard]
            if scope != "all" {
                tripleSql += " AND scope IN ('shared', ?)"
                tripleArgs.append(scope)
            }
            try write(tripleSql, tripleArgs)

            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return matchingBodies
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
        """
        var args = [String]()
        if scope == "all" {
            sql += " WHERE 1=1"
        } else if scope == "shared" {
            sql += " WHERE m.scope = 'shared'"
        } else {
            sql += " WHERE m.scope IN ('shared', ?)"
            args.append(scope)
        }
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
        var sql = """
        SELECT m.rowid, m.scope, m.body, m.source, m.revision, 
               COALESCE(d.importance, 5), COALESCE(d.created_at, 0), COALESCE(d.last_accessed_at, 0), v.vector 
        FROM memories m
        JOIN memory_vectors v ON m.rowid = v.rowid
        LEFT JOIN memory_metadata d ON m.rowid = d.rowid
        """
        var args = [String]()
        if scope == "all" {
            sql += " WHERE 1=1"
        } else if scope == "shared" {
            sql += " WHERE m.scope = 'shared'"
        } else {
            sql += " WHERE m.scope IN ('shared', ?)"
            args.append(scope)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, Self.transient)
        }

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
