import AppKit
import Carbon.HIToolbox

/// One window in the switcher, from a `WindowRegistry` window snapshot. The
/// id is the registry's ephemeral one (it carries the app's launch
/// generation), so a reused pid or a reopened window never matches it.
struct SwitcherWindow: Equatable, Identifiable {
    let id: WindowID
    let title: String
    /// The app's focused window (whether or not the app is frontmost).
    let isFocused: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
    /// The display's name, set only while more than one display is connected.
    let display: String?
    /// AX coordinates, as the registry read it. Used to find the window for a preview.
    let frame: CGRect?

    init(id: WindowID, title: String, isFocused: Bool = false, isMinimized: Bool = false,
         isFullScreen: Bool = false, display: String? = nil, frame: CGRect? = nil) {
        self.id = id
        self.title = title
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.display = display
        self.frame = frame
    }

    init(_ window: WindowSnapshot, displays: [CGDirectDisplayID: String]) {
        self.init(
            id: window.id,
            title: window.title,
            isFocused: window.isFocused,
            isMinimized: window.isMinimized,
            isFullScreen: window.isFullScreen,
            display: window.displayID.flatMap { displays[$0] },
            frame: window.frame
        )
    }

    var previewTarget: PreviewTarget {
        PreviewTarget(window: id, title: title, frame: frame, isMinimized: isMinimized)
    }

    /// The indicators in words, as shown under the title and read by VoiceOver.
    var states: [String] {
        var states: [String] = []
        if isMinimized { states.append("minimized") }
        if isFullScreen { states.append("full screen, own Space") }
        if let display { states.append("on \(display)") }
        return states
    }
}

/// One entry in the switcher: a running app, or one window of it. The app
/// key carries the launch generation, so a pid reused by a later process
/// never matches an item shown earlier.
struct SwitcherItem: Equatable, Identifiable {
    enum ID: Hashable {
        case app(AppKey)
        case window(WindowID)
    }

    let key: AppKey
    let name: String
    let bundleIdentifier: String?
    let isHidden: Bool
    /// Window-first and search entries: the one window this entry stands for.
    let window: SwitcherWindow?
    /// App entries: the app's windows, most recently focused first. Empty
    /// without Accessibility.
    let windows: [SwitcherWindow]
    /// Accessibility is allowed but this app's windows could not be read
    /// (still loading, not answering, or it refuses Accessibility).
    let windowsUnavailable: Bool

    var id: ID { window.map { .window($0.id) } ?? .app(key) }

    init(key: AppKey, name: String, bundleIdentifier: String? = nil, isHidden: Bool = false,
         window: SwitcherWindow? = nil, windows: [SwitcherWindow] = [], windowsUnavailable: Bool = false) {
        self.key = key
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isHidden = isHidden
        self.window = window
        self.windows = window == nil ? windows : []
        self.windowsUnavailable = window == nil && windowsUnavailable
    }

    init(_ app: AppSnapshot, windows: [SwitcherWindow] = [], windowsUnavailable: Bool = false) {
        self.init(key: app.key, name: app.name, bundleIdentifier: app.bundleIdentifier, isHidden: app.isHidden,
                  windows: windows, windowsUnavailable: windowsUnavailable)
    }

    /// The entry for one of this app's windows.
    func entry(for window: SwitcherWindow) -> SwitcherItem {
        SwitcherItem(key: key, name: name, bundleIdentifier: bundleIdentifier, isHidden: isHidden, window: window)
    }

    /// The window's title, or the app's name for an app or an untitled window.
    var title: String {
        guard let title = window?.title, !title.isEmpty else { return name }
        return title
    }

    /// What VoiceOver reads for the tile or row and the selection announcement.
    var spokenName: String {
        var parts = [title]
        if window != nil, title != name { parts.append(name) }
        if isHidden { parts.append("hidden") }
        parts += window?.states ?? []
        if windows.count > 1 { parts.append("\(windows.count) windows") }
        return parts.joined(separator: ", ")
    }
}

/// What the switcher lists: apps (⌘Tab style, the default) or windows.
enum SwitcherMode: String, Codable, CaseIterable {
    case apps
    case windows
}

