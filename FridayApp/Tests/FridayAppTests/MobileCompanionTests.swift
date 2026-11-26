import XCTest
@testable import FridayApp

final class MobileCompanionTests: XCTestCase {
    @MainActor func testPairedWorkspaceOverLoopback() async throws {
        let domain = "friday.mobile.test." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { prefs.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: dir) }
        prefs.set(["You\nHello\n\nFRIDAY\nWelcome"], forKey: "transcript.first")
        prefs.set("first", forKey: "fridaySession")
        let state = AppState(defaults: prefs, appSupport: dir, startServices: false)
        let bridge = state.mobileCompanion
        bridge.start(state, port: 0)
        defer { bridge.stop() }
        for _ in 0..<100 where bridge.token.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(bridge.token.isEmpty)
        func request(_ body: [String: String], token: String) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bridge.listeningPort)/v1/workspace")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let denied = try await request(["action": "state"], token: "invalid")
        XCTAssertEqual(denied.0, 401)
        let snapshot = try await request(["action": "state"], token: bridge.token)
        XCTAssertEqual(snapshot.1["turns"] as? [String], ["You\nHello\n\nFRIDAY\nWelcome"])
        let newChat = ["action": "new", "bot": "", "session": "first"]
        let new = try await request(newChat, token: bridge.token)
        XCTAssertNotEqual(new.1["session"] as? String, "first")
        let stale = try await request(newChat, token: bridge.token)
        XCTAssertNotNil(stale.1["error"])
        let selected = try await request(["action":"selectSession","bot":"","session":state.currentSessionId,"id":"first"], token:bridge.token)
        XCTAssertEqual(selected.1["session"] as? String, "first")
    }
}
