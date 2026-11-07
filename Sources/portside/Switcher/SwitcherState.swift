import AppKit
import Carbon.HIToolbox

/// One running app in the switcher, from a `WindowRegistry` app snapshot.
/// The key carries the launch generation, so a pid reused by a later
/// process never matches an item shown earlier.
struct SwitcherItem: Equatable, Identifiable {
    let key: AppKey
    let name: String
    let bundleIdentifier: String?
    let isHidden: Bool

    var id: AppKey { key }

    init(key: AppKey, name: String, bundleIdentifier: String? = nil, isHidden: Bool = false) {
        self.key = key
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isHidden = isHidden
    }

    init(_ app: AppSnapshot) {
        self.init(key: app.key, name: app.name, bundleIdentifier: app.bundleIdentifier, isHidden: app.isHidden)
    }

    /// What VoiceOver reads for the tile and the selection announcement.
    var spokenName: String { isHidden ? "\(name), hidden" : name }
}

/// Keys the switcher reads while its panel is key. Modifiers other than
/// Shift are ignored, because the shortcut's own modifier is still held.
enum SwitcherKey: Equatable {
    case next, previous, first, last
    case commit, cancel

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        switch Int(keyCode) {
        case kVK_Tab: self = shift ? .previous : .next
        // ⌘Tab's own reverse key.
        case kVK_ANSI_Grave: self = .previous
        case kVK_RightArrow: self = .next
        case kVK_LeftArrow: self = .previous
        case kVK_Home: self = .first
        case kVK_End: self = .last
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .commit
        case kVK_Escape: self = .cancel
        default: return nil
        }
    }
}

enum SwitcherEvent: Equatable {
    /// The shortcut fired. `items` are the running apps, most recently
    /// activated first; `held` is whether the shortcut's modifiers are still
    /// down. Pressed again while open, it moves to the next app.
    case trigger(items: [SwitcherItem], frontmost: pid_t?, held: Bool)
    case key(SwitcherKey)
    /// The shortcut's modifiers were released: commit the selection.
    case modifiersReleased
    /// The reveal delay passed with the modifiers still held.
    case revealDue
    /// A click or VoiceOver press on one tile: select it and commit.
    case choose(AppKey)
    /// The pointer moved onto a tile while the panel is visible: select it,
    /// as ⌘Tab does. Letting go then switches to it.
    case hover(AppKey)
    /// The registry changed while open (an app launched, quit or hid).
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
    case announce(String)
}

/// App-first switcher state machine. Pure: no AppKit, no timers. The
/// `AppSwitcher` controller performs the effects.
///
/// Hidden, then armed (panel key but transparent, so a quick tap never
/// flashes it), then visible once the reveal delay passes. Releasing the
/// modifiers commits from either open phase; Escape and focus loss cancel
/// without activating anything.
struct SwitcherState: Equatable {
    enum Phase: Equatable {
        case hidden
        case armed
        case visible
    }

    private(set) var phase = Phase.hidden
    private(set) var items: [SwitcherItem] = []
    private(set) var selection: AppKey?
    /// The app that was frontmost when the shortcut fired. Choosing it again
    /// activates nothing.
    private(set) var frontmost: pid_t?

    var isOpen: Bool { phase != .hidden }

    var selectedIndex: Int? { selection.flatMap { key in items.firstIndex { $0.key == key } } }
    var selectedItem: SwitcherItem? { selectedIndex.map { items[$0] } }

    mutating func send(_ event: SwitcherEvent) -> [SwitcherEffect] {
        switch event {
        case .trigger(let next, let frontmost, let held):
            if isOpen { return move(by: 1) }
            guard !next.isEmpty else { return [] }
            items = next
            self.frontmost = frontmost
            // ⌘Tab starts on the previous app; when the frontmost app is not
            // first (Portside's own Settings is in front), on the first one.
            let start = next.first?.key.pid == frontmost ? min(1, next.count - 1) : 0
            selection = next[start].key
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
            case .last: return select(items.count - 1)
            case .commit: return commit()
            case .cancel: return close()
            }

        case .modifiersReleased:
            guard isOpen else { return [] }
            return commit()

        case .revealDue:
            guard phase == .armed else { return [] }
            phase = .visible
            return [.reveal] + announcement()

        case .hover(let key):
            guard phase == .visible, let index = items.firstIndex(where: { $0.key == key }) else { return [] }
            return select(index)

        case .choose(let key):
            guard isOpen, items.contains(where: { $0.key == key }) else { return [] }
            selection = key
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
        guard !items.isEmpty else { return [] }
        let current = selectedIndex ?? 0
        let count = items.count
        return select(((current + step) % count + count) % count)
    }

    private mutating func select(_ index: Int) -> [SwitcherEffect] {
        guard items.indices.contains(index) else { return [] }
        let key = items[index].key
        guard key != selection else { return [] }
        selection = key
        return phase == .visible ? announcement() : []
    }

    private func announcement() -> [SwitcherEffect] {
        selectedItem.map { [.announce($0.spokenName)] } ?? []
    }

    /// Dismiss first, then activate, so the panel never holds key while
    /// another app comes forward.
    private mutating func commit() -> [SwitcherEffect] {
        let chosen = selectedItem
        let wasOpen = isOpen
        let target = frontmost
        reset()
        var effects: [SwitcherEffect] = wasOpen ? [.dismiss] : []
        if let chosen, chosen.key.pid != target { effects.append(.activate(chosen)) }
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
        frontmost = nil
    }

    /// Keeps the open order so tiles do not jump under the person: quit apps
    /// leave, new ones join at the end, names and hidden state update. A
    /// selection whose app quit moves to the app that took its place.
    private mutating func merge(_ next: [SwitcherItem]) -> [SwitcherEffect] {
        let byKey = Dictionary(next.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIndex = selectedIndex ?? 0
        var merged = items.compactMap { byKey[$0.key] }
        let known = Set(merged.map(\.key))
        merged += next.filter { !known.contains($0.key) }
        guard !merged.isEmpty else { return close() }
        let before = selection
        items = merged
        if let before, byKey[before] == nil {
            selection = merged[min(oldIndex, merged.count - 1)].key
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
