import Foundation
import AppKit

public final class VoiceService: NSObject, @unchecked Sendable {
    public static let shared = VoiceService()

    private var recorder: Process?
    private var commands: Pipe?
    private var requesting = false
    private var generation = 0

    public var onLevelUpdate: (@Sendable (Double) -> Void)?
    public var onStateUpdate: (@Sendable (String) -> Void)?
    public var onTranscriptionComplete: (@Sendable (String) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private var launcherPath: String {
        // Look in main bundle or fallback to outputs/Friday.app resources
        if let path = Bundle.main.path(forResource: "launch_voice", ofType: "py") {
            return path
        }
        let fallback = "/Users/user/Documents/Codex/2026-11-23/i-w/outputs/Friday.app/Contents/Resources/launch_voice.py"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : ""
    }

    public func listMicrophones() -> [String] {
        guard !launcherPath.isEmpty else { return [] }
        guard let result = try? ProcessRunner.run("/usr/bin/python3", [launcherPath, "devices"]),
              let names = try? JSONDecoder().decode([String].self, from: Data(result.utf8)) else {
            return []
        }
        return names
    }

    public func stopCapture() {
        generation += 1
        requesting = false
        if let p = recorder, p.isRunning {
            p.terminate()
        }
        recorder = nil
        commands = nil
        onStateUpdate?("Microphone idle")
        onLevelUpdate?(0)
    }

    public func startCapture(handsFree: Bool, micDeviceName: String) {
        stopCapture()
        guard !launcherPath.isEmpty else {
            onError?("Voice launcher script missing.")
            return
        }

        requesting = true
        let token = generation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")

        let p = Process(), out = Pipe(), control = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [launcherPath, handsFree ? "wake" : "manual", micDeviceName, url.path]
        p.standardOutput = out
        p.standardInput = control
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            requesting = false
            onError?(error.localizedDescription)
            return
        }

        self.recorder = p
        self.commands = control
        onStateUpdate?("Starting microphone…")

        DispatchQueue.global().async {
            var buffer = Data(), complete = false, issue = ""
            while true {
                let data = out.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if let error = event["error"] as? String { issue = error }
                    if event["complete"] as? Bool == true { complete = true }

                    if self.generation == token {
                        if let level = event["level"] as? Double {
                            self.onLevelUpdate?(level)
                        }
                        if let state = event["state"] as? String {
                            self.onStateUpdate?(state)
                        }
                    }
                }
            }
            p.waitUntilExit()

            guard self.generation == token else {
                try? FileManager.default.removeItem(at: url)
                return
            }

            self.stopCapture()
            guard complete else {
                self.onError?(issue.isEmpty ? "Recording ended without audio" : issue)
                return
            }

            // Local Whisper Transcription
            let whisperDir = NSHomeDirectory() + "/.hermes/tools/friday-whisper/"
            let whisperCli = whisperDir + "whisper-cli"
            let modelPath = whisperDir + "ggml-small.en.bin"

            defer { try? FileManager.default.removeItem(at: url) }

            do {
                self.onStateUpdate?("Transcribing locally…")
                let transcript = try ProcessRunner.run(
                    whisperCli,
                    ["-m", modelPath, "-f", url.path, "-l", "en", "-ng", "-nt", "-np"]
                )
                self.onTranscriptionComplete?(transcript)
            } catch {
                self.onError?("Transcription error: " + error.localizedDescription)
            }
        }
    }
}
