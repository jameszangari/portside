import AppKit
import SwiftUI

struct AgentNotchView: View {
    @ObservedObject var agents: AgentStatusWidget
    let usage: UsageWidget?
    let nowPlaying: NowPlayingWidget?
    @ObservedObject var state: AgentNotchPresentation
    /// The Files page's files: the shelf's own, or sample files in the
    /// Settings preview.
    var fileShelf = NotchFileShelf.shared
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

    /// The shelf's Agents page: the session cards (or the empty note) and
    /// usage.
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
        case .meeting: return dashboardTopPadding + 52 + dashboardBottomPadding
        case .battery, .weather, .airPods: return dashboardTopPadding + 44 + dashboardBottomPadding
        }
    }
    /// The song banner's height below the strip: one line, the song's name.
    static let bannerHeight: CGFloat = 30
    static let dashboardTopPadding: CGFloat = 12
    static let dashboardBottomPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            shelfStrip
                .frame(height: state.headerHeight)
            if state.expanded {
                shelfOpen
                    .transition(.opacity)
            } else if state.banner, state.card == .music {
                songBanner
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
        .foregroundStyle(.white)
        .font(.system(size: preferences.fontSize))
        .environment(\.colorScheme, .dark)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                state.shelfPointer(.at(point, panelWidth: state.panelWidth, compactWidth: state.compactWidth,
                                       notchWidth: state.notchWidth, headerHeight: state.headerHeight))
            case .ended:
                state.shelfPointer(.outside)
            }
        }
        // Files dropped anywhere on the notch go to the Files page (SHELF-06b);
        // the drag opens the shelf on it.
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { state.fileDragOver }, set: { state.fileDrag($0) })) { providers in
            guard state.acceptsFiles else { return false }
            NotchFilesPage.urls(from: providers) { fileShelf.add($0) }
            return true
        }
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.expanded)
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.card)
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.banner)
        .animation(preferences.animate && !reduceMotion ? .easeInOut(duration: preferences.animationDuration) : nil, value: state.surfaceSize)
        .background {
            // Keep compact media bars in sync when Now Playing publishes.
            if let nowPlaying { NotchNowPlayingObserver(widget: nowPlaying) }
        }
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
                            chips: Bool = false, usageRows: Int = 0, clipboard: (count: Int, paused: Bool) = (0, false),
                            searching: Bool = false, files: Int = 0, airPods: Int = 0) -> CGFloat {
        shelfBarHeight + {
            switch page {
            case .agents: agentsPageHeight(preferences: preferences, sessionCount: sessionCount, chips: chips, usageRows: usageRows)
            case .widgets: dashboardTopPadding + NotchShelfCardMetrics.slotHeight + dashboardBottomPadding
            case .clipboard:
                dashboardTopPadding + NotchClipboardPage.height(count: clipboard.count, paused: clipboard.paused, searching: searching)
                    + dashboardBottomPadding
            case .files: dashboardTopPadding + NotchFilesPage.height(count: files) + dashboardBottomPadding
            case .airPods: dashboardTopPadding + airPodsPageHeight(count: airPods) + dashboardBottomPadding
            case nil: 150
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
                case .clipboard:
                    NotchClipboardPage(service: ClipboardService.shared, preferences: preferences,
                                       searching: state.searching, query: $state.query,
                                       onSearch: { state.setSearching($0) }) { state.setExpanded(false) }
                        .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding)
                case .files:
                    NotchFilesPage(shelf: fileShelf, preferences: preferences, dragOver: state.fileDragOver)
                        .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding)
                case .airPods:
                    airPodsPage.padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding)
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

    /// A new song: its name and artist under the strip, as in Bartender.
    /// Hovering it grows it into the music card; a click opens the shelf.
    @ViewBuilder
    private var songBanner: some View {
        if let track = nowPlaying?.track {
            HStack(spacing: 6) {
                Text(track.title).fontWeight(.semibold)
                if let artist = track.artist { Text(artist).foregroundStyle(.white.opacity(0.55)) }
            }
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { state.shelfClick() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing \(track.title)\(track.artist.map { " by \($0)" } ?? "")")
        }
    }

    /// The card below the strip for the hovered activity (or the song
    /// banner once hovered). A click on it opens the shelf, except on its
    /// own controls.
    @ViewBuilder
    private func shelfCard(_ activity: NotchShelfActivity) -> some View {
        Group {
            switch activity {
            case .music:
                if let nowPlaying { NotchMusicCard(widget: nowPlaying, preferences: preferences, layout: .wide) }
            case .agents:
                agentCard
            case .meeting:
                if let meeting = state.meeting { NotchMeetingCard(event: meeting) }
            case .battery, .weather, .airPods:
                if let alert = state.alert { alertCard(alert) }
            }
        }
        .padding(.horizontal, 16).padding(.top, Self.dashboardTopPadding).padding(.bottom, Self.dashboardBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { state.shelfClick() }
    }

    /// A battery or weather alert's card: its symbol, what happened, detail.
    private func alertCard(_ alert: NotchShelfAlert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: alert.symbol).symbolRenderingMode(alert.activity == .weather ? .multicolor : .palette).font(.system(size: 26)).frame(width: 40)
                .foregroundStyle(alert.isWarning ? Color.red : .white, alert.isWarning ? Color.red : .white)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).fontWeight(.semibold)
                if alert.parts.isEmpty {
                    Text(alert.detail).font(.system(size: max(9, preferences.fontSize - 1))).foregroundStyle(.white.opacity(0.55))
                } else {
                    HStack(spacing: 12) {
                        ForEach(alert.parts, id: \.self) { levelPill($0, low: preferences.airPodsLowPercent) }
                    }
                    .accessibilityLabel(alert.detail)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    // MARK: AirPods page

    static let airPodsRowHeight: CGFloat = 44
    static let airPodsRowSpacing: CGFloat = 10

    static func airPodsPageHeight(count: Int) -> CGFloat {
        let rows = CGFloat(max(1, count))
        return rows * airPodsRowHeight + (rows - 1) * airPodsRowSpacing
    }

    /// The shelf's AirPods page, shown while a pair is connected: a row per
    /// pair with its model, name and a bar per part, as on its alert card.
    private var airPodsPage: some View {
        VStack(alignment: .leading, spacing: Self.airPodsRowSpacing) {
            ForEach(state.airPods, id: \.address) { pair in
                HStack(spacing: 12) {
                    Image(systemName: pair.symbol).font(.system(size: 26)).foregroundStyle(.white).frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pair.name).fontWeight(.semibold).lineLimit(1)
                        if pair.parts.isEmpty {
                            Text("Waiting for battery levels").font(.system(size: max(9, preferences.fontSize - 1)))
                                .foregroundStyle(.white.opacity(0.55))
                        } else {
                            HStack(spacing: 12) {
                                ForEach(pair.parts, id: \.self) { levelPill($0, low: preferences.airPodsLowPercent) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Self.airPodsRowHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(pair.name), \(pair.detail)")
            }
        }
    }

    /// One AirPods part on its card: label, a short bar, the number. Red at
    /// or under the low mark, as Bartender's battery pills.
    private func levelPill(_ part: NotchLevelPart, low: Int) -> some View {
        let color: Color = part.percent <= low ? .red : .green
        return HStack(spacing: 4) {
            Text(part.label).foregroundStyle(.white.opacity(0.55))
            Capsule().fill(.white.opacity(0.15)).frame(width: 24, height: 4)
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 24 * CGFloat(part.percent) / 100, height: 4) }
            Text("\(part.percent)%").monospacedDigit()
        }
        .font(.system(size: max(9, preferences.fontSize - 1)))
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
        // The strip is a menu bar's height: a little smaller than the shelf's text.
        .font(.system(size: max(10, preferences.fontSize - 2)))
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
        if state.strip.leading == .meeting || state.strip.trailing == .meeting, let meeting = state.meeting {
            parts.insert("\(meeting.title) \(NotchMeetingCard.detail(meeting, now: Date()))", at: 0)
        }
        if let alert = state.alert { parts.append(alert.title) }
        if let hud = state.hud { parts = [hud.label] }
        return (parts.isEmpty ? "Notch shelf" : parts.joined(separator: ", ")) + ". Open shelf"
    }

    /// One side of the strip: a volume or brightness change while it shows
    /// (SHELF-09), else the running activities.
    @ViewBuilder
    private func stripSide(_ side: NotchShelfSide) -> some View {
        if let hud = state.hud { hudSide(hud, side) } else { activitySide(side) }
    }

    /// The level HUD: its symbol left of the notch, a bar right of it.
    /// Moves like Bartender's, without scaling: on each step the speaker
    /// wiggles (its waves fill with the level) or the sun's rays turn, the
    /// bar springs and the number rolls.
    private func hudSide(_ hud: NotchHUD, _ side: NotchShelfSide) -> some View {
        let animate = preferences.animate && !reduceMotion
        let shown = hud.muted ? 0 : hud.percent
        return Group {
            if side == .leading {
                let step = animate ? hud.percent : 0
                let symbol = Image(systemName: hud.symbol, variableValue: hud.kind == .volume && !hud.muted ? hud.level : nil)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hud.muted ? .white.opacity(0.55) : .white)
                    .contentTransition(.symbolEffect(.replace))
                if hud.kind == .volume {
                    symbol.symbolEffect(.wiggle.forward.byLayer, options: .speed(1.8), value: step)
                } else {
                    symbol.symbolEffect(.rotate.byLayer, options: .speed(2), value: step)
                }
            } else {
                HStack(spacing: 8) {
                    NotchLevelBar(level: hud.level, dimmed: hud.muted, animate: animate)
                    Text("\(shown)").monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(hud.muted ? .white.opacity(0.55) : .white)
                        .contentTransition(.numericText(value: Double(shown)))
                        .animation(animate ? .snappy(duration: 0.2) : nil, value: shown)
                        .fixedSize().frame(minWidth: 26, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, state.expanded || state.card != nil ? 16 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .leading : .trailing)
    }

    /// One side of the strip. Alone, an activity spreads over both sides
    /// (music: art left, bars right); split, each side draws its activity
    /// whole (music and agents both show).
    @ViewBuilder
    private func activitySide(_ side: NotchShelfSide) -> some View {
        let split = state.strip.isSplit
        Group {
            switch state.strip.activity(side) {
            case .music?:
                if split { HStack(spacing: 6) { stripArt; stripBars } } else if side == .leading { stripArt } else { stripBars }
            case .agents?:
                if split { HStack(spacing: 6) { stripAgentMark; stripAgentCount } } else if side == .leading { stripAgentMark } else { stripAgentCount }
            case .meeting?:
                if split { HStack(spacing: 6) { stripMeetingMark; stripCountdown } } else if side == .leading { stripMeetingMark } else { stripCountdown }
            case .battery?, .weather?, .airPods?:
                if let alert = state.alert {
                    HStack(spacing: 4) {
                        Image(systemName: alert.symbol).symbolRenderingMode(alert.activity == .weather ? .multicolor : .palette)
                            .foregroundStyle(alert.isWarning ? Color.red : .white, alert.isWarning ? Color.red : .white)
                        if !alert.short.isEmpty { Text(alert.short).monospacedDigit().fontWeight(.semibold).lineLimit(1) }
                    }
                    .foregroundStyle(alert.isWarning ? .red : .white)
                    .fixedSize()
                }
            case nil:
                Color.clear
            }
        }
        // Open, line up with the cards' 16 pt margin; split, leave room for both marks.
        .padding(.horizontal, state.expanded || state.card != nil ? 16 : split ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .leading : .trailing)
    }

    private var stripPaused: Bool { !preferences.animate || reduceMotion }

    private var stripArt: some View {
        let size = max(14, state.headerHeight - 12)
        return Group {
            if let artwork = nowPlaying?.track?.artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.55)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    /// The bars take the art's color, as in Bartender.
    private var stripBars: some View {
        NotchAudioBars(paused: stripPaused || nowPlaying?.track?.isPlaying != true,
                       color: ArtworkTint.musicColor(nowPlaying?.track, fallback: preferences.accent.color),
                       height: min(14, max(9, state.headerHeight * 0.4)))
    }

    @ViewBuilder
    private var stripAgentMark: some View {
        if attention > 0 {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else if working > 0 {
            let loaderSize = min(16, max(10, state.headerHeight * 0.48))
            ThinkingLoader(style: ThinkingLoader.preferredStyle(preferences.thinking, for: loaderSize), paused: stripPaused, size: loaderSize, color: preferences.accent.color)
        } else {
            Image(systemName: "sparkles").foregroundStyle(preferences.accent.color)
        }
    }

    private var stripAgentCount: some View {
        HStack(spacing: 4) {
            if attention > 0 { Circle().fill(.orange).frame(width: 5, height: 5) }
            Text("\(attention > 0 ? attention : sessions.count)").monospacedDigit().fontWeight(.semibold)
                .foregroundStyle(attention > 0 ? .orange : .white)
        }
    }

    private var stripMeetingMark: some View {
        Image(systemName: "calendar").foregroundStyle(state.meeting?.color ?? .red)
    }

    @ViewBuilder
    private var stripCountdown: some View {
        if let meeting = state.meeting {
            // Each second, for the timer once the meeting starts.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(NotchMeetingCard.stripText(meeting, now: context.date)).monospacedDigit().fontWeight(.semibold)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private func sessionCard(_ session: AgentSession) -> some View {
        Button {
            AgentFocus.focus(session: session)
            if preferences.collapseAfterFocus { state.setExpanded(false) }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if session.state == .running, !session.needsAttention {
                        // Bartender's agent lamp: the working loader.
                        ThinkingLoader(style: ThinkingLoader.preferredStyle(preferences.thinking, for: 14), paused: !preferences.animate || reduceMotion, size: 14, color: tint(session.provider))
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
/// and percentage.
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

/// The HUD's level: a short white bar on a dim track, as in Bartender.
/// Springs to each new level and swells for a moment while it changes.
struct NotchLevelBar: View {
    let level: Double
    var dimmed = false
    var animate = true
    static let width: CGFloat = 64
    @State private var swell = false
    @State private var settle: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.2))
            Capsule().fill(.white.opacity(dimmed ? 0.4 : 1))
                .frame(width: Self.width * min(1, max(0, level)))
        }
        .frame(width: Self.width, height: swell ? 7 : 5)
        .animation(animate ? .spring(response: 0.28, dampingFraction: 0.72) : nil, value: level)
        .animation(animate ? .easeOut(duration: 0.15) : nil, value: swell)
        .onChange(of: level) {
            guard animate else { return }
            swell = true
            settle?.cancel()
            let task = DispatchWorkItem { swell = false }
            settle = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
        }
        .accessibilityHidden(true)
    }
}
