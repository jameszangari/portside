import AppKit
import SwiftUI

/// What the Top Notch pane's preview shows (SHELF-12): the strip, or the
/// part of the notch the open settings section changes.
enum NotchPreviewScene: Equatable {
    case strip
    /// The strip with a volume change.
    case volume
    case card(NotchShelfActivity)
    case page(NotchShelfPage)
}

/// The Top Notch pane's live preview: the real `AgentNotchView` with sample
/// sessions, a sample song, a sample alert and sample files, so it always
/// looks like the notch itself. It never reads or changes the shelf's own
/// files or clipboard, and takes no clicks.
struct NotchSettingsPreview: View {
    let preferences: AgentNotchSettings
    let scene: NotchPreviewScene
    @StateObject private var sample = NotchPreviewSample()

    /// The widest the preview draws before it scales down.
    static let maxWidth: CGFloat = 480

    var body: some View {
        let size = sample.size
        let scale = min(1, Self.maxWidth / max(1, size.width))
        AgentNotchView(agents: sample.agents, usage: nil, nowPlaying: sample.music, state: sample.state, fileShelf: sample.files)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .scaleEffect(scale, anchor: .top)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .top)
            .frame(maxWidth: .infinity)
            .padding(.top, 0).padding(.bottom, 14)
            .background(alignment: .top) {
                // The menu bar the notch hangs from.
                Rectangle().fill(.quaternary).frame(height: sample.state.headerHeight * scale)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(preferences.animate ? .easeOut(duration: 0.2) : nil, value: size)
            .onAppear { sample.show(preferences, scene) }
            .onChange(of: preferences) { sample.show(preferences, scene) }
            .onChange(of: scene) { sample.show(preferences, scene) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the Top Notch")
    }
}

/// Sample data and the presentation state the preview draws.
final class NotchPreviewSample: ObservableObject {
    let state = AgentNotchPresentation()
    let agents = AgentStatusWidget()
    let music = NowPlayingWidget()
    let files = NotchFileShelf(url: nil)
    @Published private(set) var size = CGSize(width: 400, height: 32)
    private let hosts: [WidgetHost]

    static let notchWidth: CGFloat = 180

    init() {
        let now = Date()
        agents.preview([
            AgentSession(id: "sample-claude", provider: .named("claude"), pid: 0, state: .running, needsAttention: false, ended: false,
                         updated: now, project: "portside", host: "Terminal"),
            AgentSession(id: "sample-codex", provider: .named("codex"), pid: 0, state: .running, needsAttention: true, ended: false,
                         updated: now.addingTimeInterval(-40), project: "website", host: "T3 Code"),
        ])
        let art = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
            NSGradient(starting: .systemPink, ending: .systemIndigo)?.draw(in: rect, angle: 45)
            return true
        }
        music.preview(NowPlayingWidget.Track(
            id: "sample", title: "Song title", artist: "Artist", artwork: art, artworkURL: nil, isPlaying: true,
            player: NowPlayingWidget.Player(bundleID: "com.apple.Music", name: "Music", notification: ""),
            duration: 214, elapsed: 64, elapsedAt: now))
        // Files every Mac has, so the icons are real. In memory only.
        files.preview(["/System/Applications/TextEdit.app", "/System/Library/CoreServices/Finder.app", "/etc/hosts"]
            .map { URL(fileURLWithPath: $0) })
        // Not started: no network or calendar queries, only each card's empty state.
        hosts = [WeatherWidget.kind, CalendarWidget.kind].compactMap { WidgetCatalog.make($0).map(WidgetHost.init(widget:)) }
        let hosts = hosts
        state.widgetHost = { kind in hosts.first { $0.id == kind } }
        state.pageAvailable = { _ in true }
        state.airPods = [AirPodsReading(address: "sample", name: "AirPods Pro", productID: 0x2014, left: 80, right: 75, case: 60)]
        state.followsPointer = false
        state.topAttached = true
        state.headerHeight = 32
        state.notchWidth = Self.notchWidth
    }

    func show(_ preferences: AgentNotchSettings, _ scene: NotchPreviewScene) {
        var preferences = preferences
        // Cards show at once; the preview takes no pointer.
        preferences.shelfHoverDelay = 0
        state.preferences = preferences
        let flare = 2 * NotchShape.flare
        state.compactWidth = preferences.compactWidth + Self.notchWidth + flare
        state.hud = scene == .volume ? NotchHUD(kind: .volume, level: 0.6) : nil
        if state.hud != nil { state.compactWidth = max(state.compactWidth, NotchHUD.stripWidth(notch: Self.notchWidth, flare: flare)) }
        let active = preferences.stripOrder.filter { $0 == .agents || $0 == .music && preferences.showMedia }
        var alert: NotchShelfAlert?
        if case .card(let activity) = scene, activity == .airPods || activity == .battery {
            alert = activity == .airPods
                ? NotchShelfAlert(activity: .airPods, symbol: "airpodspro", short: "15%", title: "AirPods Pro low",
                                  detail: "Left 15%, Right 70%, Case 60%", isWarning: true,
                                  parts: [NotchLevelPart(label: "Left", percent: 15), NotchLevelPart(label: "Right", percent: 70),
                                          NotchLevelPart(label: "Case", percent: 60)])
                : NotchShelfAlert(activity: .battery, symbol: "battery.25percent", short: "18%", title: "Low battery",
                                  detail: "18% left. Plug in soon.", isWarning: true)
        }
        state.alert = alert
        state.strip = NotchShelfStrip.layout(active: active, alert: alert?.activity)
        if state.strip.isSplit { state.compactWidth = max(state.compactWidth, NotchShelfStrip.splitWidth(notch: Self.notchWidth, flare: flare)) }
        state.setExpanded(false)
        let header = state.headerHeight
        let sessions = preferences.sessions(from: agents.sessions)
        switch scene {
        case .strip, .volume:
            size = CGSize(width: state.compactWidth, height: header)
        case .card(let activity):
            let side: NotchShelfSide? = state.strip.leading == activity ? .leading : state.strip.trailing == activity ? .trailing : nil
            guard let side else {
                size = CGSize(width: state.compactWidth, height: header)
                break
            }
            let width = max(preferences.expandedWidth, state.compactWidth)
            state.panelWidth = width
            state.shelfPointer(.side(side), force: true)
            size = CGSize(width: width, height: header + AgentNotchView.cardHeight(activity, preferences: preferences, sessionCount: sessions.count))
        case .page(let page):
            state.setExpanded(true)
            state.showPage(page)
            let width = AgentNotch.shelfOpenWidth
            state.panelWidth = width
            let height = AgentNotchView.shelfHeight(page: state.currentPage, preferences: preferences, sessionCount: sessions.count,
                                                    chips: AgentNotchView.providerChips(sessions).count > 1,
                                                    files: files.items.count, airPods: state.airPods.count)
            size = CGSize(width: width, height: header + height)
        }
    }
}
