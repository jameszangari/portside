import CoreGraphics

/// How the notch shelf opens. Hovering a side of the notch always peeks at
/// that side's activity; the mode decides what opens the full shelf.
enum NotchShelfOpenMode: String, Codable, CaseIterable, Identifiable {
    case hover, click, hoverPin
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        case .hoverPin: "Hover opens, click pins"
        }
    }
}

enum NotchShelfSide: Equatable { case leading, trailing }

enum NotchShelfPhase: Equatable {
    case compact
    case peek(NotchShelfSide)
    case open
}

/// Where the pointer is relative to the shelf panel.
enum NotchShelfRegion: Equatable {
    case outside
    case side(NotchShelfSide)
    /// The camera housing, or the middle of the pill on a display without one.
    case notch
    /// Peek card or open shelf content below the header.
    case body

    /// Maps a point in the panel (origin top left) to a region. The header is
    /// centered in the panel, `compactWidth` wide, with the notch in its middle.
    /// Without a notch the middle third of the header stands in for it.
    static func at(_ point: CGPoint, panelWidth: CGFloat, compactWidth: CGFloat, notchWidth: CGFloat,
                   headerHeight: CGFloat) -> NotchShelfRegion {
        guard point.x >= 0, point.y >= 0, point.x <= panelWidth else { return .outside }
        if point.y > headerHeight { return .body }
        let header = min(compactWidth, panelWidth)
        let left = (panelWidth - header) / 2
        let x = point.x - left
        guard x >= 0, x <= header else { return .body }
        let band = notchWidth > 0 ? min(notchWidth, header) : header / 3
        let bandStart = (header - band) / 2
        if x < bandStart { return .side(.leading) }
        if x > bandStart + band { return .side(.trailing) }
        return .notch
    }
}

/// A delay the presentation should run, then report back with `fire(_:)`.
enum NotchShelfTimer: Equatable {
    case peek(NotchShelfSide)
    case open
    /// Pointer left the open shelf.
    case collapse
    /// Pointer left a peek card. Shorter than `collapse`, as a peek is a glance.
    case collapsePeek
}

/// The shelf's open/close rules, free of AppKit so they can be tested.
/// Each input returns the timer to start (replacing any earlier one); nil
/// means cancel whatever was pending.
struct NotchShelfMachine: Equatable {
    var mode: NotchShelfOpenMode
    private(set) var phase = NotchShelfPhase.compact
    /// Stays open when the pointer leaves. Click outside and Esc still close.
    private(set) var pinned = false
    private(set) var pending: NotchShelfTimer?

    init(mode: NotchShelfOpenMode = .hover) { self.mode = mode }

    var isOpen: Bool { phase == .open }
    var peekSide: NotchShelfSide? {
        if case .peek(let side) = phase { return side }
        return nil
    }

    /// `canPeek` says whether a side has anything to show; an empty side
    /// does not peek.
    @discardableResult
    mutating func pointer(_ region: NotchShelfRegion, canPeek: (NotchShelfSide) -> Bool = { _ in true }) -> NotchShelfTimer? {
        let next: NotchShelfTimer?
        switch (region, phase) {
        case (.outside, .compact): next = nil
        case (.outside, .peek): next = .collapsePeek
        case (.outside, .open): next = pinned ? nil : .collapse
        case (.body, _): next = nil
        case (.side(let side), .compact): next = canPeek(side) ? .peek(side) : nil
        case (.side(let side), .peek(let current)): next = side == current || !canPeek(side) ? nil : .peek(side)
        case (.side, .open): next = nil
        case (.notch, .open): next = nil
        case (.notch, _): next = mode == .click ? nil : .open
        }
        pending = next
        return next
    }

    /// A delay ran out. Ignored unless it is still the pending one.
    mutating func fire(_ timer: NotchShelfTimer) {
        guard timer == pending else { return }
        pending = nil
        switch timer {
        case .peek(let side): if phase != .open { phase = .peek(side) }
        case .open: phase = .open
        case .collapse, .collapsePeek: close()
        }
    }

    /// A click on the header (a side or the notch). Like Bartender, a click
    /// never closes an open shelf (the pointer is still on the notch, so a
    /// close would only reopen on the next hover); in Hover opens, click
    /// pins it pins. Leaving, a click outside or the close button close it.
    mutating func click() {
        pending = nil
        if phase == .open {
            if mode == .hoverPin { pinned = true }
        } else {
            phase = .open
            pinned = mode == .hoverPin
        }
    }

    mutating func open() {
        pending = nil
        phase = .open
    }

    mutating func setPinned(_ value: Bool) {
        pinned = value && phase == .open
    }

