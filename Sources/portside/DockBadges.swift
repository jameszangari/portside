import AppKit
import os.log
import SwiftUI

/// Notification badges, the same ones the native Dock draws.
///
/// Read from LaunchServices (`LaunchServicesBadges`, private API, guarded):
/// every running app's "StatusLabel". No Accessibility permission needed,
/// and badges survive the Dock restart that the hide trick causes.
///
/// LaunchServices does not notify anyone else when a badge changes, so this
/// reads on a 1s timer, but only while the dock is on screen (same class of
/// timer as widget refresh, never in the reveal/hide path). Revealing kicks
/// one read right away; it runs off the main thread and lands during the
/// slide. App launch and quit also trigger a read. Nothing runs while the
/// dock is hidden.
final class DockBadges: ObservableObject {
    /// Badge text by standardized .app path.
    @Published private(set) var byPath: [String: String] = [:]
    /// Same labels keyed by bundle id.
    @Published private(set) var byBundleID: [String: String] = [:]
    /// False if the private LaunchServices symbols are gone (OS update).
    let isAvailable = LaunchServicesBadges.isAvailable

    private let logger = Logger(subsystem: "com.james.portside", category: "DockBadges")
    private let queue = DispatchQueue(label: "com.james.portside.badges", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var enabled = true
    private var visible = false
    private var reading = false
    private var readAgain = false
    /// How often to re-read while the dock is on screen.
    private let interval: TimeInterval = 1.0

    deinit { stop() }

    func start(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled, isAvailable else {
            stop()
            clear()
            return
        }
        installWorkspaceObservers()
        read(reason: "start")
        updateTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    /// Live toggle from Settings.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on {
            start(enabled: true)
        } else {
            enabled = false
            stop()
            clear()
            logger.info("badges off")
        }
    }

    /// The dock started revealing (true) or finished hiding (false).
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        if on { read(reason: "reveal") }
        updateTimer()
    }

    private func updateTimer() {
        let wanted = enabled && isAvailable && visible
        if !wanted {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.read(reason: nil) }
        t.resume()
        timer = t
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.read(reason: "apps changed")
            })
        }
    }

    /// Badge text for a pinned or running app, or nil if none.
    func badge(for app: PinnedApp) -> String? {
        guard enabled else { return nil }
        if let id = app.bundleIdentifier, let label = byBundleID[id] { return label }
        return byPath[Self.standardPath(app.path)]
    }

    /// Combined badge for a group tile: sum of numeric member badges, or a
    /// dot if members only have non-numeric labels.
    func badge(forGroup group: FolderGroup) -> String? {
        guard enabled else { return nil }
        var sum = 0
        var anyDot = false
        for app in group.apps {
            guard let label = badge(for: app) else { continue }
            if let n = Self.numericPrefix(label) {
                sum += n
            } else {
                anyDot = true
            }
        }
        if sum > 0 { return sum > 99 ? "99+" : "\(sum)" }
        return anyDot ? "•" : nil
    }

    // MARK: - Read

    private struct RunningApp {
        let pid: pid_t
        let bundleID: String?
        let path: String?
    }

    /// One read of every regular app's badge, off the main thread. Calls
    /// that arrive mid-read fold into one more read after it.
    private func read(reason: String?) {
        guard enabled, isAvailable else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        queue.async { [weak self] in
            let started = CACurrentMediaTime()
            // Same set of apps the native Dock shows. Listed here, not on
            // the main thread: reading activationPolicy for every app costs
            // milliseconds. NSRunningApplication is thread safe.
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, path: $0.bundleURL?.path) }
            var byPath: [String: String] = [:]
            var byBundleID: [String: String] = [:]
            for app in apps {
                guard let label = LaunchServicesBadges.label(forPID: app.pid) else { continue }
                if let path = app.path { byPath[Self.standardPath(path)] = label }
                if let id = app.bundleID { byBundleID[id] = label }
            }
            let ms = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if let reason {
                    self.logger.debug("read (\(reason, privacy: .public)): \(apps.count) apps in \(ms, format: .fixed(precision: 2))ms")
                }
                if self.enabled { self.apply(byPath: byPath, byBundleID: byBundleID) }
                if self.readAgain {
                    self.readAgain = false
                    self.read(reason: "again")
                }
            }
        }
    }

    private func apply(byPath nextPath: [String: String], byBundleID nextBundle: [String: String]) {
        guard nextPath != byPath || nextBundle != byBundleID else { return }
        byPath = nextPath
        byBundleID = nextBundle
        if nextPath.isEmpty {
            logger.info("badges cleared")
        } else {
            let sample = nextPath.keys.sorted().prefix(6).map {
                "\(($0 as NSString).lastPathComponent)=\(nextPath[$0] ?? "")"
            }.joined(separator: ", ")
            logger.info("badges: \(nextPath.count) app(s) (\(sample, privacy: .public))")
        }
    }

    private func clear() {
        if !byPath.isEmpty || !byBundleID.isEmpty {
            byPath = [:]
            byBundleID = [:]
        }
    }

    static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Leading digits of a badge ("12", "99+"), or nil for dots / letters.
    static func numericPrefix(_ label: String) -> Int? {
        let digits = label.prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }
}

