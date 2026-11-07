import SwiftUI

/// Settings > General > Command Center: quicklinks and search history.
/// Edits save as you type; a link that does not pass `QuicklinkURL` is kept
/// and says why, here and in its Command Center row.
struct CommandCenterSettingsSection: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var history: CommandCenterHistory

    var body: some View {
        Section {
            ForEach(dockModel.commandCenterQuicklinks) { link in
                QuicklinkRow(link: link, dockModel: dockModel)
            }
            Button("Add Quicklink") { dockModel.addQuicklink() }
                .disabled(dockModel.commandCenterQuicklinks.count >= Quicklink.listLimit)
            HStack {
                Text("Search history")
                Spacer()
                Text(historySummary).foregroundStyle(.secondary)
                Button("Clear History") { history.clear() }
                    .disabled(history.isEmpty)
            }
        } header: {
            Text("Command Center")
        } footer: {
            Text("Quicklinks open from Command Center by name. Allowed links start with \(QuicklinkURL.allowedSchemes.map { "\($0):" }.joined(separator: ", ")). History ranks what you open often or recently first. It keeps only which result you opened, how often and when, never what you typed, and stays on this Mac.")
                .footerStyle()
        }
    }

    private var historySummary: String {
        switch history.entries.count {
        case 0: return "Empty"
        case 1: return "1 item"
        default: return "\(history.entries.count) items"
        }
    }
}

private struct QuicklinkRow: View {
    let link: Quicklink
    @ObservedObject var dockModel: DockModel

    private var problem: String? {
        if case .failure(let problem) = QuicklinkURL.validate(link.url) { return problem.message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Name", text: binding(\.name))
                    .frame(width: 150)
                    .accessibilityLabel("Quicklink name")
                TextField("https://example.com", text: binding(\.url))
                    .accessibilityLabel("Quicklink URL")
                Button {
                    dockModel.removeQuicklink(id: link.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove \(link.title)")
            }
            .labelsHidden()
            if let problem {
                Label {
                    Text(problem).helperStyle()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }

    private func binding(_ path: WritableKeyPath<Quicklink, String>) -> Binding<String> {
        Binding(
            get: { link[keyPath: path] },
            set: { value in
                var next = link
                next[keyPath: path] = value
                dockModel.updateQuicklink(next)
            }
        )
    }
}
