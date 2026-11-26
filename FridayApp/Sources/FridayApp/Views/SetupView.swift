import SwiftUI
import AVFoundation
import EventKit
import FridayCore

struct SetupView: View {
    private struct Check: Identifiable {
        let name: String
        let ready: Bool
        let detail: String
        var id: String { name }
    }
    @State private var checks = [Check]()

    private func refresh() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let hermes = home.appendingPathComponent(".local/bin/hermes")
        let pythonReady = AppResources.hermesPython != nil
        let voiceRoots = [Bundle.main.resourceURL?.appendingPathComponent("Whisper"),
                          home.appendingPathComponent(".hermes/tools/friday-whisper")].compactMap { $0 }
        let voice = voiceRoots.contains { dir in
            fm.isExecutableFile(atPath: dir.appendingPathComponent("whisper-cli").path) &&
                ["ggml-base.bin", "ggml-small.en.bin"].allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
        checks = [
            Check(name: "Hermes", ready: fm.isExecutableFile(atPath: hermes.path) && pythonReady, detail: "Install Hermes Agent and configure a provider with hermes setup."),
            Check(name: "Whisper", ready: voice, detail: "Use the FRIDAY package containing the voice models."),
            Check(name: "Mac controls", ready: fm.isExecutableFile(atPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"), detail: "Install CuaDriver using hermes computer-use install."),
            Check(name: "Microphone", ready: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, detail: "Enable when using voice."),
            Check(name: "Screen Recording", ready: CGPreflightScreenCaptureAccess(), detail: "Enable when reading a window or chart."),
            Check(name: "Calendar", ready: EKEventStore.authorizationStatus(for: .event) == .fullAccess, detail: "Enable when checking availability or scheduling briefings."),
            Check(name: "Reminders", ready: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, detail: "Enable when adding a follow-up.")
        ]
    }

    var body: some View {
        GroupBox("Mac setup") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(checks) { check in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: check.ready ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(check.ready ? Color.green : .secondary)
                        Text(check.name)
                        if !check.ready { Text(check.detail).font(.caption).foregroundStyle(.secondary) }
                    }.accessibilityElement(children: .combine)
                }
                HStack {
                    Button("Check again", action: refresh)
                    Link("Hermes setup", destination: URL(string: "https://github.com/NousResearch/hermes-agent#readme")!)
                    Button("Privacy settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Label("Drag FRIDAY to Settings", systemImage: "app.dashed")
                        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear(perform: refresh)
    }
}