/// Builds the switcher's entries from a registry snapshot. Pure.
enum SwitcherCatalog {
    /// Apps mode: every app in recent-activation order, each with its windows.
    /// Windows mode: every listed window in recent-focus order, then the apps
    /// with no listed window. Without Accessibility both are the app list.
    static func items(_ snapshot: WindowRegistrySnapshot, mode: SwitcherMode,
                      displays: [CGDirectDisplayID: String] = [:]) -> [SwitcherItem] {
        var byApp: [AppKey: [SwitcherWindow]] = [:]
        for window in snapshot.windows {
            byApp[window.id.app, default: []].append(SwitcherWindow(window, displays: displays))
        }
        let apps = snapshot.apps.map { app in
            let windows = byApp[app.key] ?? []
            let unavailable = snapshot.accessibilityGranted && windows.isEmpty
                && (app.windowAccess == .loading || app.windowAccess == .unresponsive)
            return SwitcherItem(app, windows: windows, windowsUnavailable: unavailable)
        }
        guard mode == .windows, snapshot.accessibilityGranted else { return apps }
        let appsByKey = Dictionary(apps.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = snapshot.windows.compactMap { window in
            appsByKey[window.id.app].map { $0.entry(for: SwitcherWindow(window, displays: displays)) }
        }
        return windows + apps.filter(\.windows.isEmpty)
    }
}

/// Title search. Every word typed must appear in the window title or the
/// app name, ignoring case and diacritics. Results keep the list's recent
/// order, so the same query always gives the same order.
enum SwitcherSearch {
    static func matches(_ item: SwitcherItem, _ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            let word = String(word)
            return item.title.localizedStandardContains(word) || item.name.localizedStandardContains(word)
        }
    }

    /// Search covers windows, whatever the mode: an app entry stands for its
    /// windows, or for itself when none are listed.
    static func candidates(_ items: [SwitcherItem]) -> [SwitcherItem] {
        items.flatMap { item -> [SwitcherItem] in
            item.window != nil || item.windows.isEmpty ? [item] : item.windows.map(item.entry)
        }
    }
}

/// Keys the switcher reads while its panel is key. Modifiers other than
/// Shift are ignored for movement, because the shortcut's own modifier is
/// still held.
enum SwitcherKey: Equatable {
    case next, previous, first, last
    /// Down and Up: in the app row, a window of the selected app.
    case down, up
    case commit, cancel
    /// Latch title search (/).
    case search
    case type(String)
    case deleteBackward
    case clearQuery

    /// `characters` and `unmodified` are the event's `characters` and
    /// `charactersIgnoringModifiers`. While searching, printable keys type
    /// (⌥ still held types the plain character); with ⌘ or ⌃ down nothing
    /// types.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil,
          unmodified: String? = nil, searching: Bool = false) {
        let shift = modifiers.contains(.shift)
        switch Int(keyCode) {
        case kVK_Tab: self = shift ? .previous : .next
        case kVK_Home: self = .first
        case kVK_End: self = .last
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .commit
        case kVK_Escape: self = .cancel
        case kVK_DownArrow: self = searching ? .next : .down
        case kVK_UpArrow: self = searching ? .previous : .up
        case kVK_RightArrow where !searching: self = .next
        case kVK_LeftArrow where !searching: self = .previous
        case kVK_Delete where searching: self = modifiers.contains(.command) ? .clearQuery : .deleteBackward
        // ⌘Tab's own reverse key.
        case kVK_ANSI_Grave where !searching: self = .previous
        case kVK_ANSI_Slash where !searching: self = .search
        default:
            guard searching, modifiers.isDisjoint(with: [.command, .control]) else { return nil }
            let text = (modifiers.contains(.option) ? unmodified : characters) ?? ""
            guard !text.isEmpty, text.unicodeScalars.allSatisfy(Self.isTypeable) else { return nil }
            self = .type(text)
        }
    }

    /// Not a control character or a function key's private-use character.
    private static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }
}

enum SwitcherEvent: Equatable {
    /// The shortcut fired. `items` are the entries, most recent first; `held`
    /// is whether the shortcut's modifiers are still down. Pressed again
    /// while open, it moves to the next entry.
    case trigger(items: [SwitcherItem], frontmost: pid_t?, held: Bool)
    case key(SwitcherKey)
    /// The shortcut's modifiers were released: commit the selection, unless
    /// search is latched.
    case modifiersReleased
    /// The reveal delay passed with the modifiers still held.
    case revealDue
    /// A click or VoiceOver press on one entry (and, in the app row, one of
    /// its windows): select it and commit.
    case choose(SwitcherItem.ID, window: WindowID? = nil)
    /// The pointer moved onto an entry while the panel is visible: select
    /// it, as ⌘Tab does. Letting go then switches to it.
    case hover(SwitcherItem.ID)
    /// The registry changed while open (an app launched, quit or hid, a
    /// window opened, closed or changed).
    case appsChanged([SwitcherItem])
    /// The panel lost key, or another app activated.
    case focusLost
    /// The module stopped.
    case disable
}

