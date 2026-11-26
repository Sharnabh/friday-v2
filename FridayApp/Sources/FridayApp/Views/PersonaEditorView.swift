import SwiftUI
import FridayCore

struct PersonaEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.square")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(DesktopTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(DesktopTheme.userBubble(for: scheme), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit persona").font(.title2.bold())
                    Text(state.editingBotId.isEmpty ? "Core assistant" : "Custom assistant")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        field("Persona name") {
                            TextField("Name", text: $state.editingBotName)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Persona name")
                        }
                        field("Model role") {
                            Picker("Model role", selection: $state.editingBotRole) {
                                ForEach(BotRolePreset.allCases) { role in
                                    Text(role.displayName).tag(role)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    field("Instructions and tone") {
                        TextEditor(text: $state.editingBotInstructions)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 120)
                            .background(DesktopTheme.field(for: scheme), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.28)))
                            .accessibilityLabel("Instructions and tone")
                    }
                    field("Voice") {
                        HStack {
                            Picker("Voice", selection: $state.editingBotVoice) {
                                ForEach(HeyGenTTSCatalog.voices) { voice in
                                    Text(voice.label).tag(voice.id)
                                }
                            }
                            .labelsHidden()
                            Button {
                                state.previewVoice(state.editingBotVoice, botName: state.editingBotName)
                            } label: {
                                Label("Preview", systemImage: "play.fill")
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(idealHeight: 330)
            .background(DesktopTheme.sidebar(for: scheme))
            Divider()
            HStack {
                if !state.editingBotId.isEmpty {
                    Button(role: .destructive) {
                        state.deleteBot(id: state.editingBotId)
                        state.showEditPersonaModal = false
                    } label: {
                        Label("Delete persona", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Cancel") { state.showEditPersonaModal = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save changes") {
                    state.updateBot(id: state.editingBotId, name: state.editingBotName,
                                    instructions: state.editingBotInstructions, voice: state.editingBotVoice,
                                    role: state.editingBotRole)
                    state.showEditPersonaModal = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.editingBotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .controlSize(.large)
        .tint(DesktopTheme.accent)
        .background(DesktopTheme.canvas(for: scheme))
        .frame(width: 540)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
