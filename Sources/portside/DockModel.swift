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
        static let usageProviders = ["claude", "codex"]
        static let hideDelay: TimeInterval = 0.3
        static let animationDuration: TimeInterval = 0.15
        static let groupHoverDelay: TimeInterval = 0.05
        static let groupHoverCloseGrace: TimeInterval = 0.05
        /// The native Dock's radius at its default height, measured.
        static let cornerRadius: CGFloat = 14
        static let magnifiedSize: CGFloat = 64
        /// Gap between strip tiles. Matches the long-standing DockMetrics default.
        static let iconGap: CGFloat = 6
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

    /// Gap (points) between strip tiles along the dock. Side docks use the
    /// same value down the column. Small range: a slight tweak only.
    @Published private(set) var iconGap: CGFloat = Defaults.iconGap
    static let iconGapRange: ClosedRange<CGFloat> = 0...8

    func setIconGap(_ gap: CGFloat, persist shouldPersist: Bool = true) {
        let clamped = min(max(gap.rounded(), Self.iconGapRange.lowerBound), Self.iconGapRange.upperBound)
        if clamped != iconGap { iconGap = clamped }
        if shouldPersist { persist() }
    }

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

    // MARK: - Native Dock options

    /// Native "Show indicators for open applications".
    @Published private(set) var showIndicators = true
    /// Native hidden option `showhidden`: icons of hidden apps are drawn
    /// translucent.
    @Published private(set) var dimHiddenApps = false
    /// Native "Show suggested and recent apps in Dock".
    @Published private(set) var showRecents = true
    /// Most recent first. Apps that quit while not pinned, like the native
    /// Dock's recents section.
    @Published private(set) var recentApps: [PinnedApp] = []

    static let recentAppsLimit = 3

    func setShowIndicators(_ enabled: Bool) {
        guard enabled != showIndicators else { return }
        showIndicators = enabled
        persist()
    }

    func setDimHiddenApps(_ enabled: Bool) {
        guard enabled != dimHiddenApps else { return }
        dimHiddenApps = enabled
        persist()
    }

    func setShowRecents(_ enabled: Bool) {
        guard enabled != showRecents else { return }
        showRecents = enabled
        persist()
    }

    /// A regular app quit. Remember it unless it is pinned (anywhere,
    /// including groups).
    func noteAppQuit(_ app: PinnedApp) {
        guard !allPinnedApps.contains(where: { $0.id == app.id }) else { return }
        var next = recentApps.filter { $0.id != app.id }
        next.insert(app, at: 0)
        next = Array(next.prefix(Self.recentAppsLimit))
        guard next != recentApps else { return }
        recentApps = next
        persist()
    }

    // MARK: - Appearance

    @Published private(set) var iconStyle: IconStyle = .matchSystem
    /// Selected background style plus each style's own settings.
    @Published private(set) var background = DockBackground()
    @Published private(set) var cornerRadius: CGFloat = Defaults.cornerRadius
    /// Mirrors Accessibility > Display > Reduce Transparency for live redraws.
    @Published private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    /// Mirrors the System Settings Liquid Glass slider for live redraws.
    @Published private(set) var systemGlassTint = NativeDockGlass.systemTint

    static let cornerRadiusRange: ClosedRange<CGFloat> = 4...28

    /// The strip and group grid background, in one value.
    var look: DockLook {
        DockLook(background: background, cornerRadius: cornerRadius, reduceTransparency: reduceTransparency, systemGlassTint: systemGlassTint)
    }

    func syncSystemGlassTint() {
        let next = NativeDockGlass.systemTint
        guard next != systemGlassTint else { return }
        systemGlassTint = next
        DockModel.logger.info("Liquid Glass slider \(next, format: .fixed(precision: 2))")
    }

    func syncReduceTransparency() {
        let next = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard next != reduceTransparency else { return }
        reduceTransparency = next
        DockModel.logger.info("Reduce Transparency \(next ? "on" : "off", privacy: .public)")
    }

    func setIconStyle(_ style: IconStyle) {
        guard style != iconStyle else { return }
        iconStyle = style
        persist()
    }

    /// Change any background setting. Sliders pass `persist: false` while
    /// dragging and save once on release.
    func updateBackground(persist shouldPersist: Bool = true, _ change: (inout DockBackground) -> Void) {
        var next = background
        change(&next)
        guard next != background else {
            if shouldPersist { persist() }
            return
        }
        background = next
        if shouldPersist { persist() }
    }

    /// Current style's settings and the corner radius back to defaults.
    /// Other styles keep theirs.
    func resetBackgroundStyleToDefaults() {
        updateBackground(persist: false) { bg in
            switch bg.style {
            case .glass:
                // Back to the macOS values, staying on Custom if that is selected.
                let variant = bg.glass.variant
                bg.glass = GlassBackground()
                bg.glass.variant = variant
            case .solid: bg.solid = SolidBackground()
            }
        }
        cornerRadius = Defaults.cornerRadius
        persist()
    }

    func resetAppearanceToDefaults() {
        iconStyle = .matchSystem
        background = DockBackground()
        cornerRadius = Defaults.cornerRadius
        persist()
    }

    func setCornerRadius(_ value: CGFloat, persist shouldPersist: Bool = true) {
        cornerRadius = min(max(value, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        if shouldPersist { persist() }
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

    /// With hiding off, keep other apps' windows out of the dock's space
    /// (like the native Dock). Needs Accessibility.
    @Published private(set) var reserveSpace: Bool = true

    func setReserveSpace(_ enabled: Bool) {
        guard enabled != reserveSpace else { return }
        reserveSpace = enabled
        persist()
    }

    // MARK: - Keyboard

    /// Global shortcut that opens Settings. Nil means none is registered.
    /// Default is Command-Shift-D (see `HotkeyChord.settingsDefault`).
    @Published private(set) var settingsHotkey: HotkeyChord? = .settingsDefault

    func setSettingsHotkey(_ chord: HotkeyChord?) {
        let next: HotkeyChord?
        if let chord {
            next = chord.isRegisterable ? chord : settingsHotkey
        } else {
            next = nil
        }
        guard next != settingsHotkey else { return }
        settingsHotkey = next
        persist()
    }

    // MARK: - Trash

    /// "Show Trash in dock": the Trash tile at the far end of the dock.
    @Published private(set) var showTrash: Bool = true

    /// The Full Disk Access hint in Settings was dismissed (or its button
    /// used). It is shown once and never again on its own.
    @Published private(set) var trashAccessHintDismissed: Bool = false

    /// Draw notification badges, the same ones the native Dock shows.
    @Published private(set) var showBadges: Bool = true

    func setShowTrash(_ enabled: Bool) {
        guard enabled != showTrash else { return }
        showTrash = enabled
        persist()
    }

    func dismissTrashAccessHint() {
        guard !trashAccessHintDismissed else { return }
        trashAccessHintDismissed = true
        persist()
    }

    /// Badge fill (Settings > Appearance > Badges).
    @Published private(set) var badgeColor: BadgeColor = .macOS
    /// Used when `badgeColor` is `.custom`. Kept when switching away, so
    /// switching back restores it.
    @Published private(set) var badgeCustomColor: PaletteColor = BadgeColor.defaultCustom

    var badgeStyle: BadgeStyle { BadgeStyle(fill: badgeColor.fill(custom: badgeCustomColor)) }

    func setBadgeColor(_ color: BadgeColor) {
        guard color != badgeColor else { return }
        badgeColor = color
        persist()
    }

    func setBadgeCustomColor(_ color: PaletteColor, persist shouldPersist: Bool = true) {
        if color != badgeCustomColor { badgeCustomColor = color }
        if badgeColor != .custom { badgeColor = .custom }
        if shouldPersist { persist() }
    }

    func setShowBadges(_ enabled: Bool) {
        guard enabled != showBadges else { return }
        showBadges = enabled
        persist()
    }

    // MARK: - Activity icons

    /// Small icons for apps using the mic or camera, playing audio, or
    /// working (see `AppActivity`).
    @Published private(set) var activityIcons = ActivityIconSettings()

    func setActivityIcons(_ next: ActivityIconSettings) {
        guard next != activityIcons else { return }
        activityIcons = next
        persist()
    }

    func watchesWorking(_ app: PinnedApp) -> Bool {
        app.bundleIdentifier.map(activityIcons.workingApps.contains) ?? false
    }

    /// Right-click "Show Working Icon".
    func setWatchesWorking(_ app: PinnedApp, _ on: Bool) {
        guard let id = app.bundleIdentifier else { return }
        var next = activityIcons
        next.workingApps.removeAll { $0 == id }
        if on { next.workingApps.append(id) }
        setActivityIcons(next)
    }

    // MARK: - Layout (where everything sits)

    /// The order of everything on the dock, left to right (top to bottom on
    /// a side dock): item ids from `entries` (apps, groups, spacers),
    /// `widget:<kind>`, `stack:<id>`, `trash`, `running` (the unpinned
    /// running apps), and `separator:<id>`. Empty means the default look:
    /// apps, running apps, widgets, folders, Trash, with separators between
    /// the sections. Items that appear later are slotted in next to their
    /// own kind, so a saved layout never goes stale.
    @Published private(set) var layout: [String] = []

    static let trashID = "trash"
    static let runningID = "running"
    static let separatorPrefix = "separator:"

    /// `layout` checked against what exists now: stale ids dropped, new items
    /// placed beside their own kind, the default when nothing was saved.
    func resolvedLayout() -> [String] {
        let entryIDs = entries.map(\.id)
        let widgetIDs = widgetKinds.map { "widget:" + $0 }
        let stackIDs = stacks.map(\.hoverID)
        guard !layout.isEmpty else {
            var list = entryIDs + [Self.runningID]
            let rightSection = !widgetIDs.isEmpty || !stackIDs.isEmpty || showTrash
            if rightSection { list.append(Self.separatorPrefix + "default-1") }
            list += widgetIDs
            if !widgetIDs.isEmpty && (!stackIDs.isEmpty || showTrash) { list.append(Self.separatorPrefix + "default-2") }
            list += stackIDs
            if showTrash { list.append(Self.trashID) }
            return list
        }
        var valid = Set(entryIDs + widgetIDs + stackIDs)
        valid.insert(Self.runningID)
        if showTrash { valid.insert(Self.trashID) }
        var seen = Set<String>()
        var list = layout.filter { (valid.contains($0) || $0.hasPrefix(Self.separatorPrefix)) && seen.insert($0).inserted }

        func place(_ id: String, after previous: String?, before next: String?, fallback: Int) {
            guard !list.contains(id) else { return }
            if let previous, let i = list.firstIndex(of: previous) {
                list.insert(id, at: i + 1)
            } else if let next, let i = list.firstIndex(of: next) {
                list.insert(id, at: i)
            } else {
                list.insert(id, at: min(fallback, list.count))
            }
        }
        for (i, id) in entryIDs.enumerated() {
            place(id, after: i > 0 ? entryIDs[i - 1] : nil,
                  before: entryIDs.dropFirst(i + 1).first { list.contains($0) }, fallback: 0)
        }
        place(Self.runningID, after: entryIDs.last, before: nil, fallback: 0)
        let trashIDs = showTrash ? [Self.trashID] : []
        for (i, id) in widgetIDs.enumerated() {
            let next = (widgetIDs.dropFirst(i + 1) + stackIDs + trashIDs).first { list.contains($0) }
            place(id, after: i > 0 ? widgetIDs[i - 1] : nil, before: next, fallback: list.count)
        }
        for (i, id) in stackIDs.enumerated() {
            let next = (stackIDs.dropFirst(i + 1) + trashIDs).first { list.contains($0) }
            place(id, after: i > 0 ? stackIDs[i - 1] : nil, before: next, fallback: list.count)
        }
        if showTrash { place(Self.trashID, after: nil, before: nil, fallback: list.count) }
        return list
    }

    func layoutIndex(of id: String) -> Int? {
        resolvedLayout().firstIndex(of: id)
    }

    /// Moves an item to a slot (index in `resolvedLayout()`). Returns whether
    /// anything moved. Saved only with `persist` (a drag saves on release).
    @discardableResult
    func moveLayoutItem(_ id: String, toIndex index: Int, persist shouldPersist: Bool = true) -> Bool {
        var list = resolvedLayout()
        guard let from = list.firstIndex(of: id) else { return false }
        let item = list.remove(at: from)
        let to = min(max(index, 0), list.count)
        list.insert(item, at: to)
        guard list != resolvedLayout() else { return false }
        commitLayout(list, persist: shouldPersist)
        return true
    }

    /// Moves an item into the slot another item holds (after it when moving
    /// toward the end, before it when moving toward the start).
    @discardableResult
    func moveLayoutItem(_ id: String, toSlotOf other: String, persist shouldPersist: Bool = true) -> Bool {
        let list = resolvedLayout()
        guard id != other, let target = list.firstIndex(of: other) else { return false }
        return moveLayoutItem(id, toIndex: target, persist: shouldPersist)
    }

    func addSeparator() {
        var list = resolvedLayout()
        list.append(Self.separatorPrefix + UUID().uuidString)
        commitLayout(list, persist: true)
    }

    func removeSeparator(id: String) {
        var list = resolvedLayout()
        guard list.contains(id), id.hasPrefix(Self.separatorPrefix) else { return }
        list.removeAll { $0 == id }
        commitLayout(list, persist: true)
    }

    /// Back to the default arrangement (apps, running apps, widgets, folders,
    /// Trash). The order of apps, widgets and folders among themselves stays.
    func resetLayout() {
        guard !layout.isEmpty else { return }
        layout = []
        persist()
    }

    /// Stores `list` and keeps the per-kind arrays in the same order.
    private func commitLayout(_ list: [String], persist shouldPersist: Bool) {
        layout = list
        let rank = Dictionary(list.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let sortedEntries = entries.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        if sortedEntries.map(\.id) != entries.map(\.id) { entries = sortedEntries }
        let sortedStacks = stacks.sorted { (rank[$0.hoverID] ?? .max) < (rank[$1.hoverID] ?? .max) }
        if sortedStacks.map(\.id) != stacks.map(\.id) { stacks = sortedStacks }
        let sortedKinds = widgetKinds.sorted { (rank["widget:" + $0] ?? .max) < (rank["widget:" + $1] ?? .max) }
        if sortedKinds != widgetKinds { widgetKinds = sortedKinds }
        if shouldPersist { persist() }
    }

    /// An order changed somewhere else (Settings widget list, stack moves):
    /// keep a saved layout in step by refilling that kind's slots in the new
    /// order.
    private func syncLayout(toOrderOf ids: [String]) {
        guard !layout.isEmpty else { return }
        var list = resolvedLayout()
        let set = Set(ids)
        var queue = ids.filter { list.contains($0) }[...]
        for i in list.indices where set.contains(list[i]) {
            guard let next = queue.popFirst() else { break }
            list[i] = next
        }
        layout = list
    }

    // MARK: - Folder stacks

    /// Filesystem folder stacks in the right section (before Trash), in order.
    @Published private(set) var stacks: [FolderStack] = []

    /// Pins a folder as a stack. No-ops if the path is already pinned or not a folder.
    /// `index` is clamped into the stacks list (nil appends).
    @discardableResult
    func addStack(folderURL: URL, at index: Int? = nil) -> FolderStack? {
        guard let stack = FolderStack(folderURL: folderURL) else { return nil }
        if stacks.contains(where: { $0.path == stack.path }) { return nil }
        var list = stacks
        let at = min(max(index ?? list.count, 0), list.count)
        list.insert(stack, at: at)
        stacks = list
        persist()
        return stack
    }

    func removeStack(id: String) {
        let before = stacks.count
        stacks.removeAll { $0.id == id }
        guard stacks.count != before else { return }
        persist()
    }

    func moveStack(id: String, toIndex index: Int, persist shouldPersist: Bool = true) {
        guard let from = stacks.firstIndex(where: { $0.id == id }) else { return }
        var list = stacks
        let item = list.remove(at: from)
        list.insert(item, at: min(max(index, 0), list.count))
        guard list != stacks else { return }
        stacks = list
        syncLayout(toOrderOf: list.map(\.hoverID))
        if shouldPersist { persist() }
    }

    /// Changes one stack's view, sort, or filter settings and saves.
    func updateStack(id: String, _ change: (inout FolderStack) -> Void) {
        guard let i = stacks.firstIndex(where: { $0.id == id }) else { return }
        var stack = stacks[i]
        change(&stack)
        guard stack != stacks[i] else { return }
        stacks[i] = stack
        persist()
    }

    func replaceStacks(_ newStacks: [FolderStack]) {
        stacks = newStacks
        persist()
    }

    /// Inserts `names` (child `lastPathComponent`s) into a stack's display
    /// order at `index`. Seeds from `seed` when the stack had no custom order.
    func insertStackItemOrder(stackID: String, names: [String], at index: Int, seed: [String]) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        var stack = stacks[i]
        var order = stack.itemOrder.isEmpty ? seed : stack.itemOrder
        // Drop names already listed so a re-drop moves them.
        order.removeAll { names.contains($0) }
        let at = min(max(index, 0), order.count)
        order.insert(contentsOf: names, at: at)
        stack.itemOrder = order
        stacks[i] = stack
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

    // MARK: - Startup

    /// Open Settings when Portside launches. Off by default.
    @Published private(set) var openSettingsOnLaunch: Bool = false

    func setOpenSettingsOnLaunch(_ enabled: Bool) {
        guard enabled != openSettingsOnLaunch else { return }
        openSettingsOnLaunch = enabled
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
            let order = WidgetCatalog.allKinds
            let position = order.firstIndex(of: kind) ?? order.count
            let insertAt = kinds.firstIndex { (order.firstIndex(of: $0) ?? order.count) > position } ?? kinds.count
            kinds.insert(kind, at: insertAt)
        }
        widgetKinds = kinds
        persist()
    }

    /// Per-widget size on the bottom dock, by kind. Only sizes that differ
    /// from the widget's own design are stored. Side docks always use Small.
    @Published private(set) var widgetSizes: [String: WidgetSize] = [:]

    func setWidgetSize(_ kind: String, _ size: WidgetSize) {
        let stored: WidgetSize? = size == WidgetCatalog.naturalSize(kind) ? nil : size
        guard widgetSizes[kind] != stored else { return }
        widgetSizes[kind] = stored
        persist()
    }

    /// Providers the Usage widget tracks (`AgentProvider` ids), in order.
    @Published var usageProviders: [String] = DockModel.Defaults.usageProviders

    /// The user agreed to let Portside read Claude Code's sign-in token from
    /// the keychain and send it to Anthropic. Until then the Claude meter
    /// reads nothing and sends nothing.
    @Published private(set) var usageClaudeConsent = false

    /// The user agreed to let Portside ask GitHub for their Copilot quota,
    /// through the Copilot CLI or the GitHub CLI's token. Until then the
    /// Copilot meter runs nothing and sends nothing.
    @Published private(set) var usageCopilotConsent = false

    /// Whether this provider's meter may read and send. Codex is local only.
    func usageAllowed(_ id: String) -> Bool {
        switch id {
        case "claude": usageClaudeConsent
        case "copilot": usageCopilotConsent
        default: true
        }
    }

    func setUsageConsent(_ id: String, granted: Bool) {
        guard granted != usageAllowed(id) else { return }
        switch id {
        case "claude": usageClaudeConsent = granted
        case "copilot": usageCopilotConsent = granted
        default: return
        }
        persist()
    }

    func setUsageProvider(_ id: String, enabled: Bool) {
        var next = usageProviders.filter { $0 != id }
        if enabled {
            next.append(id)
            let order = AgentProvider.all.map(\.id)
            next.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        }
        usageProviders = next
        persist()
    }

    /// What a widget shows at on `edge`.
    func widgetSize(for kind: String, natural: WidgetSize, edge: DockEdge) -> WidgetSize {
        edge.isVertical ? .small : WidgetSize.resolved(widgetSizes[kind], natural: natural)
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
        syncLayout(toOrderOf: list.map(\.id))
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

    /// Move an app into a group. `at` is the member index (nil appends).
    /// Works for top level apps, apps in another group, and unpinned apps.
    func addToGroup(_ app: PinnedApp, groupID: String, at index: Int? = nil) {
        var list = Self.removing(app, from: entries)
        guard let gi = list.firstIndex(where: { $0.group?.id == groupID }),
              var group = list[gi].group else { return }
        let at = min(max(index ?? group.apps.count, 0), group.apps.count)
        group.apps.insert(app, at: at)
        list[gi] = .group(group)
        entries = list
        persist()
    }

    /// Reorder a member inside its group. `toIndex` is among the current
    /// members (the app is removed first, then inserted). No-op if the app
    /// is not in that group.
    func moveInGroup(appID: String, groupID: String, toIndex: Int, persist shouldPersist: Bool = true) {
        guard let gi = entries.firstIndex(where: { $0.group?.id == groupID }),
              var group = entries[gi].group,
              let from = group.apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = group.apps.remove(at: from)
        let to = min(max(toIndex, 0), group.apps.count)
        group.apps.insert(app, at: to)
        var list = entries
        list[gi] = .group(group)
        entries = list
        if shouldPersist { persist() }
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

    /// Set or clear (nil) a group's custom tile icon.
    /// Slider drags pass `persist: false` until release.
    func setGroupIcon(groupID: String, to icon: GroupIcon?, persist shouldPersist: Bool = true) {
        guard let index = entries.firstIndex(where: { $0.group?.id == groupID }),
              var group = entries[index].group else { return }
        if group.icon != icon {
            group.icon = icon
            var list = entries
            list[index] = .group(group)
            entries = list
        }
        guard shouldPersist else { return }
        persist()
        Self.logger.info("group icon \(group.name, privacy: .public): \(icon?.symbol ?? "apps", privacy: .public) \(icon?.color.resolved.hex ?? "", privacy: .public)")
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
            case .spacer:
                return entry
            }
        }
    }

    /// Insert a spacer in the pinned section (at the end if `index` is nil).
    @discardableResult
    func addSpacer(_ size: DockSpacer.Size, at index: Int? = nil) -> DockSpacer {
        let spacer = DockSpacer(size: size)
        var list = entries
        let at = min(max(index ?? list.count, 0), list.count)
        list.insert(.spacer(spacer), at: at)
        entries = list
        persist()
        return spacer
    }

    func removeSpacer(id: String) {
        let before = entries.count
        entries.removeAll { $0.spacer?.id == id }
        guard entries.count != before else { return }
        persist()
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey, CaseIterable {
        /// App version that last wrote the file. Lets a downgrade back the file up first.
        case savedByVersion
        case revealDelay, hideDelay, animationDuration, iconSize, iconGap, magnificationEnabled, magnifiedSize, edge, entries, widgetKinds
        case autoHide, reserveSpace, openGroupsOnHover, groupHoverDelay, groupHoverCloseGrace
        case animateOpeningApplications
        case hideNativeDock, nativeDockExplained, openSettingsOnLaunch
        case showTrash, trashAccessHintDismissed
        case showBadges, badgeColor, badgeCustomColor
        case activityIcons
        case stacks, layout, widgetSizes, usageProviders, usageClaudeConsent, usageCopilotConsent
        case iconStyle, background, cornerRadius
        case showIndicators, dimHiddenApps, showRecents, recentApps
        /// Before per-style backgrounds. Read only, for migration.
        case backgroundStyle, backgroundFrost, backgroundTint
        case settingsHotkey
        /// Before Milestone D: a flat list of apps. Read only, for migration.
        case pinnedApps
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revealDelay = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .revealDelay) ?? Defaults.revealDelay, to: Self.revealDelayRange)
        hideDelay = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .hideDelay) ?? Defaults.hideDelay, to: Self.hideDelayRange)
        animationDuration = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .animationDuration) ?? Defaults.animationDuration, to: Self.animationDurationRange)
        iconSize = try c.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 48.0
        let gap = (try? c.decodeIfPresent(CGFloat.self, forKey: .iconGap)) ?? Defaults.iconGap
        iconGap = min(max(gap.rounded(), Self.iconGapRange.lowerBound), Self.iconGapRange.upperBound)
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
        reserveSpace = try c.decodeIfPresent(Bool.self, forKey: .reserveSpace) ?? true
        animateOpeningApplications = try c.decodeIfPresent(Bool.self, forKey: .animateOpeningApplications) ?? true
        hideNativeDock = try c.decodeIfPresent(Bool.self, forKey: .hideNativeDock) ?? false
        nativeDockExplained = try c.decodeIfPresent(Bool.self, forKey: .nativeDockExplained) ?? false
        showTrash = (try? c.decodeIfPresent(Bool.self, forKey: .showTrash)) ?? true
        trashAccessHintDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .trashAccessHintDismissed)) ?? false
        showBadges = (try? c.decodeIfPresent(Bool.self, forKey: .showBadges)) ?? true
        badgeColor = (try? c.decodeIfPresent(BadgeColor.self, forKey: .badgeColor)) ?? .macOS
        badgeCustomColor = (try? c.decodeIfPresent(PaletteColor.self, forKey: .badgeCustomColor)) ?? BadgeColor.defaultCustom
        activityIcons = c.value(.activityIcons, or: ActivityIconSettings())
        stacks = (try? c.decodeIfPresent([FolderStack].self, forKey: .stacks)) ?? []
        layout = (try? c.decodeIfPresent([String].self, forKey: .layout)) ?? []
        widgetSizes = (try? c.decodeIfPresent([String: WidgetSize].self, forKey: .widgetSizes)) ?? [:]
        usageProviders = (try? c.decodeIfPresent([String].self, forKey: .usageProviders)) ?? Defaults.usageProviders
        usageClaudeConsent = try c.decodeIfPresent(Bool.self, forKey: .usageClaudeConsent) ?? false
        usageCopilotConsent = try c.decodeIfPresent(Bool.self, forKey: .usageCopilotConsent) ?? false
        openGroupsOnHover = try c.decodeIfPresent(Bool.self, forKey: .openGroupsOnHover) ?? false
        openSettingsOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .openSettingsOnLaunch) ?? false
        groupHoverDelay = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .groupHoverDelay) ?? Defaults.groupHoverDelay, to: Self.groupHoverDelayRange)
        groupHoverCloseGrace = Self.clamp(try c.decodeIfPresent(TimeInterval.self, forKey: .groupHoverCloseGrace) ?? Defaults.groupHoverCloseGrace, to: Self.groupHoverCloseGraceRange)
        // try? per key: an unknown enum value (from a newer build) falls back
        // to the default instead of failing the whole file.
        iconStyle = (try? c.decodeIfPresent(IconStyle.self, forKey: .iconStyle)) ?? .matchSystem
        if c.contains(.background) {
            background = c.value(.background, or: DockBackground())
        } else {
            background = DockBackground(
                legacyStyle: c.value(.backgroundStyle, or: DockBackgroundStyle.glass),
                frost: c.value(.backgroundFrost, or: 0.5),
                tint: c.value(.backgroundTint, or: RGBAColor?.none)
            )
        }
        showIndicators = c.value(.showIndicators, or: true)
        dimHiddenApps = c.value(.dimHiddenApps, or: false)
        showRecents = c.value(.showRecents, or: true)
        recentApps = Array(c.value(.recentApps, or: [PinnedApp]()).prefix(Self.recentAppsLimit))
        let radius = (try? c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)) ?? Defaults.cornerRadius
        cornerRadius = min(max(radius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        if c.contains(.settingsHotkey) {
            // Explicit null in JSON means the user cleared it. Missing key =
            // older file, keep the default.
            settingsHotkey = try c.decodeIfPresent(HotkeyChord.self, forKey: .settingsHotkey)
            if let chord = settingsHotkey, !chord.isRegisterable {
                settingsHotkey = .settingsDefault
            }
        } else {
            settingsHotkey = .settingsDefault
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AppInfo.version, forKey: .savedByVersion)
        try c.encode(revealDelay, forKey: .revealDelay)
        try c.encode(hideDelay, forKey: .hideDelay)
        try c.encode(animationDuration, forKey: .animationDuration)
        try c.encode(iconSize, forKey: .iconSize)
        try c.encode(iconGap, forKey: .iconGap)
        try c.encode(magnificationEnabled, forKey: .magnificationEnabled)
        try c.encode(magnifiedSize, forKey: .magnifiedSize)
        try c.encode(edge, forKey: .edge)
        try c.encode(entries, forKey: .entries)
        try c.encode(widgetKinds, forKey: .widgetKinds)
        try c.encode(autoHide, forKey: .autoHide)
        try c.encode(reserveSpace, forKey: .reserveSpace)
        try c.encode(animateOpeningApplications, forKey: .animateOpeningApplications)
        try c.encode(hideNativeDock, forKey: .hideNativeDock)
        try c.encode(nativeDockExplained, forKey: .nativeDockExplained)
        try c.encode(showTrash, forKey: .showTrash)
        try c.encode(trashAccessHintDismissed, forKey: .trashAccessHintDismissed)
        try c.encode(showBadges, forKey: .showBadges)
        try c.encode(badgeColor, forKey: .badgeColor)
        try c.encode(badgeCustomColor, forKey: .badgeCustomColor)
        try c.encode(activityIcons, forKey: .activityIcons)
        try c.encode(stacks, forKey: .stacks)
        if !layout.isEmpty { try c.encode(layout, forKey: .layout) }
        if !widgetSizes.isEmpty { try c.encode(widgetSizes, forKey: .widgetSizes) }
        if usageProviders != Defaults.usageProviders { try c.encode(usageProviders, forKey: .usageProviders) }
        if usageClaudeConsent { try c.encode(true, forKey: .usageClaudeConsent) }
        if usageCopilotConsent { try c.encode(true, forKey: .usageCopilotConsent) }
        try c.encode(openGroupsOnHover, forKey: .openGroupsOnHover)
        try c.encode(openSettingsOnLaunch, forKey: .openSettingsOnLaunch)
        try c.encode(groupHoverDelay, forKey: .groupHoverDelay)
        try c.encode(groupHoverCloseGrace, forKey: .groupHoverCloseGrace)
        try c.encode(iconStyle, forKey: .iconStyle)
        try c.encode(background, forKey: .background)
        try c.encode(showIndicators, forKey: .showIndicators)
        try c.encode(dimHiddenApps, forKey: .dimHiddenApps)
        try c.encode(showRecents, forKey: .showRecents)
        if !recentApps.isEmpty { try c.encode(recentApps, forKey: .recentApps) }
        try c.encode(cornerRadius, forKey: .cornerRadius)
        // Always write the key: null means cleared, object means set. Older
        // files without the key keep the default on load.
        if let settingsHotkey {
            try c.encode(settingsHotkey, forKey: .settingsHotkey)
        } else {
            try c.encodeNil(forKey: .settingsHotkey)
        }
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
        let data = Self.carryingForwardUnknownKeys(into: try encoder.encode(self))
        try data.write(to: DockModel.storageURL, options: .atomic)
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))

    /// Top-level keys in the file on disk that this build does not know
    /// (written by a newer Portside) are kept, so running an older copy never
    /// drops newer settings. Keys this build knows are always its own values.
    private static func carryingForwardUnknownKeys(into encoded: Data) -> Data {
        guard let existing = try? Data(contentsOf: storageURL),
              let old = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return encoded }
        let unknown = old.filter { !knownKeys.contains($0.key) }
        guard !unknown.isEmpty,
              var merged = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        merged.merge(unknown) { current, _ in current }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) else {
            return encoded
        }
        logger.info("kept \(unknown.count) dock.json key(s) from a newer build: \(unknown.keys.sorted().joined(separator: ", "), privacy: .public)")
        return data
    }

    static var beforeUpdateURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("dock.json.before-update")
    }

    /// Copy dock.json aside right before an update replaces the app.
    static func backUpBeforeUpdate() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        try? FileManager.default.removeItem(at: beforeUpdateURL)
        try FileManager.default.copyItem(at: storageURL, to: beforeUpdateURL)
    }

    /// A file written by a newer build is copied aside once per downgrade,
    /// since nested values this build does not know can still be lost.
    private static func backUpIfDowngrading(_ data: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let written = raw[CodingKeys.savedByVersion.stringValue] as? String,
              UpdateChecker.isNewer(written, than: AppInfo.version) else { return }
        let backup = storageURL.deletingLastPathComponent().appendingPathComponent("dock.json.from-\(written)")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        do {
            try data.write(to: backup, options: .atomic)
            logger.info("dock.json was written by \(written, privacy: .public), newer than \(AppInfo.version, privacy: .public); copied to \(backup.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("could not back up dock.json before downgrade: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// An existing file that fails to decode is moved aside, never overwritten.
    private static func setAsideUnreadable(_ error: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = storageURL.deletingLastPathComponent().appendingPathComponent("dock.json.unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: storageURL, to: aside)
            logger.error("dock.json could not be read (\(error.localizedDescription, privacy: .public)); moved to \(aside.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("dock.json could not be read and could not be moved aside: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            try save()
            DockModel.logger.info("saved \(self.entries.count) entries (\(self.allPinnedApps.count) apps, \(self.groups.count) groups, \(self.stacks.count) stacks)")
        } catch {
            DockModel.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load from disk. On first launch (no file), seed pinned apps from the
    /// native Dock and save immediately so later launches use Portside's list.
    static func load() -> DockModel {
        if let data = try? Data(contentsOf: storageURL) {
            backUpIfDowngrading(data)
            do {
                let model = try JSONDecoder().decode(DockModel.self, from: data)
                logger.info("loaded \(model.entries.count) entries (\(model.allPinnedApps.count) apps, \(model.groups.count) groups) from dock.json")
                return model
            } catch {
                setAsideUnreadable(error)
            }
        }
        let model = DockModel()
        let native = NativeDockImport.readSnapshot()
        model.entries = native.appSection
        model.stacks = native.folderStacks
        model.edge = native.edge
        model.iconSize = NativeDockImport.clampedIconSize(
            native.tileSize, edge: native.edge,
            itemCount: model.entries.count + model.stacks.count,
            widgetKinds: model.widgetKinds.count
        )
        model.persist()
        logger.info("first launch: seeded \(model.entries.count) entries (\(native.apps.count) apps, \(native.spacerCount) spacers), \(model.stacks.count) stacks, edge \(native.edge.rawValue, privacy: .public), icon size \(Double(model.iconSize), format: .fixed(precision: 0)) from the native Dock")
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
    /// separators and all other settings are never touched except stacks,
    /// which merge (or replace when replacing apps).
    func importFromNativeDock(_ native: NativeDockSnapshot, replace: Bool, applyLook: Bool, fitTileSize: CGFloat?) throws -> ImportResult {
        try save() // the file must match memory (slider drags persist late)
        let backup = Self.beforeImportURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: Self.storageURL, to: backup)

        var result = ImportResult()
        var list = entries
        if replace {
            let grouped = Set(groups.flatMap(\.apps).map(\.id))
            let incoming = native.appSection.filter { entry in
                if case .app(let app) = entry { return !grouped.contains(app.id) }
                return true // keep spacers from the native list
            }
            result.inGroups = native.apps.count - incoming.compactMap(\.apps.first).count
            result.removed = list.filter { if case .app = $0 { return true }; return false }.count
            result.added = incoming.compactMap { if case .app(let a) = $0 { return a }; return nil }.count
            // Groups keep their slots (capped at the new length).
            var merged = incoming
            for (index, entry) in list.enumerated() where entry.group != nil {
                merged.insert(entry, at: min(index, merged.count))
            }
            list = merged
            stacks = native.folderStacks
        } else {
            let have = Set(allPinnedApps.map(\.id))
            let new = native.apps.filter { !have.contains($0.id) }
            list.append(contentsOf: new.map(DockEntry.app))
            result.added = new.count
            let havePaths = Set(stacks.map(\.path))
            for stack in native.folderStacks where !havePaths.contains(stack.path) {
                stacks.append(stack)
            }
        }
        entries = list

        if applyLook {
            edge = native.edge
            iconSize = NativeDockImport.clampedIconSize(
                native.tileSize, edge: native.edge,
                itemCount: entries.count + stacks.count,
                widgetKinds: widgetKinds.count, fit: fitTileSize
            )
            result.appliedLook = true
        }
        persist()
        importLogger.info("import: \(replace ? "replace" : "add missing", privacy: .public), added \(result.added), removed \(result.removed), left in groups \(result.inGroups), stacks \(self.stacks.count), look \(result.appliedLook)")
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
        iconGap = old.iconGap
        magnificationEnabled = old.magnificationEnabled
        magnifiedSize = old.magnifiedSize
        animateOpeningApplications = old.animateOpeningApplications
        autoHide = old.autoHide
        reserveSpace = old.reserveSpace
        showTrash = old.showTrash
        showBadges = old.showBadges
        activityIcons = old.activityIcons
        settingsHotkey = old.settingsHotkey
        openGroupsOnHover = old.openGroupsOnHover
        usageClaudeConsent = old.usageClaudeConsent
        usageCopilotConsent = old.usageCopilotConsent
        openSettingsOnLaunch = old.openSettingsOnLaunch
        groupHoverDelay = old.groupHoverDelay
        groupHoverCloseGrace = old.groupHoverCloseGrace
        edge = old.edge
        entries = old.entries
        stacks = old.stacks
        widgetKinds = old.widgetKinds
        layout = old.layout
        widgetSizes = old.widgetSizes
        persist()
        try? FileManager.default.removeItem(at: Self.beforeImportURL)
        importLogger.info("import: undone, restored \(old.entries.count) entries, \(old.stacks.count) stacks from dock.json.before-import")
    }
}