enum SwitcherEffect: Equatable {
    /// Order the panel in as key, still transparent.
    case present
    /// Make the panel visible.
    case reveal
    case dismiss
    /// Bring this app forward. Only after `dismiss`.
    case activate(SwitcherItem)
    /// Bring this window of the app forward. Only after `dismiss`.
    case focus(SwitcherItem, SwitcherWindow)
    case announce(String)
}

/// Switcher state machine. Pure: no AppKit, no timers. The `AppSwitcher`
/// controller performs the effects.
///
/// Hidden, then armed (panel key but transparent, so a quick tap never
/// flashes it), then visible once the reveal delay passes. Releasing the
/// modifiers commits from either open phase; Escape and focus loss cancel
/// without activating anything. `/` latches title search: the panel shows,
/// typing filters, and only Return or a click commits, so the modifier may
/// be let go.
struct SwitcherState: Equatable {
    enum Phase: Equatable {
        case hidden
        case armed
        case visible
    }

    private(set) var phase = Phase.hidden
    private(set) var items: [SwitcherItem] = []
    private(set) var selection: SwitcherItem.ID?
    /// In the app row: the window chosen inside the selected app. Nil means
    /// the app itself, as in SW-01.
    private(set) var windowSelection: WindowID?
    /// The latched search text; nil while not searching.
    private(set) var query: String?
    /// Search matches, in the list's order.
    private(set) var results: [SwitcherItem] = []
    /// The app that was frontmost when the shortcut fired. Choosing it again
    /// activates nothing.
    private(set) var frontmost: pid_t?

    var isOpen: Bool { phase != .hidden }
    var isSearching: Bool { query != nil }
    /// A vertical window list rather than the app icon row.
    var isWindowList: Bool { isSearching || items.contains { $0.window != nil } }

    /// What the panel lists and the keys move through.
    var shown: [SwitcherItem] { isSearching ? results : items }
    var selectedIndex: Int? { selection.flatMap { id in shown.firstIndex { $0.id == id } } }
    var selectedItem: SwitcherItem? { selectedIndex.map { shown[$0] } }
    /// The selected entry's window, or the window chosen in the app row.
    var selectedWindow: SwitcherWindow? {
        guard let item = selectedItem else { return nil }
        return item.window ?? windowSelection.flatMap { id in item.windows.first { $0.id == id } }
    }

    mutating func send(_ event: SwitcherEvent) -> [SwitcherEffect] {
        switch event {
        case .trigger(let next, let frontmost, let held):
            if isOpen { return move(by: 1) }
            guard !next.isEmpty else { return [] }
            items = next
            self.frontmost = frontmost
            // ⌘Tab starts on the previous app (or window); when the
            // frontmost app is not first (Portside's own Settings is in
            // front), on the first one.
            let start = next.first?.key.pid == frontmost ? min(1, next.count - 1) : 0
            selection = next[start].id
            guard held else {
                // A tap released before the panel could show: quick switch.
                return commit()
            }
            phase = .armed
            return [.present]

        case .key(let key):
            guard isOpen else { return [] }
            switch key {
            case .next: return move(by: 1)
            case .previous: return move(by: -1)
            case .first: return select(0)
            case .last: return select(shown.count - 1)
            case .down: return isWindowList ? move(by: 1) : moveWindow(by: 1)
            case .up: return isWindowList ? move(by: -1) : moveWindow(by: -1)
            case .commit: return commit()
            case .cancel: return close()
            case .search: return startSearch()
            case .type(let text): return edit { $0 += text }
            case .deleteBackward: return edit { if !$0.isEmpty { $0.removeLast() } }
            case .clearQuery: return edit { $0 = "" }
            }

        case .modifiersReleased:
            // Latched: letting go while searching keeps it open.
            guard isOpen, !isSearching else { return [] }
            return commit()

        case .revealDue:
            guard phase == .armed else { return [] }
            phase = .visible
            return [.reveal] + announcement()

        case .hover(let id):
            guard phase == .visible, let index = shown.firstIndex(where: { $0.id == id }) else { return [] }
            return select(index)

        case .choose(let id, let window):
            guard isOpen, let item = shown.first(where: { $0.id == id }) else { return [] }
            selection = id
            windowSelection = window.flatMap { window in item.windows.contains { $0.id == window } ? window : nil }
            return commit()

        case .appsChanged(let next):
            guard isOpen else { return [] }
            return merge(next)

        case .focusLost, .disable:
            guard isOpen else { return [] }
            return close()
        }
    }

