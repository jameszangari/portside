import AppKit
import Combine
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
    //
    // The engine and panel read these each time they arm a delay or start a
    // slide, so a change applies to the next reveal or hide without any
    // extra wiring. Published only so the Settings window shows them.

    enum Defaults {
        static let revealDelay: TimeInterval = 0.0
        static let hideDelay: TimeInterval = 0.3
        static let animationDuration: TimeInterval = 0.15
        static let groupHoverDelay: TimeInterval = 0.05
        static let groupHoverCloseGrace: TimeInterval = 0.05
        static let backgroundFrost: Double = 0.5
        static let cornerRadius: CGFloat = 16
        static let magnifiedSize: CGFloat = 64
    }

    static let revealDelayRange: ClosedRange<TimeInterval> = 0...1
    static let hideDelayRange: ClosedRange<TimeInterval> = 0...2
    static let animationDurationRange: ClosedRange<TimeInterval> = 0...0.5

    /// Delay (seconds) before the panel starts revealing after edge detection.
    @Published private(set) var revealDelay: TimeInterval = Defaults.revealDelay

    /// Delay (seconds) after mouse leaves before the panel hides.
    @Published private(set) var hideDelay: TimeInterval = Defaults.hideDelay

    /// Duration (seconds) of the reveal/hide slide animation. 0 is instant.
    @Published private(set) var animationDuration: TimeInterval = Defaults.animationDuration

    /// Sliders call these on every step with `persist: false`, then once with
    /// `persist: true` when the drag ends.
    func setRevealDelay(_ value: TimeInterval, persist shouldPersist: Bool = true) {
        revealDelay = Self.clamp(value, to: Self.revealDelayRange)
        if shouldPersist { persist() }
    }

    func setHideDelay(_ value: TimeInterval, persist shouldPersist: Bool = true) {
        hideDelay = Self.clamp(value, to: Self.hideDelayRange)
        if shouldPersist { persist() }
    }

    func setAnimationDuration(_ value: TimeInterval, persist shouldPersist: Bool = true) {
        animationDuration = Self.clamp(value, to: Self.animationDurationRange)
        if shouldPersist { persist() }
    }

    func resetTimingToDefaults() {
        revealDelay = Defaults.revealDelay
        hideDelay = Defaults.hideDelay
        animationDuration = Defaults.animationDuration
        persist()
    }

    /// Rounded to milliseconds so saved values stay readable.
    private static func clamp(_ value: TimeInterval, to range: ClosedRange<TimeInterval>) -> TimeInterval {
        (min(max(value, range.lowerBound), range.upperBound) * 1000).rounded() / 1000
    }

    // MARK: - Icon settings

    /// Size (points) of dock item icons. Tiles can render smaller when the
    /// strip would not fit on screen.
    @Published private(set) var iconSize: CGFloat = 48.0

    /// Same range as the native Dock's `tilesize`.
    static let iconSizeRange: ClosedRange<CGFloat> = 16...128

    /// Native-style magnification: tiles grow under the cursor (bottom
    /// edge for now).
    @Published private(set) var magnificationEnabled: Bool = false

    func setMagnificationEnabled(_ enabled: Bool) {
        guard enabled != magnificationEnabled else { return }
        magnificationEnabled = enabled
        persist()
    }

    /// Size (points) of the tile right under the cursor while magnifying.
    /// Same range as the native Dock's `largesize`. At or below the icon
    /// size nothing grows.
    @Published private(set) var magnifiedSize: CGFloat = Defaults.magnifiedSize
    static let magnifiedSizeRange: ClosedRange<CGFloat> = 16...128

    func setMagnifiedSize(_ size: CGFloat, persist shouldPersist: Bool = true) {
        let clamped = min(max(size.rounded(), Self.magnifiedSizeRange.lowerBound), Self.magnifiedSizeRange.upperBound)
        if clamped != magnifiedSize { magnifiedSize = clamped }
        if shouldPersist { persist() }
    }

    /// Native "Animate opening applications": a pinned tile bounces while
    /// its app launches (bottom dock only for now).
    @Published private(set) var animateOpeningApplications: Bool = true

    func setAnimateOpeningApplications(_ enabled: Bool) {
        guard enabled != animateOpeningApplications else { return }
        animateOpeningApplications = enabled
        persist()
    }

    // MARK: - Appearance

    @Published private(set) var iconStyle: IconStyle = .matchSystem
    @Published private(set) var backgroundStyle: DockBackgroundStyle = DockBackgroundStyle.systemDefault
    @Published private(set) var backgroundFrost: Double = Defaults.backgroundFrost
    @Published private(set) var backgroundTint: RGBAColor?
    @Published private(set) var cornerRadius: CGFloat = Defaults.cornerRadius

    static let cornerRadiusRange: ClosedRange<CGFloat> = 4...28

    /// The strip and group grid background, in one value.
    var look: DockLook {
        DockLook(style: backgroundStyle, frost: backgroundFrost, tint: backgroundTint, cornerRadius: cornerRadius)
    }

    func setIconStyle(_ style: IconStyle) {
        guard style != iconStyle else { return }
        iconStyle = style
        persist()
    }

    func setBackgroundStyle(_ style: DockBackgroundStyle) {
        guard style != backgroundStyle else { return }
        backgroundStyle = style
        persist()
    }

    func setBackgroundFrost(_ value: Double, persist shouldPersist: Bool = true) {
        backgroundFrost = min(max(value, 0), 1)
        if shouldPersist { persist() }
    }

    func setBackgroundTint(_ tint: RGBAColor?, persist shouldPersist: Bool = true) {
        guard tint != backgroundTint else { return }
        backgroundTint = tint
        if shouldPersist { persist() }
    }

    func setCornerRadius(_ value: CGFloat, persist shouldPersist: Bool = true) {
        cornerRadius = min(max(value, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        if shouldPersist { persist() }
    }

    func resetAppearanceToDefaults() {
        iconStyle = .matchSystem
        backgroundStyle = DockBackgroundStyle.systemDefault
        backgroundFrost = Defaults.backgroundFrost
        backgroundTint = nil
        cornerRadius = Defaults.cornerRadius
        persist()
    }

    // MARK: - Hiding

    /// Native "Automatically hide and show the Dock". Off keeps the dock
    /// revealed all the time.
    @Published private(set) var autoHide: Bool = true

    func setAutoHide(_ enabled: Bool) {
        guard enabled != autoHide else { return }
        autoHide = enabled
        persist()
    }

    // MARK: - Native Dock

    /// "Hide the macOS Dock". Written only by `NativeDockController`, after
    /// the native Dock was actually hidden (or restored).
    @Published private(set) var hideNativeDock: Bool = false

    /// The first-time explanation for `hideNativeDock` was confirmed.
    private(set) var nativeDockExplained: Bool = false

    func setHideNativeDock(_ enabled: Bool) {
        guard enabled != hideNativeDock else { return }
        hideNativeDock = enabled
        persist()
    }

    func markNativeDockExplained() {
        guard !nativeDockExplained else { return }
        nativeDockExplained = true
        persist()
    }

    // MARK: - Groups on hover

    /// Open a group's grid by hovering its tile (after `groupHoverDelay`).
    @Published private(set) var openGroupsOnHover: Bool = false
    @Published private(set) var groupHoverDelay: TimeInterval = Defaults.groupHoverDelay
    static let groupHoverDelayRange: ClosedRange<TimeInterval> = 0...1
    /// Grace after leaving the tile or grid before a hover-opened popover closes.
    @Published private(set) var groupHoverCloseGrace: TimeInterval = Defaults.groupHoverCloseGrace
    static let groupHoverCloseGraceRange: ClosedRange<TimeInterval> = 0...0.5

    func setOpenGroupsOnHover(_ enabled: Bool) {
        guard enabled != openGroupsOnHover else { return }
        openGroupsOnHover = enabled
        persist()
    }

    func setGroupHoverDelay(_ value: TimeInterval, persist shouldPersist: Bool = true) {
        groupHoverDelay = Self.clamp(value, to: Self.groupHoverDelayRange)
        if shouldPersist { persist() }
    }

    func setGroupHoverCloseGrace(_ value: TimeInterval, persist shouldPersist: Bool = true) {
        groupHoverCloseGrace = Self.clamp(value, to: Self.groupHoverCloseGraceRange)
        if shouldPersist { persist() }
    }

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

    // MARK: - Pinned entries

    /// The pinned section in display order: apps and groups.
    @Published private(set) var entries: [DockEntry] = []

    /// Every pinned app, including the ones inside groups.
    var allPinnedApps: [PinnedApp] { entries.flatMap(\.apps) }

    var groups: [FolderGroup] { entries.compactMap(\.group) }

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

    /// Reorder enabled widgets (Settings list drag).
    func moveWidgets(fromOffsets source: IndexSet, toOffset destination: Int) {
        var kinds = widgetKinds
        kinds.move(fromOffsets: source, toOffset: destination)
        guard kinds != widgetKinds else { return }
        widgetKinds = kinds
        persist()
    }

    /// Move one enabled widget earlier (-1) or later (+1).
    func moveWidget(_ kind: String, by offset: Int) {
        guard let index = widgetKinds.firstIndex(of: kind),
              widgetKinds.indices.contains(index + offset) else { return }
        var kinds = widgetKinds
        kinds.swapAt(index, index + offset)
        widgetKinds = kinds
        persist()
    }

    private static let logger = Logger(subsystem: "com.james.portside", category: "DockModel")

    init() {}

    // MARK: - Pinned mutations (each one persists)

    func isPinned(_ app: PinnedApp) -> Bool {
        allPinnedApps.contains { $0.id == app.id }
    }

    /// Pin an app as its own entry at `index` (end if nil). If it is already
    /// pinned, top level or in a group, it moves there.
    func pin(_ app: PinnedApp, at index: Int? = nil) {
        var list = Self.removing(app, from: entries)
        let target = min(max(index ?? list.count, 0), list.count)
        list.insert(.app(app), at: target)
        entries = list
        persist()
    }

    /// Remove an app from the dock, wherever it is. A group left empty goes too.
    func unpin(_ app: PinnedApp) {
        entries = Self.removing(app, from: entries)
        persist()
    }

    /// Move an entry to `index`. Drag reorder calls this on every slot
    /// change with `persist: false`, then `saveOrder()` once on release.
    func move(entryID: String, toIndex index: Int, persist shouldPersist: Bool = true) {
        guard let from = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let to = min(max(index, 0), entries.count - 1)
        guard from != to else { return }
        var list = entries
        let entry = list.remove(at: from)
        list.insert(entry, at: to)
        entries = list
        if shouldPersist { persist() }
    }

    func saveOrder() {
        persist()
    }

    // MARK: - Groups

    /// Replace the app's slot with a new group holding just that app.
    /// Returns the group's id.
    @discardableResult
    func createGroup(with app: PinnedApp) -> String {
        let group = FolderGroup(name: nextGroupName(), apps: [app])
        let slot = entries.firstIndex { $0.apps.contains { $0.id == app.id } } ?? entries.count
        var list = Self.removing(app, from: entries)
        list.insert(.group(group), at: min(slot, list.count))
        entries = list
        persist()
        Self.logger.info("created \(group.name, privacy: .public) with \(app.displayName, privacy: .public)")
        groupCreated.send(group.id)
        return group.id
    }

    /// Emits a group's id right after `createGroup` made it, so the dock can
    /// prompt for its name.
    let groupCreated = PassthroughSubject<String, Never>()

    /// Move an app into a group (appended). Works for top level apps, apps in
    /// another group, and running apps that are not pinned yet.
    func addToGroup(_ app: PinnedApp, groupID: String) {
        var list = Self.removing(app, from: entries)
        guard let index = list.firstIndex(where: { $0.group?.id == groupID }),
              var group = list[index].group else { return }
        group.apps.append(app)
        list[index] = .group(group)
        entries = list
        persist()
    }

    /// Take an app out of its group and put it back on the dock right after
    /// the group. A group left empty is removed.
    func removeFromGroup(_ app: PinnedApp, groupID: String) {
        guard let index = entries.firstIndex(where: { $0.group?.id == groupID }),
              var group = entries[index].group else { return }
        group.apps.removeAll { $0.id == app.id }
        var list = entries
        if group.apps.isEmpty {
            list[index] = .app(app)
        } else {
            list[index] = .group(group)
            list.insert(.app(app), at: index + 1)
        }
        entries = list
        persist()
    }

    /// Replace the group with its apps, in place.
    func ungroup(groupID: String) {
        guard let index = entries.firstIndex(where: { $0.group?.id == groupID }),
              let group = entries[index].group else { return }
        var list = entries
        list.replaceSubrange(index...index, with: group.apps.map(DockEntry.app))
        entries = list
        persist()
    }

    /// Rename a group. Blank names are ignored (the old name stays).
    func renameGroup(groupID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = entries.firstIndex(where: { $0.group?.id == groupID }),
              var group = entries[index].group, group.name != trimmed else { return }
        group.name = trimmed
        var list = entries
        list[index] = .group(group)
        entries = list
        persist()
    }

    /// Remove the group and its apps from the dock.
    func removeGroup(groupID: String) {
        entries.removeAll { $0.group?.id == groupID }
        persist()
    }

    private func nextGroupName() -> String {
        let used = Set(groups.map(\.name))
        var n = 1
        while used.contains("Group \(n)") { n += 1 }
        return "Group \(n)"
    }

    /// The list without `app`, wherever it was. Groups left empty are dropped.
    private static func removing(_ app: PinnedApp, from list: [DockEntry]) -> [DockEntry] {
        list.compactMap { entry in
            switch entry {
            case .app(let other):
                return other.id == app.id ? nil : entry
            case .group(var group):
                group.apps.removeAll { $0.id == app.id }
                return group.apps.isEmpty ? nil : .group(group)
            }
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case revealDelay, hideDelay, animationDuration, iconSize, magnificationEnabled, magnifiedSize, edge, entries, widgetKinds
        case autoHide, openGroupsOnHover, groupHoverDelay, groupHoverCloseGrace
        case animateOpeningApplications
        case hideNativeDock, nativeDockExplained
        case iconStyle, backgroundStyle, backgroundFrost, backgroundTint, cornerRadius
        /// Before Milestone D: a flat list of apps. Read only, for migration.
        case pinnedApps
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revealDelay = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .revealDelay) ?? Defaults.revealDelay, to: Self.revealDelayRange)
        hideDelay = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .hideDelay) ?? Defaults.hideDelay, to: Self.hideDelayRange)
        animationDuration = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .animationDuration) ?? Defaults.animationDuration, to: Self.animationDurationRange)
        iconSize = try c.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 48.0
        magnificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .magnificationEnabled) ?? false
        let magnified = (try? c.decodeIfPresent(CGFloat.self, forKey: .magnifiedSize)) ?? Defaults.magnifiedSize
        magnifiedSize = min(max(magnified, Self.magnifiedSizeRange.lowerBound), Self.magnifiedSizeRange.upperBound)
        edge = (try? c.decodeIfPresent(DockEdge.self, forKey: .edge)) ?? .bottom
        if let saved = try c.decodeIfPresent([DockEntry].self, forKey: .entries) {
            entries = saved
        } else if let apps = try c.decodeIfPresent([PinnedApp].self, forKey: .pinnedApps) {
            entries = apps.map(DockEntry.app)
        } else {
            entries = DockModel.seedFromNativeDock().map(DockEntry.app)
        }
        widgetKinds = try c.decodeIfPresent([String].self, forKey: .widgetKinds) ?? WidgetCatalog.defaultKinds
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? true
        animateOpeningApplications = try c.decodeIfPresent(Bool.self, forKey: .animateOpeningApplications) ?? true
        hideNativeDock = try c.decodeIfPresent(Bool.self, forKey: .hideNativeDock) ?? false
        nativeDockExplained = try c.decodeIfPresent(Bool.self, forKey: .nativeDockExplained) ?? false
        openGroupsOnHover = try c.decodeIfPresent(Bool.self, forKey: .openGroupsOnHover) ?? false
        groupHoverDelay = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .groupHoverDelay) ?? Defaults.groupHoverDelay, to: Self.groupHoverDelayRange)
        groupHoverCloseGrace = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .groupHoverCloseGrace) ?? Defaults.groupHoverCloseGrace, to: Self.groupHoverCloseGraceRange)
        // try? per key: an unknown enum value (from a newer build) falls back
        // to the default instead of failing the whole file.
        iconStyle = (try? c.decodeIfPresent(IconStyle.self, forKey: .iconStyle)) ?? .matchSystem
        backgroundStyle = (try? c.decodeIfPresent(DockBackgroundStyle.self, forKey: .backgroundStyle)) ?? DockBackgroundStyle.systemDefault
        backgroundFrost = min(max((try? c.decodeIfPresent(Double.self, forKey: .backgroundFrost)) ?? Defaults.backgroundFrost, 0), 1)
        backgroundTint = (try? c.decodeIfPresent(RGBAColor.self, forKey: .backgroundTint)) ?? nil
        let radius = (try? c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)) ?? Defaults.cornerRadius
        cornerRadius = min(max(radius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revealDelay, forKey: .revealDelay)
        try c.encode(hideDelay, forKey: .hideDelay)
        try c.encode(animationDuration, forKey: .animationDuration)
        try c.encode(iconSize, forKey: .iconSize)
        try c.encode(magnificationEnabled, forKey: .magnificationEnabled)
        try c.encode(magnifiedSize, forKey: .magnifiedSize)
        try c.encode(edge, forKey: .edge)
        try c.encode(entries, forKey: .entries)
        try c.encode(widgetKinds, forKey: .widgetKinds)
        try c.encode(autoHide, forKey: .autoHide)
        try c.encode(animateOpeningApplications, forKey: .animateOpeningApplications)
        try c.encode(hideNativeDock, forKey: .hideNativeDock)
        try c.encode(nativeDockExplained, forKey: .nativeDockExplained)
        try c.encode(openGroupsOnHover, forKey: .openGroupsOnHover)
        try c.encode(groupHoverDelay, forKey: .groupHoverDelay)
        try c.encode(groupHoverCloseGrace, forKey: .groupHoverCloseGrace)
        try c.encode(iconStyle, forKey: .iconStyle)
        try c.encode(backgroundStyle, forKey: .backgroundStyle)
        try c.encode(backgroundFrost, forKey: .backgroundFrost)
        try c.encodeIfPresent(backgroundTint, forKey: .backgroundTint)
        try c.encode(cornerRadius, forKey: .cornerRadius)
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
            DockModel.logger.info("saved \(self.entries.count) entries (\(self.allPinnedApps.count) apps, \(self.groups.count) groups)")
        } catch {
            DockModel.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load from disk. On first launch (no file), seed pinned apps from the
    /// native Dock and save immediately so later launches use Portside's list.
    static func load() -> DockModel {
        if let data = try? Data(contentsOf: storageURL),
           let model = try? JSONDecoder().decode(DockModel.self, from: data) {
            logger.info("loaded \(model.entries.count) entries (\(model.allPinnedApps.count) apps, \(model.groups.count) groups) from dock.json")
            return model
        }
        let model = DockModel()
        let native = NativeDockImport.readSnapshot()
        model.entries = native.apps.map(DockEntry.app)
        model.edge = native.edge
        model.iconSize = NativeDockImport.clampedIconSize(
            native.tileSize, edge: native.edge, itemCount: model.entries.count, widgetKinds: model.widgetKinds.count
        )
        model.persist()
        logger.info("first launch: seeded \(model.entries.count) pinned apps, edge \(native.edge.rawValue, privacy: .public), icon size \(Double(model.iconSize), format: .fixed(precision: 0)) from the native Dock")
        return model
    }

    /// Read (never write) the native Dock's pinned apps, with Finder first
    /// like the real Dock.
    static func seedFromNativeDock() -> [PinnedApp] {
        NativeDockImport.readSnapshot().apps
    }

    // MARK: - Import from the native Dock

    struct ImportResult {
        var added = 0
        /// Replace mode: apps already inside a group, left there.
        var inGroups = 0
        /// Replace mode: top level apps that were dropped.
        var removed = 0
        var appliedLook = false
    }

    static var beforeImportURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("dock.json.before-import")
    }

    static var hasBeforeImport: Bool {
        FileManager.default.fileExists(atPath: beforeImportURL.path)
    }

    /// Copy dock.json to dock.json.before-import (overwriting the last one),
    /// then apply. Nothing changes if the copy fails. Groups, widgets,
    /// separators and all other settings are never touched.
    func importFromNativeDock(_ native: NativeDockSnapshot, replace: Bool, applyLook: Bool, fitTileSize: CGFloat?) throws -> ImportResult {
        try save() // the file must match memory (slider drags persist late)
        let backup = Self.beforeImportURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: Self.storageURL, to: backup)

        var result = ImportResult()
        var list = entries
        if replace {
            let grouped = Set(groups.flatMap(\.apps).map(\.id))
            let incoming = native.apps.filter { !grouped.contains($0.id) }
            result.inGroups = native.apps.count - incoming.count
            result.removed = list.filter { if case .app = $0 { return true } else { return false } }.count
            result.added = incoming.count
            // Groups keep their slots (capped at the new length).
            var merged = incoming.map(DockEntry.app)
            for (index, entry) in list.enumerated() where entry.group != nil {
                merged.insert(entry, at: min(index, merged.count))
            }
            list = merged
        } else {
            let have = Set(allPinnedApps.map(\.id))
            let new = native.apps.filter { !have.contains($0.id) }
            list.append(contentsOf: new.map(DockEntry.app))
            result.added = new.count
        }
        entries = list

        if applyLook {
            edge = native.edge
            iconSize = NativeDockImport.clampedIconSize(
                native.tileSize, edge: native.edge, itemCount: entries.count, widgetKinds: widgetKinds.count, fit: fitTileSize
            )
            result.appliedLook = true
        }
        persist()
        importLogger.info("import: \(replace ? "replace" : "add missing", privacy: .public), added \(result.added), removed \(result.removed), left in groups \(result.inGroups), look \(result.appliedLook)")
        return result
    }

    /// Restore dock.json.before-import live, then delete it. The two native
    /// Dock hiding flags stay as they are: they describe the real Dock now.
    func undoLastImport() throws {
        let data = try Data(contentsOf: Self.beforeImportURL)
        let old = try JSONDecoder().decode(DockModel.self, from: data)
        revealDelay = old.revealDelay
        hideDelay = old.hideDelay
        animationDuration = old.animationDuration
        iconSize = old.iconSize
        magnificationEnabled = old.magnificationEnabled
        magnifiedSize = old.magnifiedSize
        animateOpeningApplications = old.animateOpeningApplications
        autoHide = old.autoHide
        openGroupsOnHover = old.openGroupsOnHover
        groupHoverDelay = old.groupHoverDelay
        groupHoverCloseGrace = old.groupHoverCloseGrace
        edge = old.edge
        entries = old.entries
        widgetKinds = old.widgetKinds
        persist()
        try? FileManager.default.removeItem(at: Self.beforeImportURL)
        importLogger.info("import: undone, restored \(old.entries.count) entries from dock.json.before-import")
    }
}
