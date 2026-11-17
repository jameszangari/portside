import AppKit
import Combine

/// What the Command Center commands do outside Portside. Injected so tests
/// never launch an app or open a link.
struct CommandCenterActions {
    /// Launch or bring forward the app at this bundle URL. nil on success,
    /// otherwise the reason it failed.
    var openApplication: @MainActor (URL) async -> String?
    /// Opens an already validated URL. false when macOS refused.
    var openURL: @MainActor (URL) -> Bool
    var quicklinks: @MainActor () -> [Quicklink]
    /// Puts plain text on the pasteboard. false when it could not.
    var copyText: @MainActor (String) -> Bool = { _ in false }
    var snippets: @MainActor () -> [Snippet] = { [] }
    /// The path is an existing directory (an .app bundle is one).
    var bundleExists: (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Opens through `AppLauncher`, the dock tiles' path, so a running app
    /// unhides and comes forward and a stopped one launches.
    static func live(quicklinks: @escaping @MainActor () -> [Quicklink], snippets: @escaping @MainActor () -> [Snippet] = { [] }) -> CommandCenterActions {
        CommandCenterActions(
            openApplication: { url in
                guard let app = PinnedApp(appURL: url) else { return "Not an app." }
                let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
                return await withCheckedContinuation { continuation in
                    AppLauncher.open(app, running: running) { _, error in
                        continuation.resume(returning: error?.localizedDescription)
                    }
                }
            },
            openURL: { NSWorkspace.shared.open($0) },
            quicklinks: quicklinks,
            copyText: { text in
                NSPasteboard.general.clearContents()
                let done = NSPasteboard.general.setString(text, forType: .string)
                // A snippet or result Portside copied is not clipboard history.
                ClipboardService.shared.noteOwnWrite(changeCount: NSPasteboard.general.changeCount)
                return done
            },
            snippets: snippets
        )
    }

    static let none = CommandCenterActions(openApplication: { _ in "Not available." }, openURL: { _ in false }, quicklinks: { [] })
}

/// The optional `commandCenter` module. Off by default like every optional
/// module: until it is turned on in Settings > Command Center, no shortcut is
/// registered and the menu bar item is hidden. Running, it keeps the global
/// shortcut in step with `commandCenterHotkey`. Its two commands open an
/// app and a quicklink, so those rows run through the registry like any
/// other and are unavailable while the module is off.
@MainActor
final class CommandCenterModule: PortsideModule {
    static let moduleID = ModuleID("commandCenter")!
    static let openAppCommand = CommandID("commandCenter.openApp")!
    static let openQuicklinkCommand = CommandID("commandCenter.openQuicklink")!
    static let copyTextCommand = CommandID("commandCenter.copyText")!
    static let copySnippetCommand = CommandID("commandCenter.copySnippet")!

    let id = CommandCenterModule.moduleID
    let title = "Command Center"
    let summary = "A search panel for apps, Portside's commands, Settings panes, your quicklinks and snippets, a calculator and emoji, opened with a global shortcut (default ⌥Space, set in General > Keyboard)."
    let fallback = "Every command stays in the menu bar menu, the dock and Settings."
    /// A Carbon hotkey is not key interception and reads no data.
    let isSensitive = false

    private let center: CommandCenter
    private let chords: AnyPublisher<HotkeyChord?, Never>
    private let actions: CommandCenterActions

    /// `chords` publishes the saved shortcut, current value first.
    init(center: CommandCenter, chords: AnyPublisher<HotkeyChord?, Never>, actions: CommandCenterActions = .none) {
        self.center = center
        self.chords = chords
        self.actions = actions
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.openAppCommand,
                title: "Open Application",
                keywords: ["launch", "switch"],
                symbolName: "app",
                input: .string(maxLength: 4096),
                handler: { [actions] input in
                    guard case .string(let path) = input else { return .failure(CommandFailure(reason: "No app given.")) }
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard path.hasPrefix("/"), url.pathExtension == "app" else {
                        return .failure(CommandFailure(reason: "Not an app."))
                    }
                    guard actions.bundleExists(url.path) else {
                        return .failure(CommandFailure(reason: "\(url.deletingPathExtension().lastPathComponent) is no longer at \(url.deletingLastPathComponent().path)."))
                    }
                    if let problem = await actions.openApplication(url) { return .failure(CommandFailure(reason: problem)) }
                    return .success(nil)
                }
            ),
            CommandDescriptor(
                id: Self.copyTextCommand,
                title: "Copy Text",
                keywords: ["clipboard", "calculator", "emoji"],
                symbolName: "doc.on.doc",
                input: .string(maxLength: 256),
                handler: { [actions] input in
                    // Plain text only: a calculator result or one emoji. Never run or opened.
                    guard case .string(let text) = input, !text.isEmpty else {
                        return .failure(CommandFailure(reason: "Nothing to copy."))
                    }
                    return actions.copyText(text) ? .success(nil) : .failure(CommandFailure(reason: "macOS would not take the text."))
                }
            ),
            CommandDescriptor(
                id: Self.copySnippetCommand,
                title: "Copy Snippet",
                keywords: ["clipboard", "text"],
                symbolName: "text.alignleft",
                input: .string(maxLength: 36),
                handler: { [actions] input in
                    // The ID, never text: only a saved snippet can be copied, as plain text.
                    guard case .string(let raw) = input, let id = UUID(uuidString: raw),
                          let snippet = actions.snippets().first(where: { $0.id == id }) else {
                        return .failure(CommandFailure(reason: "That snippet was removed."))
                    }
                    guard !snippet.isEmpty else { return .failure(CommandFailure(reason: "This snippet is empty.")) }
                    return actions.copyText(snippet.text) ? .success(nil) : .failure(CommandFailure(reason: "macOS would not take the text."))
                }
            ),
            CommandDescriptor(
                id: Self.openQuicklinkCommand,
                title: "Open Quicklink",
                keywords: ["link", "url"],
                symbolName: "link",
                input: .string(maxLength: 36),
                handler: { [actions] input in
                    // The ID, never a URL: only a saved quicklink can open.
                    guard case .string(let raw) = input, let id = UUID(uuidString: raw),
                          let link = actions.quicklinks().first(where: { $0.id == id }) else {
                        return .failure(CommandFailure(reason: "That quicklink was removed."))
                    }
                    switch QuicklinkURL.validate(link.url) {
                    case .failure(let problem):
                        return .failure(CommandFailure(reason: problem.message))
                    case .success(let url):
                        return actions.openURL(url) ? .success(nil) : .failure(CommandFailure(reason: "macOS could not open \(link.title)."))
                    }
                }
            ),
        ]
    }

    func start(_ context: ModuleContext) throws {
        center.setEnabled(true)
        let subscription = chords.sink { [center] chord in
            MainActor.assumeIsolated { center.setHotkey(chord) }
        }
        context.onStop { [center] in
            subscription.cancel()
            MainActor.assumeIsolated { center.setEnabled(false) }
        }
    }
}
