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
}

/// Builds the snapshot Command Center opens with: registry commands without
/// input, Settings panes, quicklinks, apps and local servers. Each provider gets its own
/// result ID prefix (see `CommandCenterResultID`), and every row runs a
/// registry command, so availability and permissions come from the registry.
@MainActor
enum CommandCenterCatalog {
    static func items(registry: CommandRegistry, moduleTitle: (String) -> String?, sources: CommandCenterSources) -> [CommandCenterItem] {
        // The refresh command is the Local Servers status row instead.
        var items = commandItems(registry.descriptors.filter { $0.id != LocalServersModule.refreshCommand }, moduleTitle: moduleTitle)
        items += settingsItems(openPane: registry.descriptor(for: PortsideCoreModule.openSettingsPaneCommand))
        items += quicklinkItems(sources.quicklinks(), open: registry.descriptor(for: CommandCenterModule.openQuicklinkCommand))
        items += applicationItems(
            installed: sources.applications?.apps ?? [],
            running: sources.runningApps(),
            open: registry.descriptor(for: CommandCenterModule.openAppCommand)
        )
        items += serverItems(sources.servers, registry: registry, moduleTitle: moduleTitle)
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
