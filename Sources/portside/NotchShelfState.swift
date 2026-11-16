import CoreGraphics
import Foundation

enum NotchShelfSide: Equatable { case leading, trailing }

/// Something the compact strip shows and that has a card. Music, agents
/// and a meeting about to start last while they are true; battery,
/// weather and AirPods only ever come as short alerts (SHELF-07, SHELF-10).
enum NotchShelfActivity: String, Codable, CaseIterable, Identifiable {
    case meeting, music, agents, battery, weather, airPods
    var id: String { rawValue }
    var title: String {
        switch self {
        case .meeting: "Meeting soon"
        case .music: "Music"
        case .agents: "Agents"
        case .battery: "Battery"
        case .weather: "Weather"
        case .airPods: "AirPods"
        }
    }
    /// Lasts while true, so it can own the strip; the rest are alerts.
    var isLasting: Bool { self == .meeting || self == .music || self == .agents }
}

/// A short alert on the strip's right side: what it is and its words.
struct NotchShelfAlert: Equatable {
    let activity: NotchShelfActivity
    let symbol: String
    /// On the strip, beside the symbol ("18%"); may be empty.
    let short: String
    let title: String
    let detail: String
    /// Drawn in red (low battery).
    var isWarning = false
    /// Battery bars on the card (AirPods: left, right, case).
    var parts: [NotchLevelPart] = []
}

/// Which lasting activity owns the strip when several are on, first wins.
/// Saved inside `agentNotchSettings` as `stripOrder`; unknown, repeated or
/// alert-only entries are dropped and missing ones come back at the end.
enum NotchShelfOrder {
    static let defaults: [NotchShelfActivity] = [.meeting, .music, .agents]

    static func normalized(_ order: [NotchShelfActivity]) -> [NotchShelfActivity] {
        var seen = Set<NotchShelfActivity>()
        let kept = order.filter { $0.isLasting && seen.insert($0).inserted }
        return kept + defaults.filter { !seen.contains($0) }
    }
}

/// When the strip shows a meeting: from `minutes` before it starts until a
/// minute after. All-day events never count.
enum NotchMeetingSoon {
    static let after: TimeInterval = 60
    static let choices = [0, 1, 5, 10, 15]

    static func current(_ starts: [(start: Date, allDay: Bool)], now: Date, minutes: Int) -> Int? {
        guard minutes > 0 else { return nil }
        return starts.indices.filter { !starts[$0].allDay }.first { index in
            let start = starts[index].start
            return now >= start.addingTimeInterval(-TimeInterval(minutes * 60)) && now < start.addingTimeInterval(after)
        }
    }

    /// The next time the answer of `current` can change, for one timer.
    static func nextChange(_ starts: [(start: Date, allDay: Bool)], now: Date, minutes: Int) -> Date? {
        guard minutes > 0 else { return nil }
        return starts.filter { !$0.allDay }
            .flatMap { [$0.start.addingTimeInterval(-TimeInterval(minutes * 60)), $0.start.addingTimeInterval(after)] }
            .filter { $0 > now }.min()
    }
}

/// Weather alerts: rain, snow or a storm in the next two hours when none
/// is falling now (WMO codes from Open-Meteo).
enum NotchWeatherAlert {
    enum Kind: String { case rain, snow, storm }

    static func kind(_ code: Int) -> Kind? {
        switch code {
        case 51...67, 80...82: .rain
        case 71...77, 85, 86: .snow
        case 95...99: .storm
        default: nil
        }
    }

    /// The first wet hour within two hours, when it is dry now.
    static func detect(now code: Int?, hours: [(date: Date, code: Int)], at now: Date) -> (kind: Kind, date: Date)? {
        guard let code, kind(code) == nil else { return nil }
        return hours.lazy
            .filter { $0.date.addingTimeInterval(3600) > now && $0.date <= now.addingTimeInterval(7200) }
            .compactMap { hour in kind(hour.code).map { (kind: $0, date: hour.date) } }
            .first
    }
}

/// Battery alerts: the charger goes in, or the level drops to the low mark
/// while on battery.
enum NotchBatteryAlert: Equatable {
    case pluggedIn, low