    /// Click outside, Esc, or any explicit close.
    mutating func close() {
        pending = nil
        phase = .compact
        pinned = false
    }
}

/// A page of the open shelf (SHELF-03).
enum NotchShelfPage: String, Codable, CaseIterable, Identifiable {
    case widgets, agents, clipboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .widgets: "Widgets"
        case .agents: "Agents"
        case .clipboard: "Clipboard"
        }
    }
    var symbol: String {
        switch self {
        case .widgets: "square.grid.2x2"
        case .agents: "sparkles"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

/// Which page the shelf opens on: the last one shown, or a fixed page.
enum NotchShelfStartPage: String, Codable, CaseIterable, Identifiable {
    case lastUsed, widgets, agents, clipboard
    var id: String { rawValue }
    var title: String { self == .lastUsed ? "Last used" : page?.title ?? rawValue }
    var page: NotchShelfPage? { NotchShelfPage(rawValue: rawValue) }
}

/// Page order, which pages are off, and the starting page. Saved inside
/// `agentNotchSettings` as `shelfPages`; unknown or repeated pages are
/// dropped on read and missing ones come back at the end, turned on.
struct NotchShelfPages: Codable, Equatable {
    private(set) var order: [NotchShelfPage] = NotchShelfPage.allCases
    private(set) var hidden: Set<NotchShelfPage> = []
    var start = NotchShelfStartPage.lastUsed

    init() {}

    init(order: [NotchShelfPage], hidden: Set<NotchShelfPage> = [], start: NotchShelfStartPage = .lastUsed) {
        self.order = Self.complete(order)
        self.hidden = hidden
        self.start = start
    }

    private enum CodingKeys: String, CodingKey { case order, hidden, start }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? nil
        order = Self.complete((names ?? []).compactMap(NotchShelfPage.init(rawValue:)))
        let off = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? nil
        hidden = Set((off ?? []).compactMap(NotchShelfPage.init(rawValue:)))
        start = c.value(.start, or: .lastUsed)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order.map(\.rawValue), forKey: .order)
        try c.encode(order.filter(hidden.contains).map(\.rawValue), forKey: .hidden)
        try c.encode(start, forKey: .start)
    }

    private static func complete(_ pages: [NotchShelfPage]) -> [NotchShelfPage] {
        var seen = Set<NotchShelfPage>()
        let kept = pages.filter { seen.insert($0).inserted }
        return kept + NotchShelfPage.allCases.filter { !seen.contains($0) }
    }

    func isOn(_ page: NotchShelfPage) -> Bool { !hidden.contains(page) }

    mutating func setOn(_ page: NotchShelfPage, _ on: Bool) {
        if on { hidden.remove(page) } else { hidden.insert(page) }
    }

    /// Moves `page` one place toward the start (`by: -1`) or the end (`by: 1`).
    mutating func move(_ page: NotchShelfPage, by step: Int) {
        guard let index = order.firstIndex(of: page) else { return }
        let target = index + step
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    /// Tabs in order: turned on and `available` (Clipboard needs its module).
    func visible(available: (NotchShelfPage) -> Bool) -> [NotchShelfPage] {
        order.filter { isOn($0) && available($0) }
    }

    /// The page an opening shelf shows. A peek opens on the page that holds
    /// the peeked card, so the card stays put; otherwise the starting page,
    /// falling back to the first visible page. Nil when no page is visible.
    func opening(lastUsed: NotchShelfPage?, fromPeek: Bool, available: (NotchShelfPage) -> Bool) -> NotchShelfPage? {
        let pages = visible(available: available)
        if fromPeek, pages.contains(.agents) { return .agents }
        let wanted = start == .lastUsed ? lastUsed : start.page
        if let wanted, pages.contains(wanted) { return wanted }
        return pages.first
    }
}

/// The Widgets page's slots (SHELF-04): widget kinds in order, 1 to 4.
/// Saved inside `agentNotchSettings` as `shelfWidgets`.
enum NotchShelfWidgets {
    static let eligible = ["nowPlaying", "calendar", "weather", "usage", "systemStats", "cpu", "memory", "battery", "clock"]
    static let defaults = ["nowPlaying", "weather"]
    static let maxSlots = 4

    /// Eligible, each once, at most `maxSlots`; nothing left gives the defaults.
    static func normalized(_ kinds: [String]) -> [String] {
        var seen = Set<String>()
        let kept = kinds.filter { eligible.contains($0) && seen.insert($0).inserted }
        return kept.isEmpty ? defaults : Array(kept.prefix(maxSlots))
    }
}