// MARK: - Badge color

/// Badge fill, Settings > Appearance > Badges.
enum BadgeColor: String, Codable, CaseIterable, Identifiable {
    case macOS, accent, orange, yellow, green, blue, purple, pink, graphite, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: "macOS Red"
        case .accent: "Accent Color"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .graphite: "Graphite"
        case .custom: "Custom"
        }
    }

    /// The native Dock's badge red (about sRGB #EB372D). Calibrated on
    /// screen: the real Dock's badge and this color give the same pixels
    /// in a screenshot. Not `systemRed`, which is pinker.
    static let nativeRed = NSColor(displayP3Red: 0.850, green: 0.281, blue: 0.223, alpha: 1)

    /// Starting color when Custom is picked.
    static let defaultCustom: RGBAColor = {
        let c = nativeRed.usingColorSpace(.sRGB) ?? .systemRed
        return RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
    }()

    func fill(custom: RGBAColor) -> NSColor {
        switch self {
        case .macOS: Self.nativeRed
        case .accent: .controlAccentColor
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .graphite: .systemGray
        case .custom: NSColor(srgbRed: custom.red, green: custom.green, blue: custom.blue, alpha: custom.alpha)
        }
    }
}

/// What a badge chip is painted with. Text is white like the native badge,
/// or black on a light fill (yellow, light custom colors) so it stays legible.
struct BadgeStyle: Equatable {
    var fill: NSColor

    static let native = BadgeStyle(fill: BadgeColor.nativeRed)

    var text: Color {
        guard let c = fill.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.65 ? .black : .white
    }
}

// MARK: - Badge chip

/// Native Dock-style notification badge, measured against the real Dock
/// on macOS 27: a circle (a capsule for longer text) 0.38 of the tile tall,
/// regular-weight white digits, no ring and no shadow, its top-trailing
/// corner flush with the icon frame's corner (the icon art has its own
/// margin, so the badge overlaps the icon's corner). Sized from the tile,
/// so it grows with the icon under magnification.
struct DockBadgeLabel: View {
    let text: String
    let iconSize: CGFloat
    var style: BadgeStyle = .native

    static func height(for iconSize: CGFloat) -> CGFloat {
        max(12, (iconSize * 0.38).rounded())
    }

    var body: some View {
        let height = Self.height(for: iconSize)
        let fontSize = height * 0.54
        Text(text)
            .font(.system(size: fontSize, weight: .regular))
            // Native digits sit slightly tighter than default tracking.
            .tracking(-fontSize * 0.04)
            .foregroundStyle(style.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, height * 0.15)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Capsule(style: .continuous).fill(Color(nsColor: style.fill)))
            .allowsHitTesting(false)
    }
}

extension View {
    /// Overlays the badge on the icon's top-trailing corner. Never changes
    /// the tile's layout and never leaves the icon frame, so the hosting
    /// view can't clip it.
    @ViewBuilder
    func dockBadge(_ text: String?, iconSize: CGFloat, style: BadgeStyle) -> some View {
        if let text, !text.isEmpty {
            overlay(alignment: .topTrailing) {
                DockBadgeLabel(text: text, iconSize: iconSize, style: style)
            }
        } else {
            self
        }
    }
}