    static func detect(previous: (percent: Int, onAC: Bool)?, current: (percent: Int, onAC: Bool), low: Int) -> NotchBatteryAlert? {
        guard let previous else { return nil }
        if current.onAC && !previous.onAC { return .pluggedIn }
        if !current.onAC && previous.percent > low && current.percent <= low { return .low }
        return nil
    }
}

enum NotchShelfPhase: Equatable {
    case compact
    /// One activity's card below the strip (hover, or the song banner).
    case card(NotchShelfActivity)
    case open
}

/// What the compact strip shows on each side of the notch. One lasting
/// activity takes both sides (music: art left, animation right); with two
/// on, the first in `stripOrder` takes the left and the second the right,
/// each drawn whole on its side (music and agents both show). An alert
/// takes the right side for a few seconds (SHELF-07). Nil: that side shows
/// nothing.
struct NotchShelfStrip: Equatable {
    var leading: NotchShelfActivity?
    var trailing: NotchShelfActivity?

    /// `active`: lasting activities that are on, in priority order; the
    /// first two split the sides. `alert` borrows the right side.
    static func layout(active: [NotchShelfActivity], alert: NotchShelfActivity?) -> NotchShelfStrip {
        NotchShelfStrip(leading: active.first, trailing: alert ?? (active.count > 1 ? active[1] : active.first))
    }

    /// Each side shows a different activity, so each draws whole on its side.
    var isSplit: Bool { leading != nil && trailing != nil && leading != trailing }

    /// SHELF-04c's fixed order: music over agents, an agent alert on the right.
    static func layout(music: Bool, agents: Bool, agentAlert: Bool) -> NotchShelfStrip {
        layout(active: [music ? .music : nil, agents ? .agents : nil].compactMap { $0 },
               alert: agents && agentAlert && music ? .agents : nil)
    }

    func activity(_ side: NotchShelfSide) -> NotchShelfActivity? {
        side == .leading ? leading : trailing
    }
}

/// Where the pointer is relative to the shelf panel.
enum NotchShelfRegion: Equatable {
    case outside
    case side(NotchShelfSide)
    /// The camera housing, or the middle of the pill on a display without one.
    case notch
    /// A card or open shelf content below the header.
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
    case card(NotchShelfActivity)
    case open
    /// Pointer left the open shelf.
    case collapse
    /// Pointer left a card. Shorter than `collapse`, as a card is a glance.
    case collapseCard
    /// The song banner ran its time without the pointer on it.
    case bannerEnd
    /// A shelf a hotkey opened ran its time (SHELF-11).
    case hotkeyEnd
}

/// The shelf's open/close rules, free of AppKit so they can be tested.
/// One rule everywhere (SHELF-04c): hovering a running activity on the
/// strip shows its card; the notch itself, a side with nothing running,
/// or a click opens the full shelf. Each input returns the timer to start
/// (replacing any earlier one); nil means cancel whatever was pending.
struct NotchShelfMachine: Equatable {
    private(set) var phase = NotchShelfPhase.compact
    /// Stays open when the pointer leaves and on clicks outside. Esc, the
    /// close button and the toggle hotkey still close it.
    private(set) var pinned = false
    private(set) var pending: NotchShelfTimer?
    /// The card is a song banner the pointer has not touched yet.
    private(set) var banner = false
    /// A hotkey opened the shelf (SHELF-11): as in Bartender, the pointer
    /// leaving does not close it; it closes when its time runs out, unless
    /// the pointer is on it then, which hands it to the hover rules.
    private(set) var viaHotkey = false
    private(set) var pointerInside = false

    init() {}

    var isOpen: Bool { phase == .open }
    var card: NotchShelfActivity? {
        if case .card(let activity) = phase { return activity }
        return nil
    }

    /// `activity` says what the strip shows on a side, nil for nothing.
    @discardableResult
    mutating func pointer(_ region: NotchShelfRegion,
                          activity: (NotchShelfSide) -> NotchShelfActivity? = { _ in nil }) -> NotchShelfTimer? {
        if region != .outside { banner = false }
        pointerInside = region != .outside
        // A hotkey's shelf keeps its own timer, whatever the pointer does;
        // nil here means leave the running timer alone.
        if viaHotkey, phase == .open { return nil }
        let next: NotchShelfTimer?
        switch (region, phase) {
        case (.outside, .compact): next = nil
        case (.outside, .card): next = .collapseCard
        case (.outside, .open): next = pinned ? nil : .collapse
        case (.body, _): next = nil
        case (_, .open): next = nil
        case (.notch, _): next = .open
        case (.side(let side), .compact): next = activity(side).map { .card($0) } ?? .open
        case (.side(let side), .card(let current)):
            if let shown = activity(side) { next = shown == current ? nil : .card(shown) } else { next = .open }
        }
        pending = next
        return next
    }

