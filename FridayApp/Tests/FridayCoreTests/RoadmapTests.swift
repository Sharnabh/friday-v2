import XCTest
import SQLite3
@testable import FridayCore

final class RoadmapTests:XCTestCase {
    func testSourceMoveAndIsolation() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=try HybridMemoryStore(url:dir.appendingPathComponent("db"))
        let source=MemoryOrigin(bot:"alpha",session:"meeting",turn:2).encoded
        try store.save("Review is Tuesday",scope:"private:alpha",source:source,original:nil)
        let old=try XCTUnwrap(store.search("review",scope:"private:alpha").first)
        try store.save("Review is Friday",scope:"group:team",source:old.source,original:old)
        let moved=try XCTUnwrap(store.search("review",scope:"group:team").first)
        XCTAssertEqual(moved.body,"Review is Friday")
        XCTAssertEqual(MemoryOrigin.decode(moved.source)?.turn,2)
        XCTAssertTrue(try store.search("review",scope:"private:alpha").isEmpty)
        XCTAssertThrowsError(try store.save("Stale",scope:"shared",source:source,original:old))
    }

    func testSearchAtTenThousandMemories() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("db")
        let store=try HybridMemoryStore(url:url)
        try store.save("Archive note for office stationery",scope:"shared",source:"fixture",original:nil)
        var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK);defer {sqlite3_close(db)}
        // Repeated background documents isolate vector scan cost from model ingestion time.
        let populate="""
        BEGIN;
        WITH RECURSIVE n(i) AS (VALUES(2) UNION ALL SELECT i+1 FROM n WHERE i<9997)
        INSERT INTO memories(rowid,scope,body,source,revision,pinned) SELECT i,'shared','Archive note for office stationery '||i,'fixture',i,'0' FROM n;
        INSERT INTO memory_vectors(rowid,scope,vector) SELECT m.rowid,'shared',v.vector FROM memories m CROSS JOIN memory_vectors v WHERE v.rowid=1 AND m.rowid>1;
        COMMIT;
        """
        XCTAssertEqual(sqlite3_exec(db,populate,nil,nil,nil),SQLITE_OK)
        for (topic,answer) in [("deployment","Fargate"),("workshop","Pune"),("deadline","Thursday")] {
            try store.save(topic+" detail is "+answer,scope:"shared",source:"fixture",original:nil)
        }
        var durations=[Double]()
        for (query,answer) in [("Where is deployment hosted?","Fargate"),("Where is the workshop?","Pune"),("What is the deadline?","Thursday")] {
            let start=Date()
            let rows=try store.search(query,scope:"shared",limit:3)
            durations.append(Date().timeIntervalSince(start)*1000)
            XCTAssertTrue(rows.contains{$0.body.contains(answer)})
        }
        print("10,000 synthetic memories; top-three hits 3/3; query ms:",durations)
    }
}
