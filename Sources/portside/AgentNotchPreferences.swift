import SwiftUI

enum AgentNotchDisplay: String, Codable, CaseIterable, Identifiable {
    case automatic, focused, primary, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Notched display, otherwise primary"
        case .focused: "Display you're using"
        case .primary: "Primary display"
        case .all: "All displays"
        }
    }
}

enum AgentNotchFilter: String, Codable, CaseIterable, Identifiable {
    case all, working, attention
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All sessions"
        case .working: "Working sessions"
        case .attention: "Needs attention"
        }
    }
}

/// The Top Notch, which is the Notch Shelf (SHELF-12: the classic island,
/// its position, style and click settings were retired). Retired keys in
/// older files (`shelfEnabled`, `position`, `compactStyle`, `clickAction`,
/// `expandOnHover`, `hoverDelay`, `collapseDelay`, `hideWhenEmpty`,
/// `showTotal`, `horizontalOffset`, `verticalOffset`) are ignored and
/// dropped on the next save.
struct AgentNotchSettings: Codable, Equatable {
    var display = AgentNotchDisplay.automatic
    var filter = AgentNotchFilter.all
    var animate = true
    var showUsage = true
    /// Compact waveform while Spotify or Music is playing (same sources as
    /// the Now Playing widget). Hidden when paused or nothing is playing.
    var showMedia = true
    var shelfPages = NotchShelfPages()
    /// The Widgets page's two slots.
    var shelfLeadingWidget = NotchShelfSlot.music
    var shelfTrailingWidget = NotchShelfSlot.calendar
    /// Hover delay for cards and the full shelf.
    var shelfHoverDelay: Double = 0.15
    /// Pointer left the open shelf. A card closes after a fixed 0.2 s.
    var shelfCollapseDelay: Double = 0.8
    var shelfHaptics = false
    var musicStyle = NotchMusicStyle.music
    var musicSeeking = true
    var musicTint = false
    var musicHideWhenPaused = true
    /// A new track shows its name under the strip for a few seconds.
    var musicBanner = true
    var agentCard = NotchAgentCard.latest
    /// The working animation (Ship, Boxes or Dots).
    var thinking = NotchThinkingStyle.ship
    /// Files page (SHELF-06b): how long dropped files stay, and whether a
    /// file leaves once dragged out somewhere.
    var filesKeep = NotchFilesKeep.day
    var filesRemoveAfterDrag = false
    /// The shelf strip shows the volume or brightness level for a moment
    /// when it changes (SHELF-09).
    var hudVolume = true
    var hudBrightness = true
    /// Takes the volume and brightness keys so only the shelf's HUD shows
    /// (SHELF-09b). On by default (maintainer decision, 2026-11-15); needs
    /// Accessibility and is held off by restricted mode.
    var hudReplaceSystem = true
    /// Finished sessions leave the list this many minutes after they
    /// finish (Bartender's completed-task dismiss); 0 keeps them.
    var finishedDismissMinutes = 5
    static let finishedDismissChoices = [0, 1, 5, 15, 60]
    /// Which lasting activity owns the strip when several are on (SHELF-07).
    var stripOrder = NotchShelfOrder.defaults
    /// Minutes before a meeting that the strip shows it; 0 turns it off.
    var meetingMinutes = 5
    var alertAgents = true
    var alertBattery = true
    var batteryLowPercent = 20
    static let batteryLowChoices = [10, 20, 30]
    /// AirPods connect and low alerts (SHELF-10); the low mark shares the
    /// battery's choices.
    var alertAirPods = true
    var airPodsLowPercent = 20
    /// Live AirPods levels from Bluetooth LE adverts (asks for Bluetooth).
    var airPodsLive = false

    /// Restricted mode holds off the calendar read and the Bluetooth scan,
    /// keeping the saved choices for when it ends.
    func meetingsOn(restricted: Bool) -> Bool { meetingMinutes > 0 && !restricted }
    func liveAirPodsOn(restricted: Bool) -> Bool { airPodsLive && !restricted }
    /// Shelf hotkeys (SHELF-11), none set by default: open or close the
    /// shelf, open it on Files, search the clipboard.
    var shelfToggleHotkey: HotkeyChord?
    var shelfFilesHotkey: HotkeyChord?
    var shelfClipboardHotkey: HotkeyChord?
    /// How long a shelf a hotkey opened stays when the pointer is not on it.
    var hotkeyOpenSeconds = 30
    static let hotkeyOpenChoices = [15, 30, 60, 300, 600]
    var alertWeather = true
    /// Shows over full-screen apps (SHELF-08); off hides it in full-screen Spaces.
    var showInFullScreen = false
    var collapseAfterFocus = true
    var showProject = true
    var showHost = true
    var showUpdated = true
    var showProviderNames = true
    var providerColors = true
    var showFinished = true
    var claude = true
    var codex = true
    var copilot = true
    var opencode = true
    var cursor = true
    var chatgpt = true
    /// The panel's shadow, which rims the notch with a faint edge. Off by
    /// default (maintainer request): the notch blends into the housing.
    var showBorder = false
    var compactWidth: Double = 184
    /// Down to 100 (50 pt each side of a notch, the least that fits the
    /// art and bars on one side and the agent count on the other; maintainer
    /// request, 140 was too wide).
    static let compactWidthRange: ClosedRange<Double> = 100...280
    var compactHeight: Double = 30
    var expandedWidth: Double = 420
    var cornerRadius: Double = 22
    var opacity: Double = 1
    var fontSize: Double = 12
    var rowSpacing: Double = 8
    var maxSessions = 5
    var animationDuration: Double = 0.22
    var accent = PaletteColor(RGBAColor(red: 0.35, green: 0.82, blue: 0.95, alpha: 1))

