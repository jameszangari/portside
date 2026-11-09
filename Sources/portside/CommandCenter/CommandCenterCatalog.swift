import AppKit
import os.log

/// An app Command Center can open: from the installed-app scan or a
/// running instance.
struct CommandCenterApp: Equatable, Sendable {
    let path: String
    let bundleIdentifier: String?
    let name: String

    var resultID: CommandCenterResultID { .application(bundleIdentifier: bundleIdentifier, path: path) }

    init(path: String, bundleIdentifier: String?, name: String) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    init?(running app: NSRunningApplication) {
        guard let url = app.bundleURL else { return nil }
        let fallback = url.deletingPathExtension().lastPathComponent
        self.init(path: url.path, bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? fallback)
    }
}

/// Where Command Center's results come from besides the command registry.
/// Every part is optional, so a test can build a snapshot from fixtures.
struct CommandCenterSources {
    var quicklinks: @MainActor () -> [Quicklink] = { [] }
    var applications: CommandCenterAppIndex?
    var runningApps: @MainActor () -> [CommandCenterApp] = { [] }
    var history: CommandCenterHistory?
    var now: () -> Date = Date.init
    /// Listener snapshot for server rows; nil leaves only the status row.
    var servers: LocalServerStore?
    /// Natural-language and numeric port lookup; nil adds no lookup row.
    var portLookup: PortLookup?
    /// Calculator and emoji rows made from the query; nil adds none.
    var quickAnswers: QuickAnswers?
    var snippets: @MainActor () -> [Snippet] = { [] }
    /// Apple Shortcuts rows and their listing; nil adds none.
    var shortcuts: ShortcutsService?
    /// Menu bar item rows (search and open); nil adds none.
    var menuBar: MenuBarItemsService?
    /// File name search over the chosen folders; nil adds none.
    var files: FileIndexService?
    /// Apps that can open a file path, for Open With. Empty adds no such actions.
    /// Clipboard history rows for `clip` queries; nil adds none.
    var clipboard: ClipboardService?
    var openWithApps: @MainActor (String) -> [URL] = { _ in [] }
}

/// Builds the snapshot Command Center opens with: registry commands without
/// input, Settings panes, quicklinks, apps, local servers and the port lookup. Each provider gets its own
/// result ID prefix (see `CommandCenterResultID`), and every row runs a
/// registry command, so availability and permissions come from the registry.
@MainActor
enum CommandCenterCatalog {
    static func items(registry: CommandRegistry, moduleTitle: (String) -> String?, sources: CommandCenterSources, query: String = "") -> [CommandCenterItem] {
        // The refresh command is the Local Servers status row instead.
        var items = commandItems(registry.descriptors.filter { $0.id != LocalServersModule.refreshCommand }, moduleTitle: moduleTitle)
        items += settingsItems(openPane: registry.descriptor(for: PortsideCoreModule.openSettingsPaneCommand))
        items += quicklinkItems(sources.quicklinks(), open: registry.descriptor(for: CommandCenterModule.openQuicklinkCommand))
        items += clipboardItems(sources.clipboard?.results(for: query) ?? [], query: query, now: sources.now(),
                                copy: registry.descriptor(for: ClipboardModule.copyCommand),
                                delete: registry.descriptor(for: ClipboardModule.deleteCommand))
        items += fileItems(sources.files?.results(for: query) ?? [], open: registry.descriptor(for: FilesModule.openCommand),
                           reveal: registry.descriptor(for: FilesModule.revealCommand),
                           openWith: registry.descriptor(for: FilesModule.openWithCommand), apps: sources.openWithApps)
        items += shortcutItems(sources.shortcuts?.rows ?? [], run: registry.descriptor(for: ShortcutsModule.runCommand))
        items += menuBarItems(sources.menuBar?.rows ?? [], press: registry.descriptor(for: MenuBarModule.pressCommand))
        items += snippetItems(sources.snippets(), copy: registry.descriptor(for: CommandCenterModule.copySnippetCommand))
        items += applicationItems(
            installed: sources.applications?.apps ?? [],
            running: sources.runningApps(),
            open: registry.descriptor(for: CommandCenterModule.openAppCommand)
        )
        items += serverItems(sources.servers, registry: registry, moduleTitle: moduleTitle, answering: answer(sources.portLookup))
        if let lookup = lookupItem(sources.portLookup, store: sources.servers, refresh: registry.descriptor(for: LocalServersModule.refreshCommand)) {
            items.append(lookup)
        }
        items += sources.quickAnswers?.items(query: query, copy: registry.descriptor(for: CommandCenterModule.copyTextCommand)) ?? []
        guard let history = sources.history, !history.isEmpty else { return items }
        let now = sources.now()
        return items.map { item in
            var item = item
            item.usage = history.score(item.id, now: now)
            return item
        }
    }

