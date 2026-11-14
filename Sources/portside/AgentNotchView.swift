import AppKit
import SwiftUI

struct AgentNotchView: View {
    @ObservedObject var agents: AgentStatusWidget
    let usage: UsageWidget?
    let nowPlaying: NowPlayingWidget?
    @ObservedObject var state: AgentNotchPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferences: AgentNotchSettings { state.preferences }
    private var sessions: [AgentSession] {
        // Read so a finished session's dismiss time redraws the list.
        _ = state.dismissTick
        return preferences.sessions(from: agents.sessions)
    }
    private var working: Int { sessions.filter { $0.state == .running && !$0.needsAttention }.count }
    private var attention: Int { sessions.filter(\.needsAttention).count }
    private var mediaPlaying: Bool {
        preferences.showMedia && nowPlaying?.track?.isPlaying == true
    }

    /// A collapsed pill in a short menu bar cannot take the full radius
    /// (a 24pt bar with 16pt corners would turn it into a lozenge).
    private var bottomRadius: CGFloat {
        if state.expanded || state.card != nil { return preferences.cornerRadius }
        // Attached, the compact pill rounds like the notch it extends
        // (Bartender's Top Shelf: about 12 pt on a 32 pt strip).
        return min(preferences.cornerRadius, state.headerHeight * (state.topAttached ? 0.375 : 0.5))
    }

    static func dashboardHeight(preferences: AgentNotchSettings, sessionCount: Int) -> CGFloat {
        let rowHeight = preferences.fontSize * 2 + 34
        let rows = min(preferences.maxSessions, max(1, sessionCount))
        return min(650, 86 + Double(rows) * (rowHeight + preferences.rowSpacing) + (preferences.showUsage ? 172 : 0))
    }

    /// The shelf's Agents page: the session cards (or the empty note) and
    /// usage, without the classic dashboard's title row.
    static func agentsPageHeight(preferences: AgentNotchSettings, sessionCount: Int, chips: Bool = false, usageRows: Int = 0) -> CGFloat {
        let rowHeight = preferences.fontSize * 2 + 34
        let rows = min(preferences.maxSessions, sessionCount)
        let list = rows == 0 ? 110 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * preferences.rowSpacing
        let chipRow: CGFloat = chips ? chipHeight + preferences.rowSpacing : 0
        let usage: CGFloat = usageRows > 0 ? preferences.rowSpacing + NotchUsageSummary.height(rows: usageRows) : 0
        return min(650, dashboardTopPadding + chipRow + list + usage + dashboardBottomPadding)
    }

    static let chipHeight: CGFloat = 24

    /// Providers with sessions, for the Agents page's chips: name order.
    static func providerChips(_ sessions: [AgentSession]) -> [(provider: AgentProvider, count: Int)] {
        Dictionary(grouping: sessions, by: \.provider.id).values
            .compactMap { group in group.first.map { (provider: $0.provider, count: group.count) } }
            .sorted { $0.provider.name < $1.provider.name }
    }

    /// The sessions a chip shows; a provider with no sessions left shows all.
    static func providerFiltered(_ sessions: [AgentSession], _ provider: String?) -> [AgentSession] {
        guard let provider, sessions.contains(where: { $0.provider.id == provider }) else { return sessions }
        return sessions.filter { $0.provider.id == provider }
    }

