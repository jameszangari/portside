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
    var expandOnHover = true
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
        case position, display, compactStyle, clickAction, filter, hideWhenEmpty, animate, showTotal, showUsage
        case expandOnHover, collapseAfterFocus, showProject, showHost, showUpdated, showProviderNames, providerColors
        case showFinished, claude, codex, copilot, showBorder, compactWidth, compactHeight, expandedWidth, cornerRadius, opacity, fontSize
        case rowSpacing, maxSessions, hoverDelay, collapseDelay, animationDuration, horizontalOffset, verticalOffset, accent
    }

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
        expandOnHover = values.value(.expandOnHover, or: true)
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
        hoverDelay = bounded(hoverDelay, 0...1, 0.25)
        collapseDelay = bounded(collapseDelay, 0.1...2, 0.6)
        animationDuration = bounded(animationDuration, 0.1...0.5, 0.22)
        horizontalOffset = bounded(horizontalOffset, -300...300, 0)
        verticalOffset = bounded(verticalOffset, 0...80, 0)
    }

    func sessions(from all: [AgentSession]) -> [AgentSession] {
        all.filter { session in
            guard providerEnabled(session.provider.id),
                  showFinished || session.state != .done else { return false }
            switch filter {
            case .all: return true
            case .working: return session.state == .running && !session.needsAttention
            case .attention: return session.needsAttention || session.state == .done
            }
        }
    }

    private func providerEnabled(_ id: String) -> Bool {
        switch id {
        case "claude": claude
        case "codex": codex
        case "copilot": copilot
        default: true
        }
    }
}