    /// Commands that take no input. Parameterized ones (open an app, a pane,
    /// a quicklink) are reached through their own rows instead.
    static func commandItems(_ descriptors: [CommandDescriptor], moduleTitle: (String) -> String?) -> [CommandCenterItem] {
        descriptors.filter { $0.input == .none }.map { descriptor in
            CommandCenterItem(
                id: descriptor.id,
                title: descriptor.title,
                subtitle: moduleTitle(descriptor.id.namespace) ?? descriptor.id.namespace,
                symbolName: descriptor.symbolName,
                keywords: descriptor.keywords,
                unavailableReason: descriptor.unavailableReason(),
                permissions: descriptor.requiredPermissions.map(\.description)
            )
        }
    }

    static func settingsItems(openPane: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(openPane)
        return SettingsTab.allCases.map { tab in
            CommandCenterItem(
                id: .settings(tab.rawValue),
                kind: .settings,
                title: "\(tab.title) Settings",
                subtitle: "Settings",
                symbolName: tab.symbol,
                keywords: ["settings", "preferences"],
                unavailableReason: reason,
                permissions: openPane?.requiredPermissions.map(\.description) ?? [],
                invocation: CommandInvocation(command: PortsideCoreModule.openSettingsPaneCommand, input: .string(tab.rawValue)),
                primaryTitle: "Open in Settings",
                copyValue: CommandCenterResultID.settings(tab.rawValue).rawValue,
                copyTitle: "Copy Result ID"
            )
        }
    }

    static func quicklinkItems(_ links: [Quicklink], open: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(open)
        return links.map { link in
            var problem: String?
            var host: [String] = []
            switch QuicklinkURL.validate(link.url) {
            case .success(let url): host = url.host.map { [$0] } ?? []
            case .failure(let error): problem = error.message
            }
            return CommandCenterItem(
                id: .quicklink(link.id),
                kind: .quicklink,
                title: link.title,
                subtitle: "Quicklink",
                symbolName: "link",
                keywords: ["link", "quicklink"] + host,
                unavailableReason: problem ?? reason,
                invocation: CommandInvocation(command: CommandCenterModule.openQuicklinkCommand, input: .string(link.id.uuidString)),
                primaryTitle: "Open Link",
                copyValue: link.url,
                copyTitle: "Copy URL"
            )
        }
    }

    /// Copied text for a `clip` query, newest first. Return copies it back
    /// (nothing is pasted); Cmd+K deletes it. Never kept in history.
    static func clipboardItems(_ entries: [ClipboardEntry], query: String, now: Date,
                               copy: CommandDescriptor?, delete: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(copy)
        let key = CommandCenterRanker.answerKey(query)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return entries.enumerated().map { order, entry in
            var item = CommandCenterItem(
                id: .clipboard(entry.id),
                kind: .clipboard,
                title: entry.title.isEmpty ? "(blank)" : entry.title,
                subtitle: "Clipboard",
                symbolName: "doc.on.clipboard",
                keywords: [],
                unavailableReason: reason,
                invocation: CommandInvocation(command: ClipboardModule.copyCommand, input: .string(entry.id.uuidString)),
                primaryTitle: "Copy to Clipboard",
                copyValue: "",
                copyTitle: "Copy to Clipboard"
            )
            item.detail = "\(formatter.localizedString(for: entry.date, relativeTo: now)) · \(entry.text.count) characters"
            item.answers = key
            item.answerOrder = order
            item.facts = [
                CommandCenterFact(label: "Kind", value: "Copied text"),
                CommandCenterFact(label: "Copied", value: entry.date.formatted(date: .abbreviated, time: .standard)),
                CommandCenterFact(label: "Length", value: "\(entry.text.count) characters"),
                CommandCenterFact(label: "Text", value: String(entry.text.prefix(1000)) + (entry.text.count > 1000 ? "…" : "")),
            ]
            if unavailableReason(delete) == nil {
                item.moreActions = [CommandCenterItemAction(
                    title: "Delete from History", symbolName: "trash",
                    invocation: CommandInvocation(command: ClipboardModule.deleteCommand, input: .string(entry.id.uuidString), staysOpen: true)
                )]
            }
            return item
        }
    }

