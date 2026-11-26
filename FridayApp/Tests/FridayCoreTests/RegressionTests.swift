import XCTest
@testable import FridayCore

final class RegressionTests: XCTestCase {
    func withStore(_ check: (HybridMemoryStore) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        try check(HybridMemoryStore(url:dir.appendingPathComponent("test.sqlite")))
    }

    func testForgetRequiresAffirmativeRequest() {
        XCTAssertNil(ForgetRequest.topic(in:"Don't forget my coffee"))
        XCTAssertNil(ForgetRequest.topic(in:"Can you explain what forget my coffee means?"))
        XCTAssertEqual(ForgetRequest.topic(in:"Please forget my coffee"),"coffee")
    }

    func testForgetIsLiteralScopedAndChecksPreview() throws {
        try withStore {store in
            for scope in ["private:a","private:b","shared"] {
                try store.save("Travel discount 5%_OFF",scope:scope,source:"Test",original:nil)
            }
            try store.save("Travel plans",scope:"private:a",source:"Test",original:nil)
            let first = try store.previewForget(topic:"%_",scope:"private:a")
            XCTAssertEqual(first.count,1)
            try store.saveTriple(GraphTriple(scope:"private:a",subject:"Trip",predicate:"discount",object:"5%_OFF",confidence:1))
            XCTAssertThrowsError(try store.forget(topic:"%_",scope:"private:a",approved:first))
            let updated = try store.previewForget(topic:"%_",scope:"private:a")
            XCTAssertEqual(updated.count,2)
            try store.forget(topic:"%_",scope:"private:a",approved:updated)
            XCTAssertEqual(try store.previewForget(topic:"Travel",scope:"private:a").count,1)
            for scope in ["shared","private:b"] {
                XCTAssertEqual(try store.previewForget(topic:"%_",scope:scope).count,1)
            }
        }
    }

    func testClearOnlySelectedScope() throws {
        try withStore {store in
            for scope in ["group:alpha","private:b","shared"] {
                try store.save("Release Thursday",scope:scope,source:"test",original:nil)
                try store.saveTriple(GraphTriple(scope:scope,subject:"Release",predicate:"on",object:"Thursday",confidence:1))
            }
            for scope in ["group:alpha","private:b"] {
                try store.clearAll(scope:scope)
                XCTAssertTrue(try store.previewForget(topic:"Release",scope:scope).isEmpty)
                XCTAssertEqual(try store.previewForget(topic:"Release",scope:"shared").count,2)
            }
        }
    }

    func testDeploymentAnswerRanksFirst() throws {
        try withStore {store in
            try store.save("User develops with Swift, SwiftUI, and Python on macOS.",scope:"shared",source:"test",importance:9,original:nil)
            try store.save("DevOps deployment pipeline is on AWS ECS with Fargate.",scope:"private:bot",source:"test",importance:8,original:nil)
            let hits = try store.search("Where is our deployment pipeline hosted?",scope:"private:bot",limit:3)
            XCTAssertTrue(hits.first?.body.contains("Fargate") == true)
        }
    }

    @MainActor
    func testManualFinishAndWakeCompletion() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".py")
        defer {try? FileManager.default.removeItem(at:script)}
        let helper = """
        import sys, pathlib
        if sys.argv[1]=='manual':
            print('{"state":"Listening"}',flush=True)
            assert sys.stdin.readline()=='\\n'
        pathlib.Path(sys.argv[3]).write_text(sys.argv[1])
        print('{"complete":true}',flush=True)
        """
        try helper.write(to:script,atomically:true,encoding:.utf8)
        let service = VoiceService(launcher:script.path,transcribe:{try String(contentsOf:$0,encoding:.utf8)})
        defer {service.stopCapture()}
        for mode in ["manual","wake"] {
            let done = expectation(description:mode)
            service.onStateUpdate = {state in if state=="Listening" {service.finishCapture()}}
            service.onTranscriptionComplete = {text in XCTAssertEqual(text,mode);done.fulfill()}
            service.onError = {message in XCTFail(message);done.fulfill()}
            service.startCapture(handsFree:mode=="wake",micDeviceName:"fixture")
            await fulfillment(of:[done],timeout:8)
            XCTAssertFalse(service.isActive)
        }
    }

    func testHeyGenPCMConversionAndSampleRateParsing() {
        XCTAssertEqual(AssistantService.parseOpenRouterSampleRate(contentType: nil), 44100)
        XCTAssertEqual(AssistantService.parseOpenRouterSampleRate(contentType: "audio/pcm;rate=24000"), 24000)
        XCTAssertEqual(AssistantService.parseOpenRouterSampleRate(contentType: "audio/pcm; rate=44100"), 44100)

        // Signed 16-bit little-endian: 0, +16384 (~0.5), -32768 (-1.0)
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x40, 0x00, 0x80]
        let floats = AssistantService.pcm16ToFloat32(Data(bytes))
        XCTAssertEqual(floats.count, 3)
        XCTAssertEqual(floats[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(floats[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(floats[2], -1.0, accuracy: 0.0001)

        let spoken = AssistantService.stripMarkdownForSpeech("**Kiara**: Here is `code`.\n```swift\nlet x = 1\n```")
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertFalse(spoken.contains("`"))
        XCTAssertTrue(spoken.contains("Code block omitted."))
    }
}
