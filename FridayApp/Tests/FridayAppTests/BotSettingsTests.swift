import XCTest
@testable import FridayApp

final class BotSettingsTests:XCTestCase {
    @MainActor func testSwitchAndRestart() throws {
        let domain="test.friday."+UUID().uuidString
        let prefs=try XCTUnwrap(UserDefaults(suiteName:domain))
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {prefs.removePersistentDomain(forName:domain);try? FileManager.default.removeItem(at:dir)}
        let state=AppState(defaults:prefs,appSupport:dir,startServices:false)
        state.provider="provider-a";state.model="model-a"
        state.selectBot("assistant-b")
        state.provider="provider-b";state.model="model-b"
        state.selectBot("")
        XCTAssertEqual(state.provider,"provider-a");XCTAssertEqual(state.model,"model-a")
        let restart=AppState(defaults:prefs,appSupport:dir,startServices:false)
        restart.selectBot("assistant-b")
        XCTAssertEqual(restart.provider,"provider-b");XCTAssertEqual(restart.model,"model-b")
    }
}