    /// Matches for the query in the chosen folders. Return opens the file;
    /// Cmd+K shows it in Finder. Both re-check the path against the roots.
    static func fileItems(_ files: [FileEntry], open: CommandDescriptor?, reveal: CommandDescriptor?,
                          openWith: CommandDescriptor? = nil, apps: (String) -> [URL] = { _ in [] }) -> [CommandCenterItem] {
        let reason = unavailableReason(open)
        let revealReason = unavailableReason(reveal)
        return files.map { file in
            var item = CommandCenterItem(
                id: .file(file.path),
                kind: .file,
                title: file.name,
                subtitle: file.isDirectory ? "Folder" : "File",
                symbolName: file.isDirectory ? "folder" : "doc",
                iconPath: file.path,
                keywords: [],
                unavailableReason: reason,
                invocation: CommandInvocation(command: FilesModule.openCommand, input: .string(file.path)),
                primaryTitle: file.isDirectory ? "Open Folder" : "Open File",
                copyValue: file.path,
                copyTitle: "Copy Path"
            )
            item.detail = FileEntry.abbreviated((file.path as NSString).deletingLastPathComponent)
            item.previewable = !file.isDirectory
            item.moreActions = [CommandCenterItemAction(
                title: "Show in Finder", symbolName: "folder",
                invocation: CommandInvocation(command: FilesModule.revealCommand, input: .string(file.path)),
                shortcut: CommandCenterItemAction.revealShortcut
            )]
            if revealReason != nil && reason == nil { item.moreActions = [] }
            // One row per app that can open it, default first. Only an app path
            // goes in the invocation; the file is checked again when it runs.
            if openWithReason(openWith) == nil, reason == nil {
                for app in apps(file.path) {
                    item.moreActions.append(CommandCenterItemAction(
                        title: "Open With \(OpenWithApps.name(app))", symbolName: "arrow.up.forward.app",
                        invocation: CommandInvocation(
                            command: FilesModule.openWithCommand,
                            input: .string(app.path + String(FilesModule.openWithSeparator) + file.path)
                        )
                    ))
                }
            }
            return item
        }
    }

    private static func openWithReason(_ descriptor: CommandDescriptor?) -> String? { unavailableReason(descriptor) }

    /// One row per listed shortcut. Return runs it through the registry by
    /// identifier; it is never run from the query.
    static func shortcutItems(_ shortcuts: [ShortcutInfo], run: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(run)
        return shortcuts.map { shortcut in
            CommandCenterItem(
                id: .shortcut(shortcut.id),
                kind: .shortcut,
                title: shortcut.name,
                subtitle: "Shortcut",
                symbolName: "bolt.fill",
                keywords: ["shortcut", "shortcuts", "automation"],
                unavailableReason: reason,
                invocation: CommandInvocation(command: ShortcutsModule.runCommand, input: .string(shortcut.id.uuidString)),
                primaryTitle: "Run Shortcut",
                copyValue: shortcut.id.uuidString,
                copyTitle: "Copy Shortcut ID"
            )
        }
    }

    /// One row per pressable menu bar item. Return opens it through the
    /// registry by key; it is never opened from the query.
    static func menuBarItems(_ listed: [MenuBarItem], press: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(press)
        return listed.map { item in
            CommandCenterItem(
                id: .menuBarItem(item.id),
                kind: .menuBarItem,
                title: item.displayTitle,
                subtitle: item.title.isEmpty ? "Menu bar item" : "\(item.ownerName) menu bar item",
                symbolName: "menubar.rectangle",
                keywords: ["menu bar", "status", "menu extra", item.ownerName],
                unavailableReason: reason,
                permissions: [PermissionScope.accessibility.description],
                invocation: CommandInvocation(command: MenuBarModule.pressCommand, input: .string(item.id)),
                primaryTitle: "Open Menu Bar Item",
                copyValue: item.id,
                copyTitle: "Copy Item ID"
            )
        }
    }

    /// One row per snippet. Return copies it through the registry by ID, so
    /// the text never travels in the invocation.
    static func snippetItems(_ snippets: [Snippet], copy: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(copy)
        return snippets.map { snippet in
            var item = CommandCenterItem(
                id: .snippet(snippet.id),
                kind: .snippet,
                title: snippet.title,
                subtitle: "Snippet",
                symbolName: "text.alignleft",
                keywords: ["snippet", "text", "paste"],
                unavailableReason: snippet.isEmpty ? "This snippet is empty." : reason,
                invocation: CommandInvocation(command: CommandCenterModule.copySnippetCommand, input: .string(snippet.id.uuidString)),
                primaryTitle: "Copy Snippet",
                copyValue: "",
                copyTitle: "Copy Snippet"
            )
            // The title already shows the first line when there is no name.
            item.detail = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : snippet.preview()
            item.facts = [
                CommandCenterFact(label: "Kind", value: "Snippet"),
                CommandCenterFact(label: "Length", value: "\(snippet.text.count) characters"),
                CommandCenterFact(label: "Text", value: String(snippet.text.prefix(1000)) + (snippet.text.count > 1000 ? "…" : "")),
            ]
            return item
        }
    }

