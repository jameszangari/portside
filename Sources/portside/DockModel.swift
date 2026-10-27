import AppKit
import os.log

/// A pinned app. Identified by bundle id when it has one (survives the app
/// moving on disk), otherwise by its path.
struct PinnedApp: Codable, Hashable, Identifiable {
    var bundleIdentifier: String?
    var path: String

    var id: String { bundleIdentifier ?? path }

    /// Current location: Launch Services lookup by bundle id, falling back
    /// to the saved path.
    var url: URL {
        if let bundleIdentifier,
           let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return found
        }
        return URL(fileURLWithPath: path)
    }

    var displayName: String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    init(bundleIdentifier: String?, path: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }

    /// Build from an .app URL, reading the bundle id from its Info.plist.
    init?(appURL: URL) {
        guard appURL.pathExtension == "app" else { return nil }
        self.init(bundleIdentifier: Bundle(url: appURL)?.bundleIdentifier, path: appURL.path)
    }

    init?(runningApp: NSRunningApplication) {
        guard let url = runningApp.bundleURL else { return nil }
        self.init(bundleIdentifier: runningApp.bundleIdentifier, path: url.path)
    }
}

/// Codable settings + pinned apps, persisted to
/// ~/Library/Application Support/com.james.portside/dock.json.
///
/// React analogy: an observable store. Views that hold it as an
/// @ObservedObject re-render when a @Published property changes.
final class DockModel: Codable, ObservableObject {
    // MARK: - Timing settings

    /// Delay (seconds) before the panel starts revealing after edge detection.
    var revealDelay: TimeInterval = 0.0

    /// Delay (seconds) after mouse leaves before the panel hides.
    var hideDelay: TimeInterval = 0.3

    // MARK: - Animation settings

    /// Duration (seconds) of the reveal/hide slide animation.
    var animationDuration: TimeInterval = 0.15

    // MARK: - Icon settings

    /// Size (points) of dock item icons. Tiles can render smaller when the
    /// strip would not fit on screen.
    @Published private(set) var iconSize: CGFloat = 48.0

    /// Same range as the native Dock's `tilesize`.
    static let iconSizeRange: ClosedRange<CGFloat> = 16...128

    /// Whether magnification is enabled on hover.
    var magnificationEnabled: Bool = false

    // MARK: - Position

    /// Screen edge the dock sits on.
    @Published private(set) var edge: DockEdge = .bottom

    func setEdge(_ newEdge: DockEdge) {
        guard newEdge != edge else { return }
        edge = newEdge
        persist()
    }

    /// Live resize calls this on every drag step with `persist: false`, then
    /// once more with `persist: true` on release.
    func setIconSize(_ size: CGFloat, persist shouldPersist: Bool) {
        let clamped = min(max(size.rounded(), DockModel.iconSizeRange.lowerBound), DockModel.iconSizeRange.upperBound)
        if clamped != iconSize {
            iconSize = clamped
        }
        if shouldPersist { persist() }
    }

    // MARK: - Pinned apps

    @Published var pinnedApps: [PinnedApp] = []

    // MARK: - Widgets

    /// Enabled widgets, in display order (see `WidgetCatalog`).
    @Published var widgetKinds: [String] = WidgetCatalog.defaultKinds

    func setWidget(_ kind: String, enabled: Bool) {
        var kinds = widgetKinds.filter { $0 != kind }
        if enabled {
            // Keep catalog order so re-enabling puts it back where it was.
            let order = WidgetCatalog.defaultKinds
            let position = order.firstIndex(of: kind) ?? order.count
            let insertAt = kinds.firstIndex { (order.firstIndex(of: $0) ?? order.count) > position } ?? kinds.count
            kinds.insert(kind, at: insertAt)
        }
        widgetKinds = kinds
        persist()
    }

    private static let logger = Logger(subsystem: "com.james.portside", category: "DockModel")

    init() {}

    // MARK: - Pinned app mutations (each one persists)

    func isPinned(_ app: PinnedApp) -> Bool {
        pinnedApps.contains { $0.id == app.id }
    }

