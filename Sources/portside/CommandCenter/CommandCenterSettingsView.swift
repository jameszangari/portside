import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings > General > Command Center: quicklinks and search history.
/// Edits save as you type; a link that does not pass `QuicklinkURL` is kept
/// and says why, here and in its Command Center row.
struct CommandCenterSettingsSection: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var history: CommandCenterHistory
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var files: FileIndexService
    @State private var folderProblem: String?

    var body: some View {
        Section {
            ForEach(dockModel.commandCenterQuicklinks) { link in
                QuicklinkRow(link: link, dockModel: dockModel)
            }
            Button("Add Quicklink") { dockModel.addQuicklink() }
                .disabled(dockModel.commandCenterQuicklinks.count >= Quicklink.listLimit)
            if !files.roots.isEmpty, !files.isActive {
                Label {
                    Text("Files is off, so nothing is indexed or searchable. Turn it on in Settings > Integrations (it needs Command Center on too).").helperStyle()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            ForEach(files.roots) { root in
                FileRootRow(root: root, state: files.isActive ? (files.states[root.id] ?? .notScanned) : .off) { files.removeRoot(id: root.id) }
            }
            HStack {
                Button("Add Searchable Folder…") { chooseFolder() }
                    .disabled(files.roots.count >= FileRootRules.limit)
                Button("Refresh File Index") { files.refresh(force: true) }
                    .disabled(files.roots.isEmpty || !files.isActive)
            }
            if let folderProblem {
                Label {
                    Text(folderProblem).helperStyle()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            ForEach(snippets.snippets) { snippet in
                SnippetRow(snippet: snippet, store: snippets)
            }
            Button("Add Snippet") { snippets.add() }
                .disabled(snippets.isFull)
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
            Text("Quicklinks open from Command Center by name. Allowed links start with \(QuicklinkURL.allowedSchemes.map { "\($0):" }.joined(separator: ", ")). Searchable folders feed file name search (turn on Files in Settings > Integrations): names only, nothing outside the folders you add, symbolic links not followed, and removing a folder drops its index at once. Snippets are text you type here; picking one in Command Center copies it as plain text and nothing more, and they are stored only on this Mac, outside dock.json. History ranks what you open often or recently first. It keeps only which result you opened, how often and when, never what you typed, and stays on this Mac.")
                .footerStyle()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Search This Folder"
        panel.message = "Command Center will search the names of files inside this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch files.addRoot(url.path) {
        case .success: folderProblem = nil
        case .failure(let problem): folderProblem = problem.message
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

private struct SnippetRow: View {
    let snippet: Snippet
    @ObservedObject var store: SnippetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Snippet name", text: binding(\.name))
                    .accessibilityLabel("Snippet name")
                Button {
                    store.remove(id: snippet.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove \(snippet.title)")
            }
            TextEditor(text: binding(\.text))
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .accessibilityLabel("Snippet text")
            if snippet.isEmpty {
                Label {
                    Text("Add some text to copy.").helperStyle()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .labelsHidden()
    }

    private func binding(_ path: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(
            get: { snippet[keyPath: path] },
            set: { value in
                var next = snippet
                next[keyPath: path] = value
                store.update(next)
            }
        )
    }
}

private struct FileRootRow: View {
    let root: FileRoot
    let state: FileRootState
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FileEntry.abbreviated(root.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(state.text).helperStyle()
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop searching this folder")
            .accessibilityLabel("Stop searching \(FileEntry.abbreviated(root.path))")
        }
    }
}

/// Settings > General > Clipboard History: pause, expiry, excluded apps and
/// Clear History. The module itself is switched in Settings > Integrations.
struct ClipboardSettingsSection: View {
    @ObservedObject var service: ClipboardService
    @State private var confirmClear = false
    @State private var problem: String?

    private static let expiryTitles: [Int: String] = [1: "1 hour", 24: "1 day", 24 * 7: "7 days", 24 * 30: "30 days"]

    var body: some View {
        Section {
            if !service.isActive {
                Label {
                    Text("Clipboard History is off, so nothing is being kept. Turn it on in Settings > Integrations (it needs Command Center on too).").helperStyle()
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            }
            Toggle("Pause clipboard history", isOn: Binding(get: { service.prefs.paused }, set: { service.setPaused($0) }))
                .disabled(!service.isActive)
            Picker("Keep copied text for", selection: Binding(get: { service.prefs.expiryHours }, set: { service.setExpiry(hours: $0) })) {
                ForEach(ClipboardPrefs.expiryChoices, id: \.self) { Text(Self.expiryTitles[$0] ?? "\($0) hours").tag($0) }
            }
            ForEach(service.prefs.excludedApps, id: \.self) { bundleID in
                HStack {
                    Text(bundleID).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { service.includeApp(bundleID) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Capture from this app again")
                        .accessibilityLabel("Stop excluding \(bundleID)")
                }
            }
            HStack {
                Button("Exclude an App…") { chooseApp() }
                Spacer()
                Text(service.isActive ? countText : "").foregroundStyle(.secondary)
                // Also works while the module is off: the encrypted file can outlive it.
                Button("Clear History…") { confirmClear = true }
            }
            if let problem {
                Label {
                    Text(problem).helperStyle()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Clipboard History")
        } footer: {
            Text("Keeps the text you copy, encrypted on this Mac with a key in your keychain (your login keychain in an unsigned build), and finds it again when you type clip in Command Center. It skips what apps mark as secret, copies made while a password field has the keyboard, and password managers (\(ClipboardPolicy.builtInExcludedApps.count) built in), plus the apps you add here. It cannot recognize every secret, so pause it or exclude an app when that matters. Text only, never synced or sent anywhere, and it is dropped from memory when the module is off (the encrypted file stays until it expires or you clear it).")
                .footerStyle()
        }
        .confirmationDialog("Clear all clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { service.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved entry and the encrypted file. It cannot be undone.")
        }
    }

    private var countText: String {
        switch service.entries.count {
        case 0: return "Empty"
        case 1: return "1 entry"
        default: return "\(service.entries.count) entries"
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
            problem = "That app has no bundle identifier."
            return
        }
        problem = service.excludeApp(id) ? nil : "That app is already excluded, or the list is full."
    }
}