    /// Installed apps, marked when running, plus running apps the scan did
    /// not find (built elsewhere, on another volume). One row per result ID.
    static func applicationItems(installed: [CommandCenterApp], running: [CommandCenterApp], open: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = unavailableReason(open)
        var runningByID: [CommandCenterResultID: CommandCenterApp] = [:]
        for app in running where runningByID[app.resultID] == nil { runningByID[app.resultID] = app }
        var seen = Set<CommandCenterResultID>()
        var items: [CommandCenterItem] = []
        for app in installed + running where seen.insert(app.resultID).inserted {
            // A running copy opens the instance that is running.
            let live = runningByID[app.resultID]
            let path = live?.path ?? app.path
            let fileName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
            items.append(CommandCenterItem(
                id: app.resultID,
                kind: .application,
                title: app.name,
                subtitle: live == nil ? "Application" : "Running",
                symbolName: "app",
                iconPath: path,
                keywords: fileName == app.name ? [] : [fileName],
                unavailableReason: reason,
                invocation: CommandInvocation(command: CommandCenterModule.openAppCommand, input: .string(path)),
                primaryTitle: live == nil ? "Open Application" : "Switch to App",
                copyValue: app.bundleIdentifier ?? path,
                copyTitle: app.bundleIdentifier == nil ? "Copy Path" : "Copy Bundle Identifier"
            ))
        }
        return items
    }

    /// The query a port lookup answers and its port, once there is a port to show.
    private static func answer(_ lookup: PortLookup?) -> (key: String, port: UInt16)? {
        guard let state = lookup?.current, case .port(let port, _) = state.phase else { return nil }
        return (state.key, port)
    }

    private static func unavailableReason(_ descriptor: CommandDescriptor?) -> String? {
        guard let descriptor else { return "This build cannot open it." }
        return descriptor.unavailableReason()
    }
}

// MARK: - Installed apps

/// Installed apps from the standard Applications folders, scanned off the
/// main thread. Nothing scans until Command Center opens; each open starts a
/// background rescan (skipped while one runs or within 30 s of the last), so
/// opening never waits on the disk and the list catches up a moment later.
@MainActor
final class CommandCenterAppIndex {
    nonisolated static let rescanInterval: TimeInterval = 30
    /// A pathological folder cannot make the scan unbounded.
    nonisolated static let scanLimit = 4000

    private(set) var apps: [CommandCenterApp] = []
    private var scanning = false
    private var lastScan: Date?
    private let roots: [URL]
    private let logger = Logger(subsystem: "com.james.portside", category: "CommandCenter")

    init(roots: [URL] = CommandCenterAppIndex.defaultRoots) {
        self.roots = roots
    }

    nonisolated static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
    }

    /// `changed` runs on the main actor when the list differs from before.
    func refresh(now: Date = Date(), changed: @escaping @MainActor () -> Void) {
        guard !scanning else { return }
        if let lastScan, now.timeIntervalSince(lastScan) < Self.rescanInterval { return }
        scanning = true
        let roots = roots
        Task.detached(priority: .utility) { [weak self] in
            let found = CommandCenterAppIndex.scan(roots)
            await self?.finishScan(found, changed: changed)
        }
    }

    private func finishScan(_ found: [CommandCenterApp], changed: @MainActor () -> Void) {
        scanning = false
        lastScan = Date()
        guard found != apps else { return }
        logger.info("command center: \(found.count) installed apps")
        apps = found
        changed()
    }

    /// Top-level apps of each root plus one folder down (`/Applications/Xcode
    /// Tools/…`). First root wins for a bundle ID; output sorted by path.
    nonisolated static func scan(_ roots: [URL]) -> [CommandCenterApp] {
        let files = FileManager.default
        var seen = Set<CommandCenterResultID>()
        var found: [CommandCenterApp] = []
        func add(_ url: URL) {
            guard found.count < scanLimit else { return }
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let bundleID = plist?["CFBundleIdentifier"] as? String
            var name = files.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let app = CommandCenterApp(path: url.path, bundleIdentifier: bundleID, name: name)
            if seen.insert(app.resultID).inserted { found.append(app) }
        }
        func children(_ url: URL) -> [URL] {
            let list = (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return list.sorted { $0.path < $1.path }
        }
        for root in roots {
            for child in children(root) {
                if child.pathExtension == "app" {
                    add(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for nested in children(child) where nested.pathExtension == "app" { add(nested) }
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
