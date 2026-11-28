import XCTest
@testable import FridayApp
import FridayCore

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

    @MainActor func testMultiModelRoleAndOptInSettingsPersistence() throws {
        let domain="test.friday.multimodel."+UUID().uuidString
        let prefs=try XCTUnwrap(UserDefaults(suiteName:domain))
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {prefs.removePersistentDomain(forName:domain);try? FileManager.default.removeItem(at:dir)}

        let state=AppState(defaults:prefs,appSupport:dir,startServices:false)
        XCTAssertFalse(state.useGeminiForVoice)
        state.voiceModelID = "gemini-3.8-live-extended-thinking"
        XCTAssertFalse(state.isDeciderRoutingEnabled)
        XCTAssertEqual(state.memoryEmbeddingMode, .localOnly)
        XCTAssertFalse(state.isCloudRerankEnabled)

        state.isDeciderRoutingEnabled = true
        state.memoryEmbeddingMode = .multimodalRAG
        state.isCloudRerankEnabled = true
        state.hasOpenRouterCredits = true
        state.createBot(name: "Coder", instructions: "Write Swift", voice: "bram", role: .coding)
        let coderId = try XCTUnwrap(state.bots.first(where: { $0.name == "Coder" })?.id)

        let reloaded=AppState(defaults:prefs,appSupport:dir,startServices:false)
        XCTAssertEqual(reloaded.voiceModelID,"gemini-3.8-live-extended-thinking")
        reloaded.toggleVoiceRecording()
        XCTAssertTrue(reloaded.liveWakePresented)
        XCTAssertTrue(reloaded.isDeciderRoutingEnabled)
        XCTAssertEqual(reloaded.memoryEmbeddingMode, .multimodalRAG)
        XCTAssertTrue(reloaded.isCloudRerankEnabled)
        XCTAssertTrue(reloaded.hasOpenRouterCredits)
        XCTAssertEqual(reloaded.botRole(for: coderId), .coding)
    }

    @MainActor func testTTSEnabledTogglePersistenceAndHeyFridayAutoEnable() throws {
        let domain="test.friday.tts."+UUID().uuidString
        let prefs=try XCTUnwrap(UserDefaults(suiteName:domain))
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {
            AssistantService.shared.setMuted(false)
            prefs.removePersistentDomain(forName:domain)
            try? FileManager.default.removeItem(at:dir)
        }

        let state=AppState(defaults:prefs,appSupport:dir,startServices:false)
        XCTAssertTrue(state.isTTSEnabled)

        state.isTTSEnabled = false
        XCTAssertFalse(state.isTTSEnabled)
        XCTAssertTrue(AssistantService.shared.isMutedState)

        let reloaded=AppState(defaults:prefs,appSupport:dir,startServices:false)
        XCTAssertFalse(reloaded.isTTSEnabled)

        // Turning on Hey Friday must turn TTS on and keep it on
        reloaded.isWakeEnabled = true
        XCTAssertTrue(reloaded.isTTSEnabled)
        XCTAssertFalse(AssistantService.shared.isMutedState)

        reloaded.isTTSEnabled = false
        XCTAssertTrue(reloaded.isTTSEnabled)
        XCTAssertFalse(AssistantService.shared.isMutedState)
    }
}
