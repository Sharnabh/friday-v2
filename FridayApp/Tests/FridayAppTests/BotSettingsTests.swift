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

    @MainActor func testPerBotVoicePersistenceAcrossRestart() throws {
        let domain="test.friday.voice."+UUID().uuidString
        let prefs=try XCTUnwrap(UserDefaults(suiteName:domain))
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {prefs.removePersistentDomain(forName:domain);try? FileManager.default.removeItem(at:dir)}

        let state=AppState(defaults:prefs,appSupport:dir,startServices:false)
        state.updateBot(id: "", name: "FRIDAY", instructions: "", voice: "noelle")
        state.createBot(name: "Kiara", instructions: "Direct", voice: "nadine")
        let kiaraId = try XCTUnwrap(state.bots.first(where: { $0.name == "Kiara" })?.id)
        state.createBot(name: "Jarvis", instructions: "Analytical", voice: "gareth")
        let jarvisId = try XCTUnwrap(state.bots.first(where: { $0.name == "Jarvis" })?.id)

        state.setVoiceForBot(id: jarvisId, voice: "lucian")

        let reloaded=AppState(defaults:prefs,appSupport:dir,startServices:false)
        XCTAssertEqual(reloaded.voiceForBot(id: ""), "noelle")
        XCTAssertEqual(reloaded.voiceForBot(id: kiaraId), "nadine")
        XCTAssertEqual(reloaded.voiceForBot(id: jarvisId), "lucian")
    }
}
