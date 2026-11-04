import AppKit
import SwiftUI

struct AgentNotchView: View {
    @ObservedObject var agents: AgentStatusWidget
    let usage: UsageWidget?
    @ObservedObject var state: AgentNotchPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferences: AgentNotchSettings { state.preferences }
    private var sessions: [AgentSession] { preferences.sessions(from: agents.sessions) }
    private var working: Int { sessions.filter { $0.state == .running && !$0.needsAttention }.count }
    private var attention: Int { sessions.filter(\.needsAttention).count }

    static func dashboardHeight(preferences: AgentNotchSettings, sessionCount: Int) -> CGFloat {
        let rowHeight = preferences.fontSize * 2 + 34
        let rows = min(preferences.maxSessions, max(1, sessionCount))
        return min(650, 86 + Double(rows) * (rowHeight + preferences.rowSpacing) + (preferences.showUsage ? 154 : 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            compactHeader
                .frame(height: state.headerHeight)
            if state.expanded {
                dashboard
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(preferences.opacity))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: state.notchWidth > 0 ? 6 : preferences.cornerRadius,
                                         bottomLeadingRadius: preferences.cornerRadius,
                                         bottomTrailingRadius: preferences.cornerRadius,
                                         topTrailingRadius: state.notchWidth > 0 ? 6 : preferences.cornerRadius))
        .overlay {
            if preferences.showBorder, state.notchWidth == 0 {
                RoundedRectangle(cornerRadius: preferences.cornerRadius)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .font(.system(size: preferences.fontSize))
        .environment(\.colorScheme, .dark)
        .onHover { state.hover($0) }
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.expanded)
    }

    private var compactHeader: some View {
        HStack(spacing: 0) {
            compactButton {
                HStack(spacing: 6) {
                    if preferences.compactStyle == .providers {
                        ForEach(Array(Set(sessions.map(\.provider))).sorted { $0.id < $1.id }.prefix(3)) { provider in
                            Circle().fill(tint(provider)).frame(width: 7, height: 7)
                        }
                        if sessions.isEmpty { Image(systemName: "sparkles").foregroundStyle(preferences.accent.color) }
                    } else {
                        Image(systemName: attention > 0 ? "exclamationmark.circle.fill" : working > 0 ? "waveform" : "sparkles")
                            .foregroundStyle(attention > 0 ? .orange : preferences.accent.color)
                            .symbolEffect(.pulse, options: .repeating, isActive: working > 0 && preferences.animate && !reduceMotion)
                        if preferences.compactStyle == .counts { Text("\(working)").monospacedDigit().fontWeight(.semibold) }
                    }
                }
            }
            if state.notchWidth > 0 { Color.clear.frame(width: state.notchWidth).allowsHitTesting(false) }
            compactButton {
                HStack(spacing: 5) {
                    if attention > 0 {
                        Circle().fill(.orange).frame(width: 5, height: 5)
                        Text("\(attention)").monospacedDigit()
                    } else if preferences.showTotal {
                        Text("\(sessions.count)").monospacedDigit()
                        if preferences.compactStyle != .minimal { Text("agents").foregroundStyle(.white.opacity(0.55)) }
                    } else {
                        Image(systemName: state.expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                }
            }
        }
        .frame(maxWidth: state.compactWidth)
        .frame(maxWidth: .infinity)
    }

    private func compactButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button {
            if state.expanded { state.setExpanded(false) }
            else if preferences.clickAction == .focus, let session = sessions.first {
                AgentFocus.focus(session: session)
            } else { state.setExpanded(true) }
        } label: {
            content().frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(working) working, \(attention) need attention, \(sessions.count) sessions. \(state.expanded ? "Collapse" : "Open agent dashboard")")
        .help("Click to \(state.expanded ? "collapse" : preferences.clickAction == .focus ? "focus latest session" : "expand"). Hover to show sessions.")
    }

    private var dashboard: some View {
        // Plain VStack first so ImageRenderer and fixed panel frames get a real
        // height; ScrollView alone often draws empty in bitmap captures.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your agents").font(.system(size: preferences.fontSize + 3, weight: .semibold))
                        Text(attention > 0 ? "\(attention) waiting for you" : working > 0 ? "\(working) working · stay in flow" : "All caught up")
                            .font(.system(size: preferences.fontSize - 1)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Button {
                        state.pinned.toggle()
                    } label: {
                        Image(systemName: state.pinned ? "pin.fill" : "pin")
                            .foregroundStyle(state.pinned ? preferences.accent.color : .white.opacity(0.55))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(state.pinned ? "Unpin dashboard" : "Keep dashboard open")
                        .accessibilityLabel(state.pinned ? "Unpin dashboard" : "Pin dashboard")
                    Button { state.setExpanded(false) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel("Collapse dashboard")
                }
                if sessions.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(preferences.accent.color)
                        Text("No matching sessions").fontWeight(.medium)
                        Text("Install agent hooks in Settings > Widgets, or adjust the session filters.")
                            .font(.system(size: preferences.fontSize - 1)).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    VStack(spacing: preferences.rowSpacing) {
                        ForEach(Array(sessions.prefix(preferences.maxSessions).enumerated()), id: \.offset) { _, session in
                            sessionCard(session)
                        }
                    }
                }
                if preferences.showUsage, let usage {
                    NotchUsageDetails(usage: usage, preferences: preferences)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sessionCard(_ session: AgentSession) -> some View {
        Button {
            AgentFocus.focus(session: session)
            if preferences.collapseAfterFocus { state.setExpanded(false) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: session.needsAttention ? "hand.raised.fill" : session.state == .running ? "sparkles" : session.state == .done ? "checkmark" : "moon")
                    .font(.system(size: preferences.fontSize + 1, weight: .medium))
                    .foregroundStyle(session.needsAttention ? .orange : tint(session.provider))
                    .frame(width: 30, height: 30)
                    .background(tint(session.provider).opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(preferences.showProject ? session.project ?? "Untitled session" : session.provider.name)
                        .fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 5) {
                        if preferences.showProviderNames { Text(session.provider.name) }
                        if preferences.showHost, let host = session.host { Text(host) }
                        if preferences.showUpdated { Text(session.updated, style: .relative).monospacedDigit() }
                    }
                    .font(.system(size: max(9, preferences.fontSize - 2)))
                    .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.needsAttention ? "Needs you" : session.state == .running ? "Working" : session.state == .done ? "Finished" : "Idle")
                    .font(.system(size: max(9, preferences.fontSize - 2), weight: .medium))
                    .foregroundStyle(session.needsAttention ? .orange : session.state == .done ? .green : tint(session.provider))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white.opacity(0.05), in: Capsule())
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Open \(session.project ?? session.provider.name) in \(session.host ?? "its terminal or editor")")
    }

    private func tint(_ provider: AgentProvider) -> Color {
        preferences.providerColors ? provider.color : preferences.accent.color
    }
}

private struct NotchUsageDetails: View {
    @ObservedObject var usage: UsageWidget
    let preferences: AgentNotchSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PLAN USAGE").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                Spacer()
                Text("Used").font(.system(size: 10))
            }.foregroundStyle(.white.opacity(0.45))
            if usage.usage.isEmpty {
                Text(usage.providers.isEmpty ? "Choose usage providers in Settings > Widgets." : "Usage follows provider consent in Settings > Widgets.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(usage.usage, id: \.provider.id) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Circle().fill(preferences.providerColors ? item.provider.color : preferences.accent.color).frame(width: 6, height: 6)
                        Text(item.provider.name).font(.system(size: 11, weight: .medium))
                    }
                    if item.windows.isEmpty {
                        Text(item.note ?? "No usage available").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                    ForEach(Array(item.windows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 8) {
                            Text(window.label).frame(width: 30, alignment: .leading).foregroundStyle(.white.opacity(0.5))
                            GeometryReader { geometry in
                                Capsule().fill(.white.opacity(0.09))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(window.percent >= 90 ? .orange : preferences.providerColors ? item.provider.color : preferences.accent.color)
                                            .frame(width: geometry.size.width * window.percent / 100)
                                    }
                            }.frame(height: 4)
                            Text("\(Int(window.percent.rounded()))%")
                                .monospacedDigit().frame(width: 34, alignment: .trailing)
                        }.font(.system(size: 10))
                        .help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Reset time unavailable")
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
