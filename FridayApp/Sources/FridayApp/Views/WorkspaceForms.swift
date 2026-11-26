import SwiftUI
import FridayCore

struct DocumentImport: View {
    @EnvironmentObject var state: AppState
    @State private var ragTitle = ""
    @State private var ragBody = ""
    @State private var isIndexingRAG = false
    @State private var feedback = ""
    var body: some View {
        GroupBox("Add a document") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Document title", text: $ragTitle)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $ragBody)
                    .frame(minHeight: 70, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Button("Import Text / Markdown File…") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url,
                           let content = try? String(contentsOf: url, encoding: .utf8) {
                            ragTitle = url.lastPathComponent
                            ragBody = content
                        }
                    }
                    Button(isIndexingRAG ? "Indexing…" : "Index Document") {
                        let title = ragTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let body = ragBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty, !body.isEmpty else { return }
                        isIndexingRAG = true
                        Task {
                            defer { isIndexingRAG = false }
                            do {
                                try await state.indexRAGDocument(title: title, body: body, mediaType: "text", sourcePath: nil)
                                feedback = "Indexed '\(title)' (\(state.memoryEmbeddingMode.displayName))."
                                ragTitle = ""
                                ragBody = ""
                            } catch {
                                feedback = error.localizedDescription
                            }
                        }
                    }
                    .disabled(isIndexingRAG || ragTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ragBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        if !feedback.isEmpty { Text(feedback).font(.callout) }
    }
}

struct AppleReminderForm: View {
    @EnvironmentObject var state: AppState
    @State private var reminder = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var feedback = ""
    var body: some View {
        GroupBox("Apple Reminders"){
            if let subject=state.pendingMailSubject {Button("Use Mail draft subject"){reminder="Follow up: "+subject}}
            VStack(alignment: .leading) {TextField("Follow-up",text:$reminder);DatePicker("Due",selection:$due)
                Button("Add reminder"){Task {do {try await DesktopTools.addReminder(reminder,due:due);feedback="Added to Apple Reminders";reminder=""}catch {feedback=error.localizedDescription}}}.disabled(reminder.isEmpty)
            }
        }
        if !feedback.isEmpty { Text(feedback).font(.callout) }
    }
}
