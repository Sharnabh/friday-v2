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
        CREATE TABLE IF NOT EXISTS cloud_memory_vectors (
            rowid INTEGER,
            scope TEXT,
            model_id TEXT,
            dimensions INTEGER,
            vector BLOB,
            PRIMARY KEY(rowid, model_id)
        );
        CREATE TABLE IF NOT EXISTS rag_documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scope TEXT,
            title TEXT,
            body TEXT,
            media_type TEXT,
            source_path TEXT,
            created_at REAL
        );
        CREATE TABLE IF NOT EXISTS rag_vectors (
            doc_id INTEGER PRIMARY KEY,
            scope TEXT,
            model_id TEXT,
            dimensions INTEGER,
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

            try write("DELETE FROM cloud_memory_vectors WHERE rowid=?", [String(targetRowid)])
            try write("DELETE FROM memory_vectors WHERE rowid=?", [String(targetRowid)])
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
            try write("DELETE FROM cloud_memory_vectors WHERE rowid=?", [String(entry.id)])
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
            try write("DELETE FROM cloud_memory_vectors WHERE rowid=?", [String(id)])
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
                DELETE FROM cloud_memory_vectors;
                DELETE FROM memory_metadata;
                DELETE FROM graph_triples;
                DELETE FROM rag_vectors;
                DELETE FROM rag_documents;
                """)
            } else if scope == "shared" {
                try exec("""
                DELETE FROM memory_vectors WHERE rowid IN (SELECT rowid FROM memories WHERE scope = 'shared');
                DELETE FROM cloud_memory_vectors WHERE rowid IN (SELECT rowid FROM memories WHERE scope = 'shared');
                DELETE FROM memory_metadata WHERE rowid IN (SELECT rowid FROM memories WHERE scope = 'shared');
                DELETE FROM memories WHERE scope = 'shared';
                DELETE FROM graph_triples WHERE scope = 'shared';
                DELETE FROM rag_vectors WHERE scope = 'shared';
                DELETE FROM rag_documents WHERE scope = 'shared';
                """)
            } else {
                let ids = "SELECT rowid FROM memories WHERE scope=?"
                try write("DELETE FROM memory_vectors WHERE rowid IN (" + ids + ")", [scope])
                try write("DELETE FROM cloud_memory_vectors WHERE rowid IN (" + ids + ")", [scope])
                try write("DELETE FROM memory_metadata WHERE rowid IN (" + ids + ")", [scope])
                try write("DELETE FROM memories WHERE scope=?", [scope])
                try write("DELETE FROM graph_triples WHERE scope=?", [scope])
                try write("DELETE FROM rag_vectors WHERE scope=?", [scope])
                try write("DELETE FROM rag_documents WHERE scope=?", [scope])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public struct ForgetMatch: Equatable, Sendable {
        let table: String
        let id: Int64
        let revision: String
        public let description: String
    }

    private func matches(topic: String, scope: String) throws -> [ForgetMatch] {
        let term = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var rows = [ForgetMatch]()
        for (table, sql) in [
            ("memories", "SELECT rowid, revision, body FROM memories WHERE instr(lower(body),lower(?))>0"),
            ("graph_triples", "SELECT id, scope, subject || ' — ' || predicate || ' — ' || object FROM graph_triples WHERE instr(lower(subject || ' ' || predicate || ' ' || object),lower(?))>0")
        ] {
            let stmt = try statement(sql + " AND scope=? ORDER BY 1", [term,scope])
            defer { sqlite3_finalize(stmt) }
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else {throw failure()}
                rows.append(ForgetMatch(table:table,id:sqlite3_column_int64(stmt,0),
                    revision:String(cString:sqlite3_column_text(stmt,1)),description:String(cString:sqlite3_column_text(stmt,2))))
            }
        }
        return rows
    }

    public func previewForget(topic: String, scope: String) throws -> [ForgetMatch] {
        lock.lock(); defer {lock.unlock()}
        return try matches(topic:topic,scope:scope)
    }

    public func forget(topic: String, scope: String, approved: [ForgetMatch]) throws {
        lock.lock(); defer {lock.unlock()}
        try exec("BEGIN IMMEDIATE")
        do {
            guard try matches(topic:topic,scope:scope) == approved else {
                throw FridayError.message("The matching memories changed. Review them again.")
            }
            for match in approved {
                let id = [String(match.id)]
                if match.table == "memories" {
                    try write("DELETE FROM memory_vectors WHERE rowid=?",id)
                    try write("DELETE FROM cloud_memory_vectors WHERE rowid=?",id)
                    try write("DELETE FROM memory_metadata WHERE rowid=?",id)
                    try write("DELETE FROM memories WHERE rowid=?",id)
                } else {try write("DELETE FROM graph_triples WHERE id=?",id)}
            }
            try exec("COMMIT")
        } catch {try? exec("ROLLBACK"); throw error}
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

        // BM25 order and cosine similarity dominate; age and importance break close ties.
        var compositeMap = [Int64: Double]()
        var entryMap = [Int64: MemoryEntry]()
        let now = Date().timeIntervalSince1970
        for (rank, entry) in lexicalResults.enumerated() {
            entryMap[entry.id] = entry
            compositeMap[entry.id] = 0.60 / Double(rank + 1)
        }
        for entry in vectorResults {
            entryMap[entry.id] = entry
            compositeMap[entry.id, default:0] += 0.35 * max(0, entry.similarity ?? 0)
        }
        for (id, entry) in entryMap {
            let days = max(0, (now - entry.lastAccessedAt.timeIntervalSince1970) / 86400)
            compositeMap[id, default:0] += 0.03 * exp(-0.05 * days) + 0.02 * Double(entry.importance) / 10
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

    // MARK: - Cloud Multimodal Vectors & RAG Document Store

    public func latestMemoryRowID(scope: String, body: String) throws -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try statement("SELECT rowid FROM memories WHERE scope=? AND body=? ORDER BY rowid DESC LIMIT 1", [scope, body])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    public func embeddingTarget(scope: String, body: String) throws -> (id: Int64, revision: String)? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try statement("SELECT rowid,revision FROM memories WHERE scope=? AND body=? ORDER BY rowid DESC LIMIT 1", [scope, body])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? (sqlite3_column_int64(stmt, 0), String(cString: sqlite3_column_text(stmt, 1))) : nil
    }

    public func storeCloudMemoryVector(rowid: Int64, scope: String, modelId: String, vector: [Float], revision: String? = nil) throws {
        guard !vector.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO cloud_memory_vectors(rowid, scope, model_id, dimensions, vector) SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM memories WHERE rowid=? AND scope=? AND (? IS NULL OR revision=?))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        sqlite3_bind_text(stmt, 2, scope, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, modelId, -1, Self.transient)
        sqlite3_bind_int(stmt, 4, Int32(vector.count))
        _ = blob.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blob.count), Self.transient)
        }
        sqlite3_bind_int64(stmt, 6, rowid)
        sqlite3_bind_text(stmt, 7, scope, -1, Self.transient)
        if let revision {
            sqlite3_bind_text(stmt, 8, revision, -1, Self.transient)
            sqlite3_bind_text(stmt, 9, revision, -1, Self.transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    public func searchWithOptionalCloudVector(
        _ query: String,
        cloudQueryVector: [Float]?,
        modelId: String?,
        scope: String,
        limit: Int = 100
    ) throws -> [MemoryEntry] {
        guard let cloudQueryVector, !cloudQueryVector.isEmpty else {
            return try search(query, scope: scope, limit: limit)
        }
        lock.lock()
        defer { lock.unlock() }

        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lexicalResults = try ftsSearch(cleanQuery, scope: scope, limit: limit, pinnedOnly: false)
        let vectorResults = try cloudVectorSearch(cloudQueryVector, modelId: modelId, scope: scope, limit: limit)

        // Blend lexical rank and dimension-safe cloud cosine similarity, falling back cleanly when no cloud rows exist yet.
        if vectorResults.isEmpty {
            if !cleanQuery.isEmpty, let localVec = embeddingModel?.vector(for: cleanQuery)?.map({ Float($0) }) {
                let localResults = try vdspVectorSearch(localVec, scope: scope, limit: limit)
                return mergeRanked(lexical: lexicalResults, vector: localResults, limit: limit)
            }
            return lexicalResults
        }
        return mergeRanked(lexical: lexicalResults, vector: vectorResults, limit: limit)
    }

    private func mergeRanked(lexical: [MemoryEntry], vector: [MemoryEntry], limit: Int) -> [MemoryEntry] {
        var compositeMap = [Int64: Double]()
        var entryMap = [Int64: MemoryEntry]()
        let now = Date().timeIntervalSince1970
        for (rank, entry) in lexical.enumerated() {
            entryMap[entry.id] = entry
            compositeMap[entry.id] = 0.55 / Double(rank + 1)
        }
        for entry in vector {
            entryMap[entry.id] = entry
            compositeMap[entry.id, default: 0] += 0.40 * max(0, entry.similarity ?? 0)
        }
        for (id, entry) in entryMap {
            let days = max(0, (now - entry.lastAccessedAt.timeIntervalSince1970) / 86400)
            compositeMap[id, default: 0] += 0.03 * exp(-0.05 * days) + 0.02 * Double(entry.importance) / 10
        }
        return compositeMap.sorted { $0.value > $1.value }
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
                    lastAccessedAt: base.lastAccessedAt,
                    similarity: base.similarity,
                    compositeScore: pair.value
                )
            }
    }

    private func cloudVectorSearch(_ queryVector: [Float], modelId: String?, scope: String, limit: Int) throws -> [MemoryEntry] {
        var sql = """
        SELECT m.rowid, m.scope, m.body, m.source, m.revision,
               COALESCE(d.importance, 5), COALESCE(d.created_at, 0), COALESCE(d.last_accessed_at, 0), v.vector
        FROM memories m
        JOIN cloud_memory_vectors v ON m.rowid = v.rowid
        LEFT JOIN memory_metadata d ON m.rowid = d.rowid
        WHERE v.dimensions = ?
        """
        var args = [String(queryVector.count)]
        if let modelId, !modelId.isEmpty {
            sql += " AND v.model_id = ?"
            args.append(modelId)
        }
        if scope == "shared" {
            sql += " AND m.scope = 'shared'"
        } else if scope != "all" {
            sql += " AND m.scope IN ('shared', ?)"
            args.append(scope)
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(queryVector.count))
        for (idx, arg) in args.dropFirst().enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 2), arg, -1, Self.transient)
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
                let count = sqlite3_column_bytes(stmt, 8)
                let candidate = decodeVector(Data(bytes: blobPtr, count: Int(count)))
                guard candidate.count == queryVector.count else { continue }
                let sim = vdspCosineSimilarity(queryVector, candidate)
                scored.append((
                    MemoryEntry(
                        id: rowid,
                        scope: entryScope,
                        body: body,
                        source: source,
                        revision: revision,
                        importance: importance,
                        createdAt: created,
                        lastAccessedAt: accessed,
                        similarity: Double(sim)
                    ),
                    sim
                ))
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.entry)
    }

    @discardableResult
    public func saveDocumentChunks(_ chunks: [(text: String, model: String, vector: [Float]?)], scope: String, title: String, mediaType: String, sourcePath: String?) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            var firstID: Int64 = 0
            for chunk in chunks {
                let id = try insertDocument(scope: scope, title: title, body: chunk.text, mediaType: mediaType, sourcePath: sourcePath, modelId: chunk.model, vector: chunk.vector)
                if firstID == 0 { firstID = id }
            }
            try exec("COMMIT")
            return firstID
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func saveRAGDocument(
        scope: String,
        title: String,
        body: String,
        mediaType: String = "text",
        sourcePath: String? = nil,
        modelId: String = "",
        vector: [Float]? = nil
    ) throws -> Int64 {
        try saveDocumentChunks([(body, modelId, vector)], scope: scope, title: title, mediaType: mediaType, sourcePath: sourcePath)
    }

    private func insertDocument(
        scope: String,
        title: String,
        body: String,
        mediaType: String = "text",
        sourcePath: String? = nil,
        modelId: String = "",
        vector: [Float]? = nil
    ) throws -> Int64 {
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "INSERT INTO rag_documents(scope, title, body, media_type, source_path, created_at) VALUES(?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, scope, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, title, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, body, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, mediaType, -1, Self.transient)
        sqlite3_bind_text(stmt, 5, sourcePath ?? "", -1, Self.transient)
        sqlite3_bind_double(stmt, 6, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }

        let docId = sqlite3_last_insert_rowid(db)
        let activeVector: [Float]? = vector ?? embeddingModel?.vector(for: body)?.map { Float($0) }
        let activeModel = vector != nil ? modelId : "apple-nl-embedding"
        if let activeVector, !activeVector.isEmpty {
            let blob = activeVector.withUnsafeBufferPointer { Data(buffer: $0) }
            var vStmt: OpaquePointer?
            let vSql = "INSERT OR REPLACE INTO rag_vectors(doc_id, scope, model_id, dimensions, vector) VALUES(?, ?, ?, ?, ?)"
            if sqlite3_prepare_v2(db, vSql, -1, &vStmt, nil) == SQLITE_OK, let vStmt {
                defer { sqlite3_finalize(vStmt) }
                sqlite3_bind_int64(vStmt, 1, docId)
                sqlite3_bind_text(vStmt, 2, scope, -1, Self.transient)
                sqlite3_bind_text(vStmt, 3, activeModel, -1, Self.transient)
                sqlite3_bind_int(vStmt, 4, Int32(activeVector.count))
                _ = blob.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(vStmt, 5, ptr.baseAddress, Int32(blob.count), Self.transient)
                }
                _ = sqlite3_step(vStmt)
            }
        }
        return docId
    }

    public func searchRAGDocuments(
        query: String,
        queryVector: [Float]?,
        modelId: String?,
        scope: String,
        limit: Int = 10
    ) throws -> [(title: String, body: String, score: Double)] {
        lock.lock()
        defer { lock.unlock() }

        let targetVector = queryVector ?? embeddingModel?.vector(for: query)?.map { Float($0) }
        var sql = """
        SELECT d.title, d.body, v.vector, v.dimensions, v.model_id
        FROM rag_documents d
        LEFT JOIN rag_vectors v ON d.id = v.doc_id
        """
        var args = [String]()
        if scope == "shared" {
            sql += " WHERE d.scope = 'shared'"
        } else if scope != "all" {
            sql += " WHERE d.scope IN ('shared', ?)"
            args.append(scope)
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), a, -1, Self.transient)
        }

        let lowerQ = query.lowercased()
        let terms = lowerQ.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var hits = [(title: String, body: String, score: Double)]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = String(cString: sqlite3_column_text(stmt, 0))
            let body = String(cString: sqlite3_column_text(stmt, 1))
            var score = 0.0
            let hay = (title + " " + body).lowercased()
            if !terms.isEmpty {
                let matched = terms.filter { hay.contains($0) }.count
                score += 0.35 * Double(matched) / Double(terms.count)
            }
            if let targetVector, let blobPtr = sqlite3_column_blob(stmt, 2) {
                let dims = Int(sqlite3_column_int(stmt, 3))
                let vecModel = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let modelOk = vecModel == (queryVector == nil ? "apple-nl-embedding" : modelId)
                if dims == targetVector.count && modelOk {
                    let count = sqlite3_column_bytes(stmt, 2)
                    let vec = decodeVector(Data(bytes: blobPtr, count: Int(count)))
                    score += 0.65 * max(0, Double(vdspCosineSimilarity(targetVector, vec)))
                }
            }
            if score > 0 || lowerQ.isEmpty {
                hits.append((title: title, body: body, score: score))
            }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    public func listRAGDocuments(scope: String, limit: Int = 50) throws -> [(id: Int64, title: String, mediaType: String, createdAt: Date)] {
        lock.lock()
        defer { lock.unlock() }
        var sql = "SELECT id, title, media_type, created_at FROM rag_documents"
        var args = [String]()
        if scope == "shared" {
            sql += " WHERE scope = 'shared'"
        } else if scope != "all" {
            sql += " WHERE scope IN ('shared', ?)"
            args.append(scope)
        }
        sql += " ORDER BY id DESC LIMIT ?"
        let stmt = try statement(sql, args + [String(limit)])
        defer { sqlite3_finalize(stmt) }
        var rows = [(id: Int64, title: String, mediaType: String, createdAt: Date)]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((
                id: sqlite3_column_int64(stmt, 0),
                title: String(cString: sqlite3_column_text(stmt, 1)),
                mediaType: String(cString: sqlite3_column_text(stmt, 2)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        }
        return rows
    }
}