    init() {}

    private enum CodingKeys: String, CodingKey {
        case display, filter, animate, showUsage, showMedia
        case shelfPages, shelfLeadingWidget, shelfTrailingWidget, shelfHoverDelay, shelfCollapseDelay
        case shelfHaptics, musicStyle, musicSeeking, musicTint, musicHideWhenPaused, musicBanner, agentCard, thinking, filesKeep, filesRemoveAfterDrag, hudVolume, hudBrightness, hudReplaceSystem, finishedDismissMinutes, stripOrder, meetingMinutes
        case alertAgents, alertBattery, batteryLowPercent, alertAirPods, airPodsLowPercent, airPodsLive, shelfToggleHotkey, shelfFilesHotkey, shelfClipboardHotkey, hotkeyOpenSeconds, alertWeather, showInFullScreen, collapseAfterFocus, showProject, showHost, showUpdated, showProviderNames, providerColors
        case showFinished, claude, codex, copilot, opencode, cursor, chatgpt, showBorder, compactWidth, compactHeight, expandedWidth, cornerRadius, opacity, fontSize
        case rowSpacing, maxSessions, animationDuration, accent
    }

    /// Read once to migrate, never written.
    private enum LegacyKeys: String, CodingKey { case shelfWidgets }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        display = values.value(.display, or: .automatic)
        filter = values.value(.filter, or: .all)
        animate = values.value(.animate, or: true)
        showUsage = values.value(.showUsage, or: true)
        showMedia = values.value(.showMedia, or: true)
        shelfPages = values.value(.shelfPages, or: NotchShelfPages())
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let migrated = NotchShelfSlot.migrated((try? legacy.decodeIfPresent([String].self, forKey: .shelfWidgets)) ?? [])
        shelfLeadingWidget = values.value(.shelfLeadingWidget, or: migrated.leading)
        shelfTrailingWidget = values.value(.shelfTrailingWidget, or: migrated.trailing)
        shelfHoverDelay = values.value(.shelfHoverDelay, or: 0.15)
        shelfCollapseDelay = values.value(.shelfCollapseDelay, or: 0.8)
        shelfHaptics = values.value(.shelfHaptics, or: false)
        musicStyle = values.value(.musicStyle, or: .music)
        musicSeeking = values.value(.musicSeeking, or: true)
        musicTint = values.value(.musicTint, or: false)
        musicHideWhenPaused = values.value(.musicHideWhenPaused, or: true)
        musicBanner = values.value(.musicBanner, or: true)
        agentCard = values.value(.agentCard, or: .latest)
        thinking = values.value(.thinking, or: .ship)
        filesKeep = values.value(.filesKeep, or: .day)
        filesRemoveAfterDrag = values.value(.filesRemoveAfterDrag, or: false)
        hudVolume = values.value(.hudVolume, or: true)
        hudBrightness = values.value(.hudBrightness, or: true)
        hudReplaceSystem = values.value(.hudReplaceSystem, or: true)
        finishedDismissMinutes = values.value(.finishedDismissMinutes, or: 5)
        let order = ((try? values.decodeIfPresent([String].self, forKey: .stripOrder)) ?? nil)?.compactMap(NotchShelfActivity.init(rawValue:))
        stripOrder = order ?? NotchShelfOrder.defaults
        meetingMinutes = values.value(.meetingMinutes, or: 5)
        alertAgents = values.value(.alertAgents, or: true)
        alertBattery = values.value(.alertBattery, or: true)
        batteryLowPercent = values.value(.batteryLowPercent, or: 20)
        alertAirPods = values.value(.alertAirPods, or: true)
        airPodsLowPercent = values.value(.airPodsLowPercent, or: 20)
        airPodsLive = values.value(.airPodsLive, or: false)
        shelfToggleHotkey = (try? values.decodeIfPresent(HotkeyChord.self, forKey: .shelfToggleHotkey)) ?? nil
        shelfFilesHotkey = (try? values.decodeIfPresent(HotkeyChord.self, forKey: .shelfFilesHotkey)) ?? nil
        shelfClipboardHotkey = (try? values.decodeIfPresent(HotkeyChord.self, forKey: .shelfClipboardHotkey)) ?? nil
        hotkeyOpenSeconds = values.value(.hotkeyOpenSeconds, or: 30)
        alertWeather = values.value(.alertWeather, or: true)
        showInFullScreen = values.value(.showInFullScreen, or: false)
        collapseAfterFocus = values.value(.collapseAfterFocus, or: true)
        showProject = values.value(.showProject, or: true)
        showHost = values.value(.showHost, or: true)
        showUpdated = values.value(.showUpdated, or: true)
        showProviderNames = values.value(.showProviderNames, or: true)
        providerColors = values.value(.providerColors, or: true)
        showFinished = values.value(.showFinished, or: true)
        claude = values.value(.claude, or: true)
        codex = values.value(.codex, or: true)
        copilot = values.value(.copilot, or: true)
        opencode = values.value(.opencode, or: true)
        cursor = values.value(.cursor, or: true)
        chatgpt = values.value(.chatgpt, or: true)
        showBorder = values.value(.showBorder, or: false)
        compactWidth = values.value(.compactWidth, or: 184)
        compactHeight = values.value(.compactHeight, or: 30)
        expandedWidth = values.value(.expandedWidth, or: 420)
        cornerRadius = values.value(.cornerRadius, or: 22)
        opacity = values.value(.opacity, or: 1)
        fontSize = values.value(.fontSize, or: 12)
        rowSpacing = values.value(.rowSpacing, or: 8)
        maxSessions = values.value(.maxSessions, or: 5)
        animationDuration = values.value(.animationDuration, or: 0.22)
        accent = values.value(.accent, or: accent)
        normalize()
    }

    mutating func normalize() {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        compactWidth = bounded(compactWidth, Self.compactWidthRange, 184)
        compactHeight = bounded(compactHeight, 24...44, 30)
        expandedWidth = bounded(expandedWidth, 340...560, 420)
        cornerRadius = bounded(cornerRadius, 8...32, 22)
        opacity = bounded(opacity, 0.75...1, 1)
        fontSize = bounded(fontSize, 10...16, 12)
        rowSpacing = bounded(rowSpacing, 4...16, 8)
        maxSessions = min(10, max(2, maxSessions))
        if !Self.finishedDismissChoices.contains(finishedDismissMinutes) { finishedDismissMinutes = 5 }
        stripOrder = NotchShelfOrder.normalized(stripOrder)
        if !NotchMeetingSoon.choices.contains(meetingMinutes) { meetingMinutes = 5 }
        if !Self.batteryLowChoices.contains(batteryLowPercent) { batteryLowPercent = 20 }
        if !Self.batteryLowChoices.contains(airPodsLowPercent) { airPodsLowPercent = 20 }
        if !Self.hotkeyOpenChoices.contains(hotkeyOpenSeconds) { hotkeyOpenSeconds = 30 }
        if shelfToggleHotkey?.isRegisterable == false { shelfToggleHotkey = nil }
        if shelfFilesHotkey?.isRegisterable == false { shelfFilesHotkey = nil }
        if shelfClipboardHotkey?.isRegisterable == false { shelfClipboardHotkey = nil }
        shelfHoverDelay = bounded(shelfHoverDelay, 0...1, 0.15)
        shelfCollapseDelay = bounded(shelfCollapseDelay, 0.1...2, 0.8)
        animationDuration = bounded(animationDuration, 0.1...0.5, 0.22)
    }

    func sessions(from all: [AgentSession], now: Date = Date()) -> [AgentSession] {
        all.filter { session in
            guard providerEnabled(session.provider.id),
                  showFinished || session.state != .done,
                  !isDismissed(session, now: now) else { return false }
            switch filter {
            case .all: return true
            case .working: return session.state == .running && !session.needsAttention
            case .attention: return session.needsAttention || session.state == .done
            }
        }
    }

    /// A finished session past the dismiss time.
    func isDismissed(_ session: AgentSession, now: Date) -> Bool {
        guard let dismissAt = dismissDate(session) else { return false }
        return now >= dismissAt
    }

    /// When a finished session leaves the list; nil while it is not
    /// finished or finished sessions are kept.
    func dismissDate(_ session: AgentSession) -> Date? {
        guard session.state == .done, finishedDismissMinutes > 0 else { return nil }
        return session.updated.addingTimeInterval(TimeInterval(finishedDismissMinutes * 60))
    }

    private func providerEnabled(_ id: String) -> Bool {
        switch id {
        case "claude": claude
        case "codex": codex
        case "copilot": copilot
        case "opencode": opencode
        case "cursor": cursor
        case "chatgpt": chatgpt
        default: true
        }
    }
}