    // MARK: Transitions

    private mutating func move(by step: Int) -> [SwitcherEffect] {
        let count = shown.count
        guard count > 0 else { return [] }
        let current = selectedIndex ?? 0
        return select(((current + step) % count + count) % count)
    }

    private mutating func select(_ index: Int) -> [SwitcherEffect] {
        guard shown.indices.contains(index) else { return [] }
        let id = shown[index].id
        guard id != selection else { return [] }
        selection = id
        windowSelection = nil
        return phase == .visible ? announcement() : []
    }

    /// Down from the app goes to its most recent window, then on to older
    /// ones, stopping at the last; Up goes back, and from the first window
    /// back to the app. Nothing wraps, so the app is always one Up away.
    private mutating func moveWindow(by step: Int) -> [SwitcherEffect] {
        guard let windows = selectedItem?.windows, !windows.isEmpty else { return [] }
        let current = windowSelection.flatMap { id in windows.firstIndex { $0.id == id } } ?? -1
        let next = min(max(current + step, -1), windows.count - 1)
        guard next != current else { return [] }
        windowSelection = next < 0 ? nil : windows[next].id
        return phase == .visible ? announcement() : []
    }

    private func announcement() -> [SwitcherEffect] {
        if isSearching, results.isEmpty { return [.announce("No matches")] }
        guard let item = selectedItem else { return [] }
        if let window = windowSelection.flatMap({ id in item.windows.first { $0.id == id } }) {
            return [.announce(item.entry(for: window).spokenName)]
        }
        return [.announce(item.spokenName)]
    }

    /// Shows the panel at once (search needs it) and keeps the selection on
    /// the same window, or the selected app's most recent one.
    private mutating func startSearch() -> [SwitcherEffect] {
        guard !isSearching else { return [] }
        let current = selectedItem
        let preferred: SwitcherItem.ID? = windowSelection.map { .window($0) }
            ?? current?.windows.first.map { .window($0.id) } ?? current?.id
        query = ""
        results = SwitcherSearch.candidates(items)
        windowSelection = nil
        selection = results.first { $0.id == preferred }?.id ?? results.first?.id
        var effects: [SwitcherEffect] = []
        if phase == .armed {
            phase = .visible
            effects.append(.reveal)
        }
        return effects + [.announce("Search window titles")]
    }

    /// Typing and deleting refilter and select the first match.
    private mutating func edit(_ change: (inout String) -> Void) -> [SwitcherEffect] {
        guard var text = query else { return [] }
        change(&text)
        guard text != query else { return [] }
        query = text
        results = SwitcherSearch.candidates(items).filter { SwitcherSearch.matches($0, text) }
        selection = results.first?.id
        return announcement()
    }

    /// Dismiss first, then activate, so the panel never holds key while
    /// another app comes forward. A window of the frontmost app focuses
    /// unless it is already that app's focused window.
    private mutating func commit() -> [SwitcherEffect] {
        let chosen = selectedItem
        let window = selectedWindow
        let wasOpen = isOpen
        let target = frontmost
        reset()
        var effects: [SwitcherEffect] = wasOpen ? [.dismiss] : []
        guard let chosen else { return effects }
        if let window {
            if chosen.key.pid != target || !window.isFocused { effects.append(.focus(chosen, window)) }
        } else if chosen.key.pid != target {
            effects.append(.activate(chosen))
        }
        return effects
    }

    private mutating func close() -> [SwitcherEffect] {
        reset()
        return [.dismiss]
    }

    private mutating func reset() {
        phase = .hidden
        items = []
        selection = nil
        windowSelection = nil
        query = nil
        results = []
        frontmost = nil
    }