    /// A shelf card's height below the strip.
    static func cardHeight(_ activity: NotchShelfActivity, preferences: AgentNotchSettings, sessionCount: Int) -> CGFloat {
        switch activity {
        case .music: return dashboardTopPadding + NotchShelfCardMetrics.wideHeight + dashboardBottomPadding
        case .agents:
            let rowHeight = preferences.fontSize * 2 + 34
            let rows = preferences.agentCard == .all ? min(preferences.maxSessions, max(1, sessionCount)) : 1
            let more: CGFloat = preferences.agentCard == .latest && sessionCount > 1 ? 22 : 0
            return dashboardTopPadding + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * preferences.rowSpacing + more + dashboardBottomPadding
        }
    }
    static let dashboardTopPadding: CGFloat = 12
    static let dashboardBottomPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if preferences.shelfEnabled { shelfStrip } else { compactHeader }
            }
            .frame(height: state.headerHeight)
            if state.expanded {
                Group {
                    if preferences.shelfEnabled { shelfOpen } else { dashboard }
                }
                .transition(.opacity)
            } else if let card = state.card {
                shelfCard(card)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Shelf: draw at the target size, top centered, while the panel holds still.
        .frame(width: state.surfaceSize?.width, height: state.surfaceSize?.height, alignment: .top)
        .background(.black.opacity(preferences.opacity))
        .clipShape(NotchShape(topFlare: state.topAttached ? NotchShape.flare : 0,
                              topRadius: state.topAttached ? 0 : preferences.cornerRadius,
                              bottomRadius: bottomRadius))
        .overlay {
            if preferences.showBorder, !state.topAttached {
                RoundedRectangle(cornerRadius: preferences.cornerRadius)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .font(.system(size: preferences.fontSize))
        .environment(\.colorScheme, .dark)
        .onHover { state.hover($0) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard preferences.shelfEnabled else { return }
            switch phase {
            case .active(let point):
                state.shelfPointer(.at(point, panelWidth: state.panelWidth, compactWidth: state.compactWidth,
                                       notchWidth: state.notchWidth, headerHeight: state.headerHeight))
            case .ended:
                state.shelfPointer(.outside)
            }
        }
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.expanded)
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.card)
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.surfaceSize)
        .background {
            // Keep compact media bars in sync when Now Playing publishes.
            if let nowPlaying { NotchNowPlayingObserver(widget: nowPlaying) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    } else if attention > 0 {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        if preferences.compactStyle == .counts { Text("\(working)").monospacedDigit().fontWeight(.semibold) }
                    } else if working > 0 {
                        let loaderSize = min(16, max(10, preferences.compactHeight * 0.48))
                        ThinkingLoader(
                            style: ThinkingLoader.preferredStyle(for: loaderSize),
                            paused: !preferences.animate || reduceMotion,
                            size: loaderSize,
                            color: preferences.accent.color
                        )
                        if preferences.compactStyle == .counts { Text("\(working)").monospacedDigit().fontWeight(.semibold) }
                    } else if mediaPlaying {
                        NotchAudioBars(
                            paused: !preferences.animate || reduceMotion,
                            color: preferences.accent.color,
                            height: min(14, max(9, preferences.compactHeight * 0.4))
                        )
                    } else if !sessions.isEmpty {
                        Image(systemName: "sparkles")
                            .foregroundStyle(preferences.accent.color)
                        if preferences.compactStyle == .counts { Text("\(working)").monospacedDigit().fontWeight(.semibold) }
                    }
                }
            }
            if state.notchWidth > 0 {
                if preferences.shelfEnabled {
                    // The housing itself opens the shelf on click.
                    Color.clear.frame(width: state.notchWidth).contentShape(Rectangle())
                        .onTapGesture { state.shelfClick() }
                        .accessibilityElement()
                        .accessibilityLabel(state.expanded ? "Close shelf" : "Open shelf")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { state.shelfClick() }
                } else {
                    Color.clear.frame(width: state.notchWidth).allowsHitTesting(false)
                }
            }
            compactButton {
                HStack(spacing: 5) {
                    if mediaPlaying, working > 0 || attention > 0 {
                        NotchAudioBars(
                            paused: !preferences.animate || reduceMotion,
                            color: .white.opacity(0.9),
                            height: min(12, max(8, preferences.compactHeight * 0.36))
                        )
                    }
                    if attention > 0 {
                        Circle().fill(.orange).frame(width: 5, height: 5)
                        Text("\(attention)").monospacedDigit()
                    } else if preferences.showTotal, !sessions.isEmpty {
                        Text("\(sessions.count)").monospacedDigit()
                        if preferences.compactStyle != .minimal { Text("agents").foregroundStyle(.white.opacity(0.55)) }
                    } else if !mediaPlaying {
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
            if preferences.shelfEnabled { state.shelfClick() }
            else if state.expanded { state.setExpanded(false) }
            else if preferences.clickAction == .focus, let session = sessions.first {
                AgentFocus.focus(session: session)
            } else { state.setExpanded(true) }
        } label: {
            content().frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(working) working, \(attention) need attention, \(sessions.count) sessions\(mediaPlaying ? ", media playing" : ""). \(state.expanded ? "Collapse" : "Open agent dashboard")")
        .help("Click to \(state.expanded ? "collapse" : preferences.clickAction == .focus ? "focus latest session" : "expand"). Hover to show sessions.")
    }

    private var dashboard: some View {
        // Plain VStack first so ImageRenderer and fixed panel frames get a real
        // height; ScrollView alone often draws empty in bitmap captures.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !preferences.shelfEnabled { dashboardTitle }
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
            .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding).padding(.bottom, Self.dashboardBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Shelf pages (SHELF-03)

    private var shelfPages: [NotchShelfPage] { preferences.shelfPages.visible(available: state.pageAvailable) }
    private var currentPage: NotchShelfPage? { state.currentPage }

    /// The tab row and the gap above it.
    static let shelfBarHeight: CGFloat = 26 + 10
    static let shelfWidgetSpacing: CGFloat = 10

    /// The open shelf's height below the strip, per page: the tab row, then
    /// the page.
    static func shelfHeight(page: NotchShelfPage?, preferences: AgentNotchSettings, sessionCount: Int,
                            chips: Bool = false, usageRows: Int = 0) -> CGFloat {
        shelfBarHeight + {
            switch page {
            case .agents: agentsPageHeight(preferences: preferences, sessionCount: sessionCount, chips: chips, usageRows: usageRows)
            case .widgets: dashboardTopPadding + NotchShelfCardMetrics.slotHeight + dashboardBottomPadding
            case .clipboard, nil: 150
            }
        }()
    }

    /// The open shelf: the tab row with pin and close on top, as in
    /// Bartender, then the page.
    private var shelfOpen: some View {
        VStack(spacing: 0) {
            shelfBar
                .padding(.horizontal, 16).padding(.top, 10)
            Group {
                switch currentPage {
                case .agents: agentsPage
                case .widgets: shelfWidgets
                case .clipboard: shelfPlaceholder(.clipboard, "Clipboard History comes to the shelf in a later preview.")
                case nil: shelfPlaceholder(nil, "Every page is off. Turn one on in Settings > Top Notch > Shelf.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var shelfBar: some View {
        HStack(spacing: 6) {
            let current = currentPage
            ForEach(shelfPages) { page in
                Button { state.showPage(page) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: page.symbol).font(.system(size: max(9, preferences.fontSize - 2), weight: .semibold))
                        Text(page.title)
                    }
                    .font(.system(size: max(10, preferences.fontSize - 1), weight: .medium))
                    .foregroundStyle(page == current ? .white : .white.opacity(0.55))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(.white.opacity(page == current ? 0.14 : 0.0001), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(page == current ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 4)
            Button {
                state.setPinned(!state.pinned)
            } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(state.pinned ? preferences.accent.color : .white.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).help(state.pinned ? "Unpin shelf" : "Keep shelf open")
                .accessibilityLabel(state.pinned ? "Unpin shelf" : "Pin shelf")
            Button { state.setExpanded(false) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("Close shelf")
        }
    }

    /// The Widgets page: Bartender's two slots, side by side.
    private var shelfWidgets: some View {
        HStack(spacing: Self.shelfWidgetSpacing) {
            shelfSlot(preferences.shelfLeadingWidget)
            shelfSlot(preferences.shelfTrailingWidget)
        }
        .frame(height: NotchShelfCardMetrics.slotHeight)
        .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func shelfSlot(_ slot: NotchShelfSlot) -> some View {
        Group {
            switch slot {
            case .music:
                if let nowPlaying { NotchMusicCard(widget: nowPlaying, preferences: preferences, layout: .slot) } else { slotLoading }
            case .weather:
                if let weather = state.widgetHost(WeatherWidget.kind)?.widget as? WeatherWidget { NotchWeatherCard(widget: weather) } else { slotLoading }
            case .calendar:
                if let calendar = state.widgetHost(CalendarWidget.kind)?.widget as? CalendarWidget { NotchCalendarCard(widget: calendar) } else { slotLoading }
            case .empty:
                Color.clear
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(slot == .empty ? 0 : 0.055), in: RoundedRectangle(cornerRadius: NotchShelfCardMetrics.slotRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: NotchShelfCardMetrics.slotRadius, style: .continuous))
    }

    private var slotLoading: some View { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }

    private func shelfPlaceholder(_ page: NotchShelfPage?, _ message: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: page?.symbol ?? "rectangle.slash").font(.title2).foregroundStyle(preferences.accent.color)
            if let page { Text(page.title).fontWeight(.medium) }
            Text(message)
                .font(.system(size: preferences.fontSize - 1)).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.top, 24)
        .accessibilityElement(children: .combine)
    }

    private var dashboardTitle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your agents").font(.system(size: preferences.fontSize + 3, weight: .semibold))
                Text(attention > 0 ? "\(attention) waiting for you" : working > 0 ? "\(working) working · stay in flow" : "All caught up")
                    .font(.system(size: preferences.fontSize - 1)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                state.setPinned(!state.pinned)
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
    }

    /// The card below the strip for the hovered activity (or the song
    /// banner). A click on it opens the shelf, except on its own controls.
    @ViewBuilder
    private func shelfCard(_ activity: NotchShelfActivity) -> some View {
        Group {
            switch activity {
            case .music:
                if let nowPlaying { NotchMusicCard(widget: nowPlaying, preferences: preferences, layout: .wide) }
            case .agents:
                agentCard
            }
        }
        .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding).padding(.bottom, Self.dashboardBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { state.shelfClick() }
    }

    /// Bartender's agent card: the latest session, "+N more" below; or
    /// every running session when Settings asks for all.
    private var agentCard: some View {
        let ordered = sessions.sorted { $0.updated > $1.updated }
        let shown = preferences.agentCard == .all ? Array(ordered.prefix(preferences.maxSessions)) : Array(ordered.prefix(1))
        return VStack(alignment: .leading, spacing: preferences.rowSpacing) {
            ForEach(shown, id: \.id) { sessionCard($0) }
            if preferences.agentCard == .latest, ordered.count > 1 {
                Text("+\(ordered.count - 1) more").font(.system(size: max(9, preferences.fontSize - 2), weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)).padding(.leading, 4)
            }
        }
    }

    // MARK: Agents page (SHELF-05)

    /// The shelf's Agents page: provider chips when more than one provider
    /// has sessions, the session cards, and a one-line-per-provider usage
    /// summary.
    private var agentsPage: some View {
        let all = sessions
        let chips = Self.providerChips(all)
        let shown = Self.providerFiltered(all, state.agentProvider)
        return ScrollView {
            VStack(alignment: .leading, spacing: preferences.rowSpacing) {
                if chips.count > 1 {
                    HStack(spacing: 6) {
                        chip("All", count: all.count, selected: state.agentProvider == nil || shown.count == all.count, tint: preferences.accent.color) {
                            state.agentProvider = nil
                        }
                        ForEach(chips, id: \.provider.id) { item in
                            chip(item.provider.name, count: item.count, selected: state.agentProvider == item.provider.id && shown.count != all.count,
                                 tint: tint(item.provider)) {
                                state.agentProvider = item.provider.id
                            }
                        }
                    }
                    .frame(height: Self.chipHeight)
                }
                if shown.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(preferences.accent.color)
                        Text("No agents running").fontWeight(.medium)
                        Text("Claude Code and Codex need Agent Hooks (Settings > Widgets).")
                            .font(.system(size: preferences.fontSize - 1)).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    ForEach(Array(shown.prefix(preferences.maxSessions).enumerated()), id: \.offset) { _, session in
                        sessionCard(session)
                    }
                }
                if preferences.showUsage, let usage, !usage.usage.isEmpty {
                    NotchUsageSummary(usage: usage, preferences: preferences)
                }
            }
            .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding).padding(.bottom, Self.dashboardBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func chip(_ title: String, count: Int, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? tint : .white.opacity(0.45))
            }
            .font(.system(size: max(10, preferences.fontSize - 1), weight: .medium))
            .foregroundStyle(selected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10).frame(height: Self.chipHeight)
            .background(.white.opacity(selected ? 0.14 : 0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) sessions")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Compact strip (SHELF-04c)

    /// The shelf's compact strip: what `state.strip` says on each side of
    /// the notch. A click anywhere opens the shelf.
    private var shelfStrip: some View {
        HStack(spacing: 0) {
            stripSide(.leading)
            Color.clear.frame(width: state.notchWidth > 0 ? state.notchWidth : state.compactWidth / 3)
            stripSide(.trailing)
        }
        // Compact, the strip hugs the notch; with a card or the shelf open
        // it spans the surface, so the side icons move out with it.
        .frame(maxWidth: state.expanded || state.card != nil ? .infinity : state.compactWidth)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { state.shelfClick() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stripLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.shelfClick() }
    }

    private var stripLabel: String {
        var parts: [String] = []
        if state.strip.leading == .music || state.strip.trailing == .music, let track = nowPlaying?.track {
            parts.append("Now playing \(track.title)")
        }
        if state.strip.leading == .agents || state.strip.trailing == .agents {
            parts.append("\(sessions.count) agent sessions\(attention > 0 ? ", \(attention) need you" : "")")
        }
        return (parts.isEmpty ? "Notch shelf" : parts.joined(separator: ", ")) + ". Open shelf"
    }

    @ViewBuilder
    private func stripSide(_ side: NotchShelfSide) -> some View {
        let paused = !preferences.animate || reduceMotion
        Group {
            switch (state.strip.activity(side), side) {
            case (.music?, .leading):
                let size = max(14, state.headerHeight - 12)
                Group {
                    if let artwork = nowPlaying?.track?.artwork {
                        Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.system(size: size * 0.55)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: size, height: size)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            case (.music?, .trailing):
                NotchAudioBars(paused: paused || nowPlaying?.track?.isPlaying != true, color: preferences.accent.color,
                               height: min(14, max(9, state.headerHeight * 0.4)))
            case (.agents?, .leading):
                if attention > 0 {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else if working > 0 {
                    let loaderSize = min(16, max(10, state.headerHeight * 0.48))
                    ThinkingLoader(style: ThinkingLoader.preferredStyle(for: loaderSize), paused: paused, size: loaderSize, color: preferences.accent.color)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(preferences.accent.color)
                }
            case (.agents?, .trailing):
                HStack(spacing: 4) {
                    if attention > 0 { Circle().fill(.orange).frame(width: 5, height: 5) }
                    Text("\(attention > 0 ? attention : sessions.count)").monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(attention > 0 ? .orange : .white)
                }
            case (nil, _):
                Color.clear
            }
        }
        // Open, line up with the cards' 16 pt margin.
        .padding(.horizontal, state.expanded || state.card != nil ? 16 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .leading : .trailing)
    }

    private func sessionCard(_ session: AgentSession) -> some View {
        Button {
            AgentFocus.focus(session: session)
            if preferences.collapseAfterFocus { state.setExpanded(false) }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if preferences.shelfEnabled, session.state == .running, !session.needsAttention {
                        // Bartender's agent lamp: the working loader.
                        ThinkingLoader(style: .snakeBoxes, paused: !preferences.animate || reduceMotion, size: 14, color: tint(session.provider))
                    } else {
                        Image(systemName: session.needsAttention ? "hand.raised.fill" : session.state == .running ? "sparkles" : session.state == .done ? "checkmark" : "moon")
                            .font(.system(size: preferences.fontSize + 1, weight: .medium))
                            .foregroundStyle(session.needsAttention ? .orange : tint(session.provider))
                    }
                }
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

/// Observes the Now Playing widget so the notch redraws on play/pause
/// without owning the widget as a required ObservedObject.
private struct NotchNowPlayingObserver: View {
    @ObservedObject var widget: NowPlayingWidget
    var body: some View { Color.clear.accessibilityHidden(true) }
}

/// The Agents page's usage: one row per provider with each window's bar
/// and percentage. The classic dashboard keeps `NotchUsageDetails`.
struct NotchUsageSummary: View {
    @ObservedObject var usage: UsageWidget
    let preferences: AgentNotchSettings

    static let rowHeight: CGFloat = 18
    static let rowSpacing: CGFloat = 8
    static func height(rows: Int) -> CGFloat {
        24 + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(usage.usage, id: \.provider.id) { item in
                HStack(spacing: 10) {
                    Circle().fill(preferences.providerColors ? item.provider.color : preferences.accent.color).frame(width: 6, height: 6)
                    Text(item.provider.name).font(.system(size: 11, weight: .medium)).frame(width: 64, alignment: .leading)
                    if item.windows.isEmpty {
                        Text(item.note ?? "No usage available").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    ForEach(Array(item.windows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 6) {
                            Text(window.label).foregroundStyle(.white.opacity(0.5))
                            GeometryReader { geometry in
                                Capsule().fill(.white.opacity(0.09))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(window.percent >= 90 ? .orange : preferences.providerColors ? item.provider.color : preferences.accent.color)
                                            .frame(width: geometry.size.width * min(1, window.percent / 100))
                                    }
                            }
                            .frame(height: 4)
                            Text("\(Int(window.percent.rounded()))%").monospacedDigit().frame(width: 32, alignment: .trailing)
                        }
                        .font(.system(size: 10))
                        .help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Reset time unavailable")
                    }
                }
                .frame(height: Self.rowHeight)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
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
                        if let used = window.used, let limit = window.limit {
                            // Request quotas (Copilot): the count behind the percentage.
                            HStack(spacing: 4) {
                                Text("\(used.formatted()) / \(limit.formatted()) \(window.unit ?? "requests")")
                                    .monospacedDigit()
                                Spacer(minLength: 4)
                                if let reset = window.resetsAt {
                                    Text("Resets \(reset.formatted(.dateTime.month(.abbreviated).day()))")
                                }
                            }
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.leading, 38)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

}

/// The island's outline. Attached to the top edge, its top corners flare
/// outward into the screen edge like the hardware notch (and Bartender's
/// Top Shelf) instead of rounding inward, so no wallpaper shows at the
/// top. Floating, it is a rounded rectangle. The flare sits inside the
/// frame, so the body is `2 * topFlare` narrower than the frame.
struct NotchShape: Shape {
    static let flare: CGFloat = 5

    var topFlare: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(topFlare, AnimatablePair(topRadius, bottomRadius)) }
        set { topFlare = newValue.first; topRadius = newValue.second.first; bottomRadius = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let flare = max(0, min(topFlare, rect.width / 4, rect.height / 2))
        let left = rect.minX + flare
        let right = rect.maxX - flare
        let bottom = max(0, min(bottomRadius, (right - left) / 2, rect.height - flare))
        let top = flare > 0 ? 0 : max(0, min(topRadius, (right - left) / 2, rect.height / 2))
        var path = Path()
        if flare > 0 {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: flare)
        } else {
            path.move(to: CGPoint(x: left, y: rect.minY + top))
        }
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: bottom)
        if flare > 0 {
            path.addLine(to: CGPoint(x: right, y: rect.minY + flare))
            path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: flare)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.minY), radius: top)
            path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: top)
        }
        path.closeSubpath()
        return path
    }
}
