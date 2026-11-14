import XCTest
@testable import portside

final class NotchShelfTests: XCTestCase {
    // MARK: Regions

    /// 400 pt panel, 200 pt header with a 100 pt notch, 32 pt header height.
    private func region(_ x: CGFloat, _ y: CGFloat, notch: CGFloat = 100) -> NotchShelfRegion {
        .at(CGPoint(x: x, y: y), panelWidth: 400, compactWidth: 200, notchWidth: notch, headerHeight: 32)
    }

    func testRegionsAcrossTheHeader() {
        XCTAssertEqual(region(110, 10), .side(.leading))
        XCTAssertEqual(region(200, 10), .notch)
        XCTAssertEqual(region(290, 10), .side(.trailing))
        XCTAssertEqual(region(50, 10), .body, "panel wider than the header: outside the header is content")
        XCTAssertEqual(region(200, 60), .body)
        XCTAssertEqual(region(-1, 10), .outside)
        XCTAssertEqual(region(401, 10), .outside)
    }

    func testWithoutNotchMiddleThirdActsAsNotch() {
        XCTAssertEqual(region(120, 10, notch: 0), .side(.leading))
        XCTAssertEqual(region(200, 10, notch: 0), .notch)
        XCTAssertEqual(region(280, 10, notch: 0), .side(.trailing))
    }

    // MARK: One hover rule (SHELF-04c)

    private let musicStrip = NotchShelfStrip.layout(music: true, agents: true, agentAlert: false)
    private func music(_ side: NotchShelfSide) -> NotchShelfActivity? { musicStrip.activity(side) }

    func testStripLayout() {
        XCTAssertEqual(musicStrip, NotchShelfStrip(leading: .music, trailing: .music), "music takes both sides from agents")
        XCTAssertEqual(NotchShelfStrip.layout(music: true, agents: true, agentAlert: true),
                       NotchShelfStrip(leading: .music, trailing: .agents), "an agent alert borrows the right side")
        XCTAssertEqual(NotchShelfStrip.layout(music: true, agents: false, agentAlert: true), musicStrip, "no agents: no alert")
        XCTAssertEqual(NotchShelfStrip.layout(music: false, agents: true, agentAlert: false), NotchShelfStrip(leading: .agents, trailing: .agents))
        XCTAssertEqual(NotchShelfStrip.layout(music: false, agents: false, agentAlert: true), NotchShelfStrip())
    }

    func testHoveringAnActivityShowsItsCardAfterTheDelay() {
        var m = NotchShelfMachine()
        XCTAssertEqual(m.pointer(.side(.leading), activity: music), .card(.music))
        XCTAssertEqual(m.phase, .compact, "nothing changes before the delay")
        m.fire(.card(.music))
        XCTAssertEqual(m.card, .music)
        XCTAssertNil(m.pointer(.side(.trailing), activity: music), "the other side shows the same activity: the card stays")
        XCTAssertNil(m.pointer(.body, activity: music), "moving onto the card keeps it")
    }

    func testNotchMiddleAlwaysOpens() {
        var m = NotchShelfMachine()
        XCTAssertEqual(m.pointer(.notch, activity: music), .open)
        m.fire(.open)
        XCTAssertTrue(m.isOpen)
        var fromCard = NotchShelfMachine()
        fromCard.pointer(.side(.leading), activity: music); fromCard.fire(.card(.music))
        XCTAssertEqual(fromCard.pointer(.notch, activity: music), .open, "card to notch opens the shelf")
    }

    func testNothingRunningOpensTheShelf() {
        var m = NotchShelfMachine()
        XCTAssertEqual(m.pointer(.side(.leading)), .open)
        XCTAssertEqual(m.pointer(.side(.trailing)), .open)
    }

    func testCardFollowsTheHoveredActivity() {
        let alert = NotchShelfStrip.layout(music: true, agents: true, agentAlert: true)
        var m = NotchShelfMachine()
        m.pointer(.side(.leading)) { alert.activity($0) }; m.fire(.card(.music))
        XCTAssertEqual(m.pointer(.side(.trailing)) { alert.activity($0) }, .card(.agents))
        m.fire(.card(.agents))
        XCTAssertEqual(m.card, .agents)
    }

