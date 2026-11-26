import SwiftUI
import FridayCore
import EventKit

struct LocalTools:View {
    let isBackup: Bool
    @AppStorage("briefing.hour") private var hour=9
    @AppStorage("briefing.watch") private var watch=""
    @State private var status=""
    var body:some View {
        if !isBackup {
        GroupBox("Calendar briefing") {
            VStack(alignment:.leading){
                Stepper("Daily at \(hour):00",value:$hour,in:0...23)
                HStack {Button("Also trigger on file change"){let p=NSOpenPanel();if p.runModal() == .OK {watch=p.url?.path ?? ""}};Text(watch).lineLimit(1);if !watch.isEmpty {Button("Clear"){watch=""}}}
                HStack {
                    Button("Enable / resume") {
                        Task {
                            do {
                                guard try await EKEventStore().requestFullAccessToEvents() else {
                                    status = "Allow Calendar access to enable briefings."
                                    return
                                }
                                helper("briefing", ["configure", String(hour), watch], "Briefing enabled.")
                            } catch { status = error.localizedDescription }
                        }
                    }
                    Button("Pause"){helper("briefing",["pause"],"Briefing paused.")}
                    Button("Runs"){helper("briefing",["history"],"No recorded runs.")}
                    Button("Briefing files"){let dir=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Friday/Workflows");NSWorkspace.shared.open(dir)}
                }
            }
        }
        } else {
        GroupBox("Backup and restore"){
            HStack {
                Button("Back up"){let panel=NSSavePanel();panel.nameFieldStringValue="Friday Backup";if panel.runModal() == .OK,let url=panel.url {helper("archive",["save",url.path],"Backup saved.")}}
                Button("Restore…"){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
                    if panel.runModal() == .OK,let url=panel.url {
                        let confirm=NSAlert();confirm.messageText="Replace FRIDAY chats, settings, and memory from this backup?";confirm.addButton(withTitle:"Cancel");confirm.addButton(withTitle:"Restore")
                        if confirm.runModal() == .alertSecondButtonReturn {helper("archive",["restore",url.path],"Restored. Reopen FRIDAY.")}
                    }
                }
            }
        }
        }
        if !status.isEmpty {Text(status).textSelection(.enabled)}
    }
    private func helper(_ name:String,_ args:[String],_ success:String) {
        Task {do {
            let text=try await Task.detached {try ProcessRunner.run(AppResources.python,[AppResources.path(name,"py")]+args)}.value
            status=text.isEmpty ? success : text
        }catch {status=error.localizedDescription}}
    }
}