    /// Pin an app at `index` (end if nil). If already pinned, moves it there.
    func pin(_ app: PinnedApp, at index: Int? = nil) {
        var apps = pinnedApps
        if let existing = apps.firstIndex(where: { $0.id == app.id }) {
            apps.remove(at: existing)
        }
        let target = min(max(index ?? apps.count, 0), apps.count)
        apps.insert(app, at: target)
        pinnedApps = apps
        persist()
    }

    func unpin(_ app: PinnedApp) {
        pinnedApps.removeAll { $0.id == app.id }
        persist()
    }

    /// Move a pinned app to `index`. Drag reorder calls this on every slot
    /// change with `persist: false`, then `saveOrder()` once on release.
    func move(_ app: PinnedApp, toIndex index: Int, persist shouldPersist: Bool = true) {
        guard let from = pinnedApps.firstIndex(where: { $0.id == app.id }) else { return }
        let to = min(max(index, 0), pinnedApps.count - 1)
        guard from != to else { return }
        var apps = pinnedApps
        apps.remove(at: from)
        apps.insert(app, at: to)
        pinnedApps = apps
        if shouldPersist { persist() }
    }

    func saveOrder() {
        persist()
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case revealDelay, hideDelay, animationDuration, iconSize, magnificationEnabled, edge, pinnedApps, widgetKinds
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revealDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .revealDelay) ?? 0.0
        hideDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .hideDelay) ?? 0.3
        animationDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .animationDuration) ?? 0.15
        iconSize = try c.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 48.0
        magnificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .magnificationEnabled) ?? false
        edge = (try? c.decodeIfPresent(DockEdge.self, forKey: .edge)) ?? .bottom
        if let apps = try c.decodeIfPresent([PinnedApp].self, forKey: .pinnedApps) {
            pinnedApps = apps
        } else {
            pinnedApps = DockModel.seedFromNativeDock()
        }
        widgetKinds = try c.decodeIfPresent([String].self, forKey: .widgetKinds) ?? WidgetCatalog.defaultKinds
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revealDelay, forKey: .revealDelay)
        try c.encode(hideDelay, forKey: .hideDelay)
        try c.encode(animationDuration, forKey: .animationDuration)
        try c.encode(iconSize, forKey: .iconSize)
        try c.encode(magnificationEnabled, forKey: .magnificationEnabled)
        try c.encode(edge, forKey: .edge)
        try c.encode(pinnedApps, forKey: .pinnedApps)
        try c.encode(widgetKinds, forKey: .widgetKinds)
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let portsideDir = directory.appendingPathComponent("com.james.portside")
        try? FileManager.default.createDirectory(at: portsideDir, withIntermediateDirectories: true)
        return portsideDir.appendingPathComponent("dock.json")
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: DockModel.storageURL, options: .atomic)
    }

    private func persist() {
        do {
            try save()
            DockModel.logger.info("saved \(self.pinnedApps.count) pinned apps")
        } catch {
            DockModel.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load from disk. On first launch (no file), seed pinned apps from the
    /// native Dock and save immediately so later launches use Portside's list.
    static func load() -> DockModel {
        if let data = try? Data(contentsOf: storageURL),
           let model = try? JSONDecoder().decode(DockModel.self, from: data) {
            logger.info("loaded \(model.pinnedApps.count) pinned apps from dock.json")
            return model
        }
        let model = DockModel()
        model.pinnedApps = seedFromNativeDock()
        model.persist()
        logger.info("first launch: seeded \(model.pinnedApps.count) pinned apps from the native Dock")
        return model
    }

    /// Read (never write) the native Dock's pinned apps, with Finder first
    /// like the real Dock.
    static func seedFromNativeDock() -> [PinnedApp] {
        var result: [PinnedApp] = [
            PinnedApp(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")
        ]
        let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        for tile in tiles {
            guard tile["tile-type"] as? String == "file-tile",
                  let data = tile["tile-data"] as? [String: Any],
                  let fileData = data["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let url = URL(string: urlString), url.isFileURL else { continue }
            let app = PinnedApp(bundleIdentifier: data["bundle-identifier"] as? String, path: url.path)
            if !result.contains(where: { $0.id == app.id }) {
                result.append(app)
            }
        }
        return result
    }
}