    func testPassingOverAnActivityDoesNotShowItsCard() {
        var m = NotchShelfMachine()
        m.pointer(.side(.leading), activity: music)
        m.pointer(.outside)
        m.fire(.card(.music))
        XCTAssertEqual(m.phase, .compact, "a stale timer is ignored")
    }

    func testLeavingACardUsesTheShortCollapse() {
        var m = NotchShelfMachine()
        m.pointer(.side(.leading), activity: music); m.fire(.card(.music))
        XCTAssertEqual(m.pointer(.outside), .collapseCard)
        m.fire(.collapseCard)
        XCTAssertEqual(m.phase, .compact)
    }

    func testLeavingOpenShelfCollapsesUnlessReentered() {
        var m = NotchShelfMachine()
        m.open()
        XCTAssertEqual(m.pointer(.outside), .collapse)
        XCTAssertNil(m.pointer(.body), "coming back cancels the collapse")
        m.fire(.collapse)
        XCTAssertTrue(m.isOpen)
        XCTAssertNil(m.pointer(.side(.leading), activity: music), "the strip never turns an open shelf into a card")
        m.pointer(.outside); m.fire(.collapse)
        XCTAssertEqual(m.phase, .compact)
    }

    func testClickOpensAndNeverCloses() {
        var m = NotchShelfMachine()
        m.pointer(.side(.leading), activity: music); m.fire(.card(.music))
        m.click()
        XCTAssertTrue(m.isOpen, "a click on a card opens the shelf")
        XCTAssertFalse(m.pinned)
        m.click()
        XCTAssertTrue(m.isOpen, "like Bartender, a second click does not close")
    }

    func testBannerShowsTheMusicCardThenHides() {
        var m = NotchShelfMachine()
        XCTAssertEqual(m.showBanner(), .bannerEnd)
        XCTAssertEqual(m.card, .music)
        m.fire(.bannerEnd)
        XCTAssertEqual(m.phase, .compact)
        XCTAssertEqual(m.showBanner(), .bannerEnd)
        XCTAssertNil(m.pointer(.body, activity: music), "the pointer on the banner keeps it")
        m.fire(.bannerEnd)
        XCTAssertEqual(m.card, .music, "a stale banner timer is ignored")
        XCTAssertEqual(m.pointer(.outside), .collapseCard, "then it behaves like a hovered card")
        m.open()
        XCTAssertNil(m.showBanner(), "no banner over an open shelf")
    }

    func testCloseClearsPinAndPending() {
        var m = NotchShelfMachine()
        m.click(); m.setPinned(true)
        XCTAssertNil(m.pointer(.outside), "pinned survives the pointer leaving")
        m.pointer(.side(.leading), activity: music)
        m.close()
        XCTAssertEqual(m.phase, .compact)
        XCTAssertFalse(m.pinned)
        XCTAssertNil(m.pending)
    }

    func testPinOnlyWhileOpen() {
        var m = NotchShelfMachine()
        m.setPinned(true)
        XCTAssertFalse(m.pinned)
        m.open(); m.setPinned(true)
        XCTAssertTrue(m.pinned)
    }

    // MARK: Settings

