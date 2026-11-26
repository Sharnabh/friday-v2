import SwiftUI

struct WorkspaceSectionStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

struct WorkspacePage<Content: View>: View {
    let title: String
    @Binding var selection: String
    let sections: [String]
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.system(size: 26, weight: .semibold))
                Picker(title, selection: $selection) {
                    ForEach(sections, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 500)
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16, content: content)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .groupBoxStyle(WorkspaceSectionStyle())
        .background(DesktopTheme.canvas(for: scheme))
        .tint(DesktopTheme.accent)
    }
}
