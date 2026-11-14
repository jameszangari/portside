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