    func testSettingsDefaultsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"expandOnHover":false,"shelfOpenMode":"click"}"#.utf8))
        XCTAssertFalse(old.shelfEnabled, "existing files keep the classic island")
        XCTAssertEqual(old.shelfHoverDelay, 0.15)
        XCTAssertEqual(old.shelfCollapseDelay, 0.8)
        XCTAssertEqual(old.musicStyle, .music)
        XCTAssertTrue(old.musicSeeking && old.musicHideWhenPaused && old.musicBanner)
        XCTAssertFalse(old.musicTint || old.shelfHaptics)
        XCTAssertEqual(old.agentCard, .latest)
        var settings = AgentNotchSettings()
        settings.shelfEnabled = true
        settings.musicStyle = .vinyl
        settings.musicTint = true
        settings.agentCard = .all
        settings.shelfHoverDelay = 5
        settings.normalize()
        XCTAssertEqual(settings.shelfHoverDelay, 1, "bounded")
        let data = try JSONEncoder().encode(settings)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("shelfOpenMode"), "the removed setting is not written")
        let back = try JSONDecoder().decode(AgentNotchSettings.self, from: data)
        XCTAssertEqual(back, settings)
    }

    // MARK: Menu bar coordination (SHELF-02)

    func testExclusionJoinsNotchAndHeaderWithMargin() throws {
        let band = CGRect(x: 0, y: 1080, width: 1728, height: 38)
        let m = MenuBarShelfExclusion.margin
        let joined = try XCTUnwrap(MenuBarShelfExclusion.rect(band: band, notch: 800...928, header: 770...958))
        XCTAssertEqual(joined, CGRect(x: 770 - m, y: 1080, width: 188 + 2 * m, height: 38))
        let notchOnly = try XCTUnwrap(MenuBarShelfExclusion.rect(band: band, notch: 800...928, header: nil))
        XCTAssertEqual(notchOnly.minX, 800 - m)
        XCTAssertEqual(notchOnly.maxX, 928 + m)
        XCTAssertNil(MenuBarShelfExclusion.rect(band: band, notch: nil, header: nil), "below the bar without a notch: nothing to exclude")
    }

    func testExclusionContainsOnlyItsRects() {
        defer { MenuBarShelfExclusion.update([]) }
        MenuBarShelfExclusion.update([CGRect(x: 100, y: 0, width: 50, height: 30)])
        XCTAssertTrue(MenuBarShelfExclusion.contains(CGPoint(x: 120, y: 10)))
        XCTAssertFalse(MenuBarShelfExclusion.contains(CGPoint(x: 200, y: 10)))
        MenuBarShelfExclusion.update([])
        XCTAssertFalse(MenuBarShelfExclusion.contains(CGPoint(x: 120, y: 10)))
    }

    func testShelfLocksPresentationWithoutChangingTheSavedChoice() {
        var settings = MenuBarTriggerSettings()
        for saved in MenuBarPresentation.allCases {
            settings.presentation = saved
            XCTAssertEqual(settings.presentation(notchShelf: true), .portsideBar)
            XCTAssertEqual(settings.presentation(notchShelf: false), saved)
        }
    }

    // MARK: Pages (SHELF-03)

    private let all: (NotchShelfPage) -> Bool = { _ in true }

    func testPagesDefaultsAndOpening() {
        let pages = NotchShelfPages()
        XCTAssertEqual(pages.order, [.widgets, .agents, .clipboard])
        XCTAssertEqual(pages.start, .first)
        XCTAssertEqual(pages.opening(lastUsed: .clipboard, available: all), .widgets, "like Bartender: the first tab")
        var last = pages
        last.start = .lastUsed
        XCTAssertEqual(last.opening(lastUsed: nil, available: all), .widgets, "no last page: the first")
        XCTAssertEqual(last.opening(lastUsed: .clipboard, available: all), .clipboard)
    }

    func testFixedStartAndUnavailablePages() {
        var pages = NotchShelfPages()
        pages.start = .clipboard
        XCTAssertEqual(pages.opening(lastUsed: .agents, available: all), .clipboard)
        let noClipboard: (NotchShelfPage) -> Bool = { $0 != .clipboard }
        XCTAssertEqual(pages.visible(available: noClipboard), [.widgets, .agents])
        XCTAssertEqual(pages.opening(lastUsed: nil, available: noClipboard), .widgets, "start page unavailable: the first")
        pages.setOn(.widgets, false)
        XCTAssertEqual(pages.opening(lastUsed: nil, available: noClipboard), .agents)
        pages.setOn(.agents, false)
        XCTAssertNil(pages.opening(lastUsed: nil, available: noClipboard))
    }

    func testPagesMoveWithinBounds() {
        var pages = NotchShelfPages()
        pages.move(.clipboard, by: -1)
        XCTAssertEqual(pages.order, [.widgets, .clipboard, .agents])
        pages.move(.widgets, by: -1)
        XCTAssertEqual(pages.order, [.widgets, .clipboard, .agents], "first stays first")
        pages.move(.agents, by: 1)
        XCTAssertEqual(pages.order, [.widgets, .clipboard, .agents])
    }

    func testPagesDecodeRepairsOrder() throws {
        let json = #"{"order":["agents","bogus","agents"],"hidden":["clipboard","nope"],"start":"weird"}"#
        let pages = try JSONDecoder().decode(NotchShelfPages.self, from: Data(json.utf8))
        XCTAssertEqual(pages.order, [.agents, .widgets, .clipboard], "unknown and repeated dropped, missing appended")
        XCTAssertFalse(pages.isOn(.clipboard))
        XCTAssertEqual(pages.start, .first)
        let back = try JSONDecoder().decode(NotchShelfPages.self, from: JSONEncoder().encode(pages))
        XCTAssertEqual(back, pages)
        let settings = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"shelfEnabled":true}"#.utf8))
        XCTAssertEqual(settings.shelfPages, NotchShelfPages(), "older files get the default pages")
    }

    // MARK: Widgets page (SHELF-04c)

    func testSlotsDefaultAndMigrateFromTheWidgetList() throws {
        let fresh = AgentNotchSettings()
        XCTAssertEqual(fresh.shelfLeadingWidget, .music)
        XCTAssertEqual(fresh.shelfTrailingWidget, .calendar)
        let list = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"shelfWidgets":["clock","weather","nowPlaying"]}"#.utf8))
        XCTAssertEqual(list.shelfLeadingWidget, .weather, "kinds without a slot are skipped")
        XCTAssertEqual(list.shelfTrailingWidget, .music)
        XCTAssertEqual(NotchShelfSlot.migrated(["calendar"]).trailing, .music, "one kind: the other default fills in")
        let saved = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"shelfWidgets":["weather"],"shelfLeadingWidget":"empty"}"#.utf8))
        XCTAssertEqual(saved.shelfLeadingWidget, .empty, "a saved slot wins over the old list")
        XCTAssertEqual(NotchShelfSlot.empty.widgetKind, nil)
    }

    // MARK: Music card

    func testTrackPositionAdvancesOnlyWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1_000)
        let player = NowPlayingWidget.Player(bundleID: "x", name: "X", notification: "")
        var track = NowPlayingWidget.Track(id: "1", title: "T", artist: nil, artwork: nil, artworkURL: nil, isPlaying: true,
                                           player: player, duration: 100, elapsed: 30, elapsedAt: start)
        XCTAssertEqual(track.position(at: start.addingTimeInterval(10)), 40)
        XCTAssertEqual(track.position(at: start.addingTimeInterval(500)), 100, "never past the end")
        track.isPlaying = false
        XCTAssertEqual(track.position(at: start.addingTimeInterval(10)), 30)
        track.elapsed = nil
        XCTAssertNil(track.position(at: start))
        XCTAssertEqual(NotchProgressBar.time(72, known: true), "1:12")
        XCTAssertEqual(NotchProgressBar.time(3725, known: true), "1:02:05")
        XCTAssertEqual(NotchProgressBar.time(0, known: false), "--:--")
    }

    func testMeetingLinks() {
        let zoom = URL(string: "https://acme.zoom.us/j/123")!
        XCTAssertEqual(CalendarWidget.meetingLink(url: zoom, texts: []), zoom)
        XCTAssertNil(CalendarWidget.meetingLink(url: URL(string: "https://example.com")!, texts: ["Room 4"]))
        XCTAssertEqual(CalendarWidget.meetingLink(url: nil, texts: [nil, "Agenda\nhttps://meet.google.com/abc-defg-hij"]),
                       URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertNil(CalendarWidget.meetingLink(url: nil, texts: ["http://zoom.us/j/1"]), "https only")
    }

    // MARK: Agents page (SHELF-05)

    private func session(_ id: String, _ provider: String, _ state: AgentState, ago: TimeInterval, now: Date) -> AgentSession {
        AgentSession(id: id, provider: AgentProvider.named(provider), pid: 0, state: state, needsAttention: false, ended: false,
                     updated: now.addingTimeInterval(-ago), project: id, host: nil)
    }

    func testFinishedSessionsLeaveAfterTheDismissTime() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let all = [session("a", "claude", .done, ago: 4 * 60, now: now), session("b", "codex", .done, ago: 6 * 60, now: now),
                   session("c", "codex", .running, ago: 3600, now: now)]
        var settings = AgentNotchSettings()
        XCTAssertEqual(settings.finishedDismissMinutes, 5)
        XCTAssertEqual(settings.sessions(from: all, now: now).map(\.id), ["a", "c"], "running sessions never leave")
        XCTAssertEqual(settings.dismissDate(all[0]), all[0].updated.addingTimeInterval(300))
        XCTAssertNil(settings.dismissDate(all[2]))
        settings.finishedDismissMinutes = 0
        XCTAssertEqual(settings.sessions(from: all, now: now).count, 3, "Never keeps them")
        let bad = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"finishedDismissMinutes":7}"#.utf8))
        XCTAssertEqual(bad.finishedDismissMinutes, 5, "only the offered choices")
    }

    func testProviderChipsAndFilter() {
        let now = Date()
        let all = [session("a", "codex", .running, ago: 0, now: now), session("b", "claude", .running, ago: 0, now: now),
                   session("c", "codex", .done, ago: 0, now: now)]
        let chips = AgentNotchView.providerChips(all)
        XCTAssertEqual(chips.map(\.provider.id), ["claude", "codex"])
        XCTAssertEqual(chips.map(\.count), [1, 2])
        XCTAssertEqual(AgentNotchView.providerFiltered(all, "codex").map(\.id), ["a", "c"])
        XCTAssertEqual(AgentNotchView.providerFiltered(all, nil).count, 3)
        XCTAssertEqual(AgentNotchView.providerFiltered(all, "copilot").count, 3, "a provider with nothing left shows all")
        XCTAssertGreaterThan(AgentNotchView.agentsPageHeight(preferences: AgentNotchSettings(), sessionCount: 2, chips: true, usageRows: 2),
                             AgentNotchView.agentsPageHeight(preferences: AgentNotchSettings(), sessionCount: 2))
    }

    // MARK: Clipboard page (SHELF-06)

    func testClipboardPageShowsNewestSixAndSizesToRows() {
        let base = Date(timeIntervalSince1970: 1_000)
        let entries = (0..<8).map { ClipboardEntry(text: "clip \($0)", date: base.addingTimeInterval(TimeInterval($0))) }
        let shown = NotchClipboardPage.shown(entries)
        XCTAssertEqual(shown.count, 6)
        XCTAssertEqual(shown.first?.text, "clip 7", "newest first")
        let one = NotchClipboardPage.height(count: 2, paused: false)
        let two = NotchClipboardPage.height(count: 8, paused: false)
        XCTAssertEqual(one, NotchClipboardPage.cardHeight)
        XCTAssertEqual(two, 2 * NotchClipboardPage.cardHeight + NotchClipboardPage.spacing, "never more than two rows")
        XCTAssertGreaterThan(NotchClipboardPage.height(count: 2, paused: true), one, "the paused note adds a row")
        XCTAssertGreaterThan(NotchClipboardPage.height(count: 0, paused: false), 0, "empty state has room")
    }

    // MARK: Strip priority and alerts (SHELF-07)

    func testStripFollowsTheOrderAndAlertsBorrowTheRight() {
        XCTAssertEqual(NotchShelfStrip.layout(active: [.meeting, .music], alert: nil), NotchShelfStrip(leading: .meeting, trailing: .meeting))
        XCTAssertEqual(NotchShelfStrip.layout(active: [.music], alert: .battery), NotchShelfStrip(leading: .music, trailing: .battery))
        XCTAssertEqual(NotchShelfStrip.layout(active: [], alert: .weather), NotchShelfStrip(leading: nil, trailing: .weather))
        XCTAssertEqual(NotchShelfOrder.normalized([.agents, .battery, .agents]), [.agents, .meeting, .music],
                       "alerts never own the strip; repeats dropped, missing appended")
        XCTAssertEqual(AgentNotchSettings().stripOrder, [.meeting, .music, .agents])
    }

    func testMeetingWindowAndNextChange() {
        let now = Date(timeIntervalSince1970: 100_000)
        let starts = [(start: now.addingTimeInterval(600), allDay: false), (start: now.addingTimeInterval(120), allDay: true),
                      (start: now.addingTimeInterval(240), allDay: false)]
        XCTAssertEqual(NotchMeetingSoon.current(starts, now: now, minutes: 5), 2, "4 min away, all-day skipped")
        XCTAssertNil(NotchMeetingSoon.current(starts, now: now, minutes: 1))
        XCTAssertNil(NotchMeetingSoon.current(starts, now: now, minutes: 0), "off")
        XCTAssertEqual(NotchMeetingSoon.nextChange(starts, now: now, minutes: 5), now.addingTimeInterval(300), "the 10 min meeting enters")
        XCTAssertEqual(NotchMeetingSoon.current(starts, now: now.addingTimeInterval(290), minutes: 5), 2, "until a minute after start")
        XCTAssertEqual(NotchMeetingCard.countdown(to: now.addingTimeInterval(61), now: now), "in 2 min")
        XCTAssertEqual(NotchMeetingCard.countdown(to: now.addingTimeInterval(-10), now: now), "now")
    }

    func testBatteryAlerts() {
        XCTAssertNil(NotchBatteryAlert.detect(previous: nil, current: (15, false), low: 20), "no alert for the first reading")
        XCTAssertEqual(NotchBatteryAlert.detect(previous: (21, false), current: (20, false), low: 20), .low)
        XCTAssertNil(NotchBatteryAlert.detect(previous: (19, false), current: (18, false), low: 20), "only when crossing")
        XCTAssertEqual(NotchBatteryAlert.detect(previous: (40, false), current: (40, true), low: 20), .pluggedIn)
        XCTAssertNil(NotchBatteryAlert.detect(previous: (40, true), current: (41, true), low: 20))
    }

    func testWeatherAlerts() {
        let now = Date(timeIntervalSince1970: 200_000)
        let hours = [(date: now.addingTimeInterval(-600), code: 3), (date: now.addingTimeInterval(3000), code: 61)]
        let found = NotchWeatherAlert.detect(now: 3, hours: hours, at: now)
        XCTAssertEqual(found?.kind, .rain)
        XCTAssertEqual(found?.date, now.addingTimeInterval(3000))
        XCTAssertNil(NotchWeatherAlert.detect(now: 63, hours: hours, at: now), "already raining")
        XCTAssertNil(NotchWeatherAlert.detect(now: 0, hours: [(date: now.addingTimeInterval(9000), code: 71)], at: now), "too far out")
        XCTAssertEqual(NotchWeatherAlert.kind(96), .storm)
    }

    func testAlertSettingsDefaultsAndBounds() throws {
        let fresh = AgentNotchSettings()
        XCTAssertEqual(fresh.meetingMinutes, 5)
        XCTAssertTrue(fresh.alertAgents && fresh.alertBattery && fresh.alertWeather)
        XCTAssertEqual(fresh.batteryLowPercent, 20)
        let bad = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"meetingMinutes":7,"batteryLowPercent":3,"stripOrder":["agents","bogus"]}"#.utf8))
        XCTAssertEqual(bad.meetingMinutes, 5)
        XCTAssertEqual(bad.batteryLowPercent, 20)
        XCTAssertEqual(bad.stripOrder, [.agents, .meeting, .music])
        var on = AgentNotchSettings()
        on.shelfEnabled = true
        XCTAssertTrue(Set(WidgetStore.shelfKinds(on)).isSuperset(of: ["battery", "weather", "calendar"]))
        on.alertBattery = false; on.alertWeather = false; on.meetingMinutes = 0
        XCTAssertFalse(WidgetStore.shelfKinds(on).contains("battery"))
    }
}