    /// A delay ran out. Ignored unless it is still the pending one.
    mutating func fire(_ timer: NotchShelfTimer) {
        guard timer == pending else { return }
        pending = nil
        switch timer {
        case .card(let activity): if phase != .open { phase = .card(activity) }
        case .open: phase = .open
        case .collapse, .collapseCard: close()
        case .bannerEnd: if banner { close() }
        case .hotkeyEnd:
            viaHotkey = false
            if !pointerInside { close() }
        }
    }

    /// A hotkey opens the shelf, or keeps it open and restarts its time.
    /// Returns the timer that closes it.
    mutating func openViaHotkey() -> NotchShelfTimer {
        banner = false
        phase = .open
        pinned = false
        viaHotkey = true
        pending = .hotkeyEnd
        return .hotkeyEnd
    }

    /// The song banner: shows the music card while the strip is idle and
    /// returns the timer that hides it. Nil when something else shows.
    mutating func showBanner() -> NotchShelfTimer? {
        guard phase == .compact else { return nil }
        phase = .card(.music)
        banner = true
        pending = .bannerEnd
        return .bannerEnd
    }

    /// A click on the strip or a card opens the shelf. Like Bartender, a
    /// click never closes an open shelf (the pointer is still on the notch,
    /// so a close would only reopen on the next hover). Leaving, a click
    /// outside or the close button close it.
    mutating func click() {
        pending = nil
        banner = false
        // A click hands a hotkey's shelf to the hover rules.
        viaHotkey = false
        guard phase != .open else { return }
        phase = .open
        pinned = false
    }

    mutating func open() {
        pending = nil
        banner = false
        viaHotkey = false
        phase = .open
    }

    mutating func setPinned(_ value: Bool) {
        pinned = value && phase == .open
        if pinned {
            viaHotkey = false
            pending = nil
        }
    }

    /// Click outside, Esc, or any explicit close.
    mutating func close() {
        pending = nil
        banner = false
        viaHotkey = false
        phase = .compact
        pinned = false
    }
}

/// A page of the open shelf (SHELF-03).
enum NotchShelfPage: String, Codable, CaseIterable, Identifiable {
    case widgets, agents, files, clipboard, airPods
    var id: String { rawValue }
    var title: String {
        switch self {
        case .widgets: "Widgets"
        case .agents: "Agents"
        case .files: "Files"
        case .clipboard: "Clipboard"
        case .airPods: "AirPods"
        }
    }
    var symbol: String {
        switch self {
        case .widgets: "square.grid.2x2"
        case .agents: "sparkles"
        case .files: "tray"
        case .clipboard: "doc.on.clipboard"
        case .airPods: "airpods"
        }
    }
}

/// Which page the shelf opens on: the first tab (Bartender), the last one
/// shown, or a fixed page.
enum NotchShelfStartPage: String, Codable, CaseIterable, Identifiable {
    case first, lastUsed, widgets, agents, files, clipboard, airPods
    var id: String { rawValue }
    var title: String {
        switch self {
        case .first: "First tab"
        case .lastUsed: "Last used"
        default: page?.title ?? rawValue
        }
    }
    var page: NotchShelfPage? { NotchShelfPage(rawValue: rawValue) }
}

/// Page order, which pages are off, and the starting page. Saved inside
/// `agentNotchSettings` as `shelfPages`; unknown or repeated pages are
/// dropped on read and missing ones come back at the end, turned on.
struct NotchShelfPages: Codable, Equatable {
    private(set) var order: [NotchShelfPage] = NotchShelfPage.allCases
    private(set) var hidden: Set<NotchShelfPage> = []
    var start = NotchShelfStartPage.first

    init() {}

