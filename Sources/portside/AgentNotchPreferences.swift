import SwiftUI

enum AgentNotchPosition: String, Codable, CaseIterable, Identifiable {
    case attached, below, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attached: "Attached to notch"
        case .below: "Below the notch"
        case .left: "Left of the notch"
        case .right: "Right of the notch"
        }
    }
}

enum AgentNotchDisplay: String, Codable, CaseIterable, Identifiable {
    case automatic, primary, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Notched display, otherwise primary"
        case .primary: "Primary display"
        case .all: "All displays"
        }
    }
}

enum AgentNotchCompactStyle: String, Codable, CaseIterable, Identifiable {
    case counts, providers, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AgentNotchClickAction: String, Codable, CaseIterable, Identifiable {
    case expand, focus
    var id: String { rawValue }
    var title: String { self == .expand ? "Expand dashboard" : "Focus latest session" }
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

struct AgentNotchSettings: Codable, Equatable {
    var position = AgentNotchPosition.attached
    var display = AgentNotchDisplay.automatic
    var compactStyle = AgentNotchCompactStyle.counts
    var clickAction = AgentNotchClickAction.expand
    var filter = AgentNotchFilter.all
    var hideWhenEmpty = true
    var animate = true
    var showTotal = true
    var showUsage = true
    /// Compact waveform while Spotify or Music is playing (same sources as
    /// the Now Playing widget). Hidden when paused or nothing is playing.
    var showMedia = true
    var expandOnHover = true
    /// Notch Shelf preview (P2-SHELF): hovering a running activity shows
    /// its card, the notch opens the full shelf. Off keeps the classic island.
    var shelfEnabled = false
    var shelfPages = NotchShelfPages()
    /// The Widgets page's two slots.
    var shelfLeadingWidget = NotchShelfSlot.music
    var shelfTrailingWidget = NotchShelfSlot.calendar
    /// Shelf hover delay for cards and the full shelf; the classic island
    /// keeps `hoverDelay`.
    var shelfHoverDelay: Double = 0.15
    /// Pointer left the open shelf. A card closes after a fixed 0.2 s.
    var shelfCollapseDelay: Double = 0.8
    var shelfHaptics = false
    var musicStyle = NotchMusicStyle.music
    var musicSeeking = true
    var musicTint = false
    var musicHideWhenPaused = true
    /// The music card shows for a few seconds when the track changes.
    var musicBanner = true
    var agentCard = NotchAgentCard.latest
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
    var alertWeather = true
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
    /// Thin light edge around the floating island. Off when attached to the
    /// camera housing (the housing already frames it).
    var showBorder = true
    var compactWidth: Double = 184
    var compactHeight: Double = 30
    var expandedWidth: Double = 420
    var cornerRadius: Double = 22
    var opacity: Double = 1
    var fontSize: Double = 12
    var rowSpacing: Double = 8
    var maxSessions = 5
    var hoverDelay: Double = 0.25
    var collapseDelay: Double = 0.6
    var animationDuration: Double = 0.22
    var horizontalOffset: Double = 0
    var verticalOffset: Double = 0
    var accent = PaletteColor(RGBAColor(red: 0.35, green: 0.82, blue: 0.95, alpha: 1))

    init() {}

    private enum CodingKeys: String, CodingKey {
        case position, display, compactStyle, clickAction, filter, hideWhenEmpty, animate, showTotal, showUsage, showMedia
        case expandOnHover, shelfEnabled, shelfPages, shelfLeadingWidget, shelfTrailingWidget, shelfHoverDelay, shelfCollapseDelay
        case shelfHaptics, musicStyle, musicSeeking, musicTint, musicHideWhenPaused, musicBanner, agentCard, finishedDismissMinutes, stripOrder, meetingMinutes
        case alertAgents, alertBattery, batteryLowPercent, alertWeather, collapseAfterFocus, showProject, showHost, showUpdated, showProviderNames, providerColors
        case showFinished, claude, codex, copilot, opencode, cursor, showBorder, compactWidth, compactHeight, expandedWidth, cornerRadius, opacity, fontSize
        case rowSpacing, maxSessions, hoverDelay, collapseDelay, animationDuration, horizontalOffset, verticalOffset, accent
    }

    /// Read once to migrate, never written.
    private enum LegacyKeys: String, CodingKey { case shelfWidgets }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        position = values.value(.position, or: .attached)
        display = values.value(.display, or: .automatic)
        compactStyle = values.value(.compactStyle, or: .counts)
        clickAction = values.value(.clickAction, or: .expand)
        filter = values.value(.filter, or: .all)
        hideWhenEmpty = values.value(.hideWhenEmpty, or: true)
        animate = values.value(.animate, or: true)
        showTotal = values.value(.showTotal, or: true)
        showUsage = values.value(.showUsage, or: true)
        showMedia = values.value(.showMedia, or: true)
        expandOnHover = values.value(.expandOnHover, or: true)
        shelfEnabled = values.value(.shelfEnabled, or: false)
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
        finishedDismissMinutes = values.value(.finishedDismissMinutes, or: 5)
        let order = ((try? values.decodeIfPresent([String].self, forKey: .stripOrder)) ?? nil)?.compactMap(NotchShelfActivity.init(rawValue:))
        stripOrder = order ?? NotchShelfOrder.defaults
        meetingMinutes = values.value(.meetingMinutes, or: 5)
        alertAgents = values.value(.alertAgents, or: true)
        alertBattery = values.value(.alertBattery, or: true)
        batteryLowPercent = values.value(.batteryLowPercent, or: 20)
        alertWeather = values.value(.alertWeather, or: true)
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
        showBorder = values.value(.showBorder, or: true)
        compactWidth = values.value(.compactWidth, or: 184)
        compactHeight = values.value(.compactHeight, or: 30)
        expandedWidth = values.value(.expandedWidth, or: 420)
        cornerRadius = values.value(.cornerRadius, or: 22)
        opacity = values.value(.opacity, or: 1)
        fontSize = values.value(.fontSize, or: 12)
        rowSpacing = values.value(.rowSpacing, or: 8)
        maxSessions = values.value(.maxSessions, or: 5)
        hoverDelay = values.value(.hoverDelay, or: 0.25)
        collapseDelay = values.value(.collapseDelay, or: 0.6)
        animationDuration = values.value(.animationDuration, or: 0.22)
        horizontalOffset = values.value(.horizontalOffset, or: 0)
        verticalOffset = values.value(.verticalOffset, or: 0)
        accent = values.value(.accent, or: accent)
        normalize()
    }

    mutating func normalize() {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        compactWidth = bounded(compactWidth, 140...280, 184)
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
        hoverDelay = bounded(hoverDelay, 0...1, 0.25)
        collapseDelay = bounded(collapseDelay, 0.1...2, 0.6)
        shelfHoverDelay = bounded(shelfHoverDelay, 0...1, 0.15)
        shelfCollapseDelay = bounded(shelfCollapseDelay, 0.1...2, 0.8)
        animationDuration = bounded(animationDuration, 0.1...0.5, 0.22)
        horizontalOffset = bounded(horizontalOffset, -300...300, 0)
        verticalOffset = bounded(verticalOffset, 0...80, 0)
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
        default: true
        }
    }
}
