import Foundation
import AppKit

@MainActor
public final class VoiceService {
    public static let shared = VoiceService()

    private var recorder: Process?
    private var commands: Pipe?
    public var isActive: Bool { recorder != nil }
    private let customLauncher: String?
    private let transcribe: @Sendable (URL) throws -> String

    init(launcher: String? = nil, transcribe: @escaping @Sendable (URL) throws -> String = VoiceService.whisper) {
        self.customLauncher = launcher
        self.transcribe = transcribe
    }

    nonisolated private static func whisper(_ url: URL) throws -> String {
        let local = NSHomeDirectory() + "/.hermes/tools/friday-whisper/"
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Whisper").path
        let dir = bundled.flatMap {FileManager.default.isExecutableFile(atPath:$0+"/whisper-cli") ? $0+"/" : nil} ?? local
        return try ProcessRunner.run(dir+"whisper-cli", ["-m",dir+"ggml-small.en.bin","-f",url.path,"-l","en","-ng","-nt","-np"])
    }
    private var generation = 0

    public var onLevelUpdate: (@MainActor (Double) -> Void)?
    public var onStateUpdate: (@MainActor (String) -> Void)?
    public var onTranscriptionComplete: (@MainActor (String) -> Void)?
    public var onError: (@MainActor (String) -> Void)?

    private var launcherPath: String {
        if let customLauncher {return customLauncher}
        // Look in main bundle or fallback to outputs/Friday.app resources
        return AppResources.path("launch_voice","py")
    }

    public func listMicrophones() -> [String] {
        guard !launcherPath.isEmpty else { return [] }
        guard let result = try? ProcessRunner.run(AppResources.python, [launcherPath, "devices"]),
              let names = try? JSONDecoder().decode([String].self, from: Data(result.utf8)) else {
            return []
        }
        return names
    }

    public func stopCapture() {
        generation += 1

        if let p = recorder, p.isRunning {
            p.terminate()
        }
        recorder = nil
        commands = nil
        onStateUpdate?("Microphone idle")
        onLevelUpdate?(0)
    }

    public func finishCapture() {
        guard let commands else {return}
        self.commands = nil
        do {try commands.fileHandleForWriting.write(contentsOf:Data([10]))}
        catch { if recorder?.isRunning == true {stopCapture(); onError?(error.localizedDescription)} }
    }

    public func startCapture(handsFree: Bool, micDeviceName: String) {
        stopCapture()
        guard !launcherPath.isEmpty else {
            onError?("Voice launcher script missing.")
            return
        }


        let token = generation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")

        let p = Process(), out = Pipe(), control = Pipe()
        p.executableURL = URL(fileURLWithPath: AppResources.python)
        p.arguments = [launcherPath, handsFree ? "wake" : "manual", micDeviceName, url.path]
        p.standardOutput = out
        p.standardInput = control
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {

            onError?(error.localizedDescription)
            return
        }

        self.recorder = p
        self.commands = control
        onStateUpdate?("Starting microphone…")

        Task {
            defer {try? FileManager.default.removeItem(at:url)}
            do {
                var complete = false, issue = ""
                for try await line in out.fileHandleForReading.bytes.lines {
                    guard token == generation else {return}
                    guard let event = (try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any] else {continue}
                    if let value = event["level"] as? Double {onLevelUpdate?(value)}
                    if let state = event["state"] as? String {onStateUpdate?(state)}
                    if let error = event["error"] as? String {issue = error}
                    if event["complete"] as? Bool == true {complete = true}
                }
                guard token == generation else {return}
                guard complete else {throw FridayError.message(issue.isEmpty ? "Recording ended without audio" : issue)}
                onStateUpdate?("Transcribing locally…")
                let transcribe = self.transcribe
                let text = try await Task.detached {try transcribe(url)}.value
                guard token == generation else {return}
                stopCapture()
                onTranscriptionComplete?(text)
            } catch {
                guard token == generation else {return}
                stopCapture()
                onError?(error.localizedDescription)
            }
        }
    }
}