    init(order: [NotchShelfPage], hidden: Set<NotchShelfPage> = [], start: NotchShelfStartPage = .first) {
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
        start = c.value(.start, or: .first)
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

    /// Tabs in order: turned on and `available` (Clipboard needs its module,
    /// AirPods a connected pair).
    func visible(available: (NotchShelfPage) -> Bool) -> [NotchShelfPage] {
        order.filter { isOn($0) && available($0) }
    }

    /// The page an opening shelf shows: the starting page, falling back to
    /// the first visible page. Nil when no page is visible.
    func opening(lastUsed: NotchShelfPage?, available: (NotchShelfPage) -> Bool) -> NotchShelfPage? {
        let pages = visible(available: available)
        let wanted = start == .lastUsed ? lastUsed : start.page
        if let wanted, pages.contains(wanted) { return wanted }
        return pages.first
    }
}

/// A slot on the Widgets page (SHELF-04c): Bartender's two tray widgets,
/// left and right. Saved inside `agentNotchSettings` as
/// `shelfLeadingWidget` and `shelfTrailingWidget`.
enum NotchShelfSlot: String, Codable, CaseIterable, Identifiable {
    case music, weather, calendar, empty
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: "Music"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .empty: "Empty"
        }
    }
    /// The widget that feeds it, run while the slot shows.
    var widgetKind: String? {
        switch self {
        case .music: "nowPlaying"
        case .weather: "weather"
        case .calendar: "calendar"
        case .empty: nil
        }
    }

    /// The two slots from SHELF-04's `shelfWidgets` list: its first two
    /// kinds that have a slot, else the defaults.
    static func migrated(_ kinds: [String]) -> (leading: NotchShelfSlot, trailing: NotchShelfSlot) {
        let slots = kinds.compactMap { kind in allCases.first { $0.widgetKind == kind } }
        return (slots.first ?? .music, slots.dropFirst().first ?? (slots.first == .calendar ? .music : .calendar))
    }
}

/// How music cards look, everywhere they show (SHELF-04c).
enum NotchMusicStyle: String, Codable, CaseIterable, Identifiable {
    case music, vinyl
    var id: String { rawValue }
    var title: String { self == .music ? "Album art" : "Vinyl" }
}

/// What the agent card lists: the latest session, or every running one.
enum NotchAgentCard: String, Codable, CaseIterable, Identifiable {
    case latest, all
    var id: String { rawValue }
    var title: String { self == .latest ? "Latest session" : "All running sessions" }
}

/// How long the Files page keeps a file (SHELF-06b). Bartender's default
/// is a day.
enum NotchFilesKeep: String, Codable, CaseIterable, Identifiable {
    case hour, day, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "1 week"
        }
    }
    /// For "Files kept for a day".
    var phrase: String {
        switch self {
        case .hour: "an hour"
        case .day: "a day"
        case .week: "a week"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        }
    }
}

/// The Files page's items (SHELF-06b): references to files dropped on the
/// notch, newest first, at most `limit`. The files stay where they are;
/// only their paths are kept, so a file that moves or is deleted leaves.
struct NotchFileTray: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        let id: UUID
        let path: String
        let added: Date
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    /// Bartender's six.
    static let limit = 6

    private(set) var items: [Item] = []

    init(items: [Item] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    /// Adds files to the front. A file already here moves to the front with
    /// a new date; past the limit the oldest leave. Returns whether anything
    /// changed.
    @discardableResult
    mutating func add(_ urls: [URL], now: Date = Date()) -> Bool {
        var seen = Set<String>()
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else { return false }
        let added = paths.map { Item(id: UUID(), path: $0, added: now) }
        items = Array((added + items.filter { !seen.contains($0.path) }).prefix(Self.limit))
        return true
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func removeAll() { items = [] }

    /// Drops items older than `keep` and files that are gone. Returns
    /// whether anything left.
    @discardableResult
    mutating func prune(now: Date = Date(), keep: TimeInterval, exists: (String) -> Bool) -> Bool {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.added) >= keep || !exists($0.path) }
        return items.count != before
    }

    /// When the next item expires, for a single timer.
    func nextExpiry(keep: TimeInterval) -> Date? {
        items.map { $0.added.addingTimeInterval(keep) }.min()
    }
}