    /// Keeps the open order so entries do not jump under the person: quit
    /// apps and closed windows leave, new ones join at the end, names,
    /// titles and states update. A selection that left moves to the entry
    /// that took its place; a chosen window that closed goes back to its app.
    private mutating func merge(_ next: [SwitcherItem]) -> [SwitcherEffect] {
        let byID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIndex = selectedIndex ?? 0
        let before = selection
        let beforeWindow = windowSelection
        var merged = items.compactMap { byID[$0.id] }
        let known = Set(merged.map(\.id))
        merged += next.filter { !known.contains($0.id) }
        guard !merged.isEmpty else { return close() }
        items = merged
        if let query {
            let old = results
            results = SwitcherSearch.candidates(items).filter { SwitcherSearch.matches($0, query) }
            if let before, results.contains(where: { $0.id == before }) { return [] }
            selection = results.isEmpty ? nil : results[min(oldIndex, results.count - 1)].id
            return phase == .visible && old != results ? announcement() : []
        }
        if let before, byID[before] == nil {
            selection = merged[min(oldIndex, merged.count - 1)].id
            windowSelection = nil
            return phase == .visible ? announcement() : []
        }
        if let beforeWindow, selectedItem?.windows.contains(where: { $0.id == beforeWindow }) != true {
            windowSelection = nil
            return phase == .visible ? announcement() : []
        }
        return []
    }
}

/// The modifiers that make a shortcut "held". Shift is left out: it only
/// reverses, and releasing it must not commit.
enum SwitcherModifiers {
    static func required(for chord: HotkeyChord) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if chord.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if chord.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if chord.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// Device-dependent bits for the left and right key of each modifier
    /// (`NX_DEVICEL*KEYMASK` / `NX_DEVICER*KEYMASK` in IOLLEvent.h).
    private static let sides: [(flag: NSEvent.ModifierFlags, left: Int, right: Int, leftBit: UInt, rightBit: UInt)] = [
        (.command, kVK_Command, kVK_RightCommand, 0x08, 0x10),
        (.option, kVK_Option, kVK_RightOption, 0x20, 0x40),
        (.control, kVK_Control, kVK_RightControl, 0x01, 0x2000),
    ]

    /// A required modifier key went down while the switcher believed it held
    /// since the open, so its release was missed. The device bits tell a
    /// press from a release and rule out the pair's other key (left ⌥ held,
    /// right ⌥ pressed or let go); an event without them counts as a press.
    static func isRepress(keyCode: UInt16, flags: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags) -> Bool {
        guard let side = sides.first(where: { $0.left == Int(keyCode) || $0.right == Int(keyCode) }),
              required.contains(side.flag), flags.contains(side.flag) else { return false }
        let isLeft = side.left == Int(keyCode)
        let this = isLeft ? side.leftBit : side.rightBit
        let other = isLeft ? side.rightBit : side.leftBit
        let raw = flags.rawValue
        guard raw & (this | other) != 0 else { return true }
        return raw & this != 0 && raw & other == 0
    }

    /// Every required modifier is down. With none required nothing can be
    /// held, so the shortcut always quick-switches.
    static func isHeld(_ flags: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags) -> Bool {
        !required.isEmpty && flags.intersection(.deviceIndependentFlagsMask).isSuperset(of: required)
    }
}

/// Which chords the switcher may own.
enum SwitcherShortcut {
    /// Default: Option-Tab. Native ⌘Tab stays macOS's.
    static let defaultChord = HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))

    /// Why the switcher refuses `chord`, or nil. ⌘Tab and ⇧⌘Tab belong to
    /// the macOS app switcher; Portside never registers them (SW-04 decides
    /// on interception separately).
    static func refusal(for chord: HotkeyChord) -> String? {
        if chord.keyCode == UInt32(kVK_Tab), chord.modifiers & UInt32(cmdKey) != 0 {
            return "\(chord.displayString) belongs to the macOS app switcher. Portside does not replace it."
        }
        if SwitcherModifiers.required(for: chord).isEmpty {
            return "Include ⌘, ⌥ or ⌃ so the switcher can tell when you let go."
        }
        return nil
    }

    static func isAllowed(_ chord: HotkeyChord) -> Bool {
        chord.isRegisterable && refusal(for: chord) == nil
    }
}
