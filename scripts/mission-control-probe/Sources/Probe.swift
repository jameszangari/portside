import AppKit

enum ProbeLog {
    static let start = ProcessInfo.processInfo.systemUptime
    static func write(_ message: String) {
        let origin = start
        print(String(format: "%7.3f ", ProcessInfo.processInfo.systemUptime - origin) + message)
    }
}

private final class ProbePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Only cover panels accept mouse events. Logs bundle IDs, never titles.
    override func mouseDown(with event: NSEvent) { logClick("left") }
    override func rightMouseDown(with event: NSEvent) { logClick("right") }

    // Hover growth, driven by one tracking area; no polling.
    var base = CGRect.zero
    var edge = DockCover.Edge.bottom
    var clearance: CGFloat = 0
    var alwaysGrown = false
    private var hovering = false
    override func mouseEntered(with event: NSEvent) { hovering = true; applyFrame(); ProbeLog.write("HOVER enter grown=\(frame)") }
    override func mouseExited(with event: NSEvent) { hovering = false; applyFrame(); ProbeLog.write("HOVER exit") }
    func installTracking() {
        guard let view = contentView else { return }
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }
    func applyFrame() {
        let screen = screen?.frame ?? base
        let target = (hovering || alwaysGrown) && clearance > 0 ? DockCover.hovered(base, edge: edge, clearance: clearance, screen: screen) : base
        setFrame(target, display: true)
        if let label = contentView?.subviews.first {
            label.setFrameOrigin(NSPoint(x: base.minX - target.minX + (base.width - label.frame.width) / 2,
                                         y: (base.height - label.frame.height) / 2))
        }
    }
    private func logClick(_ button: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        ProbeLog.write("CLICK \(button) at=\(NSEvent.mouseLocation) probeActive=\(NSApp.isActive) frontmost=\(front)")
    }
}

private final class Probe: NSObject, NSApplicationDelegate {
    let duration: Double
    let eventsOnly: Bool
    let detect: Bool
    let cover: Bool
    let margin: CGFloat
    let coverLevel: Int
    let exitDelay: Double
    let labelClearance: CGFloat
    let alwaysGrown: Bool
    private let notifications = DockNotifications()
    private var panels: [NSPanel] = []
    private var statusItem: NSStatusItem?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var screenToken: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var eventCount = 0
    private var showing = false
    private var activation = 0

    init(duration: Double, eventsOnly: Bool, detect: Bool, cover: Bool, margin: CGFloat,
         coverLevel: Int, exitDelay: Double, labelClearance: CGFloat, alwaysGrown: Bool) {
        self.duration = duration
        self.eventsOnly = eventsOnly
        self.detect = detect || cover
        self.cover = cover
        self.margin = margin
        self.coverLevel = coverLevel
        self.exitDelay = exitDelay
        self.labelClearance = labelClearance
        self.alwaysGrown = alwaysGrown
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProbeLog.write("\(ProcessInfo.processInfo.operatingSystemVersionString); pid=\(getpid())")
        ProbeLog.write("mode=\(cover ? "cover" : detect ? "detect" : eventsOnly ? "events-only" : "always-visible"); exits after \(duration)s; no Dock preference writes")
        buildPanels()
        showing = !eventsOnly && !detect
        updateVisibility()
        installMenu()
        notifications.received = { [weak self] name in
            guard let self else { return }
            self.eventCount += 1
            ProbeLog.write("RECEIVED \(name)")
            if self.eventsOnly {
                self.showing = name != "AXExposeExit" && name != "AXExposeShowDesktop"
                self.updateVisibility()
            }
            self.snapshot()
        }
        notifications.start()
        DockNotifications.checkWindowManagerAccessibility()
        if detect {
            WindowServerNotifications.shared.changed = { [weak self] active in
                guard let self else { return }
                self.showing = active
                self.updateVisibility()
            }
            WindowServerNotifications.shared.start(anchors: panelIDs)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            ProbeLog.write("Dock relaunched; subscribing again")
            self?.notifications.start()
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            self?.notifications.stop()
            if self?.eventsOnly == true { self?.showing = false; self?.updateVisibility() }
        })
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.buildPanels()
            self?.updateVisibility()
            if let self, self.detect {
                WindowServerNotifications.shared.displaysChanged(anchors: self.panelIDs)
            }
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        snapshot()
        ProbeLog.write("Open Mission Control or App Expose now. One window-order sample in 10s; MC Probe menu can schedule more.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.snapshot() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { NSApp.terminate(nil) }
    }

    private var panelIDs: [UInt32] {
        panels.compactMap { $0.windowNumber > 0 ? UInt32($0.windowNumber) : nil }
    }

    private func buildPanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
        if cover { buildCoverPanels(); return }
        let cases: [(String, NSWindow.Level, NSColor)] = [
            ("STATUS", .statusBar, .systemBlue),
            ("POPUP", .popUpMenu, .systemOrange),
            ("SCREEN SAVER", .screenSaver, .systemPurple)
        ]
        for (index, screen) in NSScreen.screens.enumerated() {
            let width = min(960, screen.frame.width - 40)
            ProbeLog.write("display \(index + 1) frame=\(screen.frame)")
            for (column, item) in cases.enumerated() {
                let frame = NSRect(x: screen.frame.midX - width / 2 + CGFloat(column) * width / 3,
                                   y: screen.frame.minY, width: width / 3, height: 120)
                let panel = ProbePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.level = item.1
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.isOpaque = true
                panel.hasShadow = false
                panel.backgroundColor = item.2
                let label = NSTextField(wrappingLabelWithString:
                    "\(item.0) · level \(item.1.rawValue)\nDisplay \(index + 1) · click-through probe\nCan you see this over the native Dock?")
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 14)
                label.alignment = .center
                label.frame = NSRect(x: 8, y: 24, width: frame.width - 16, height: 72)
                panel.contentView?.addSubview(label)
                panels.append(panel)
            }
        }
    }

    /// One clickable, non-activating panel per display, laid out on each entry.
    private func buildCoverPanels() {
        for (index, screen) in NSScreen.screens.enumerated() {
            ProbeLog.write("display \(index + 1) frame=\(screen.frame) visible=\(screen.visibleFrame)")
            let panel = ProbePanel(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 100, height: 100),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: coverLevel)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.isOpaque = true
            panel.hasShadow = false
            panel.backgroundColor = .systemTeal
            let label = NSTextField(labelWithString: "COVER · display \(index + 1) · click me")
            label.textColor = .white
            label.font = .boldSystemFont(ofSize: 13)
            label.sizeToFit()
            panel.contentView?.addSubview(label)
            panel.clearance = labelClearance
            panel.alwaysGrown = alwaysGrown
            panel.installTracking()
            panels.append(panel)
        }
    }

    /// Reads Dock geometry once on entry and once 0.4 s later, after the
    /// Dock's slide-in. Bounded per activation; never a repeating timer.
    private func layoutCover(pass: Int) {
        let docks = DockGeometry.frames()
        ProbeLog.write("COVER pass=\(pass) source=\(docks.isEmpty ? "fallback (no AX Dock list)" : "AX") docks=\(docks)")
        for case let (panel as ProbePanel, screen) in zip(panels, NSScreen.screens) {
            var frame: CGRect?
            var edge = DockCover.Edge.bottom
            var source = "fallback"
            if docks.isEmpty {
                let strip = DockCover.fallback(screen: screen.frame, visible: screen.visibleFrame, height: 100)
                frame = strip
                if strip.height > strip.width { edge = strip.minX <= screen.frame.minX ? .left : .right }
            } else if let hit = docks.lazy.compactMap({ DockCover.rect(dock: $0, screen: screen.frame, margin: self.margin) }).first {
                frame = hit.0
                edge = hit.1
                source = "AX"
            }
            guard let frame else { panel.orderOut(nil); continue }
            panel.base = frame
            panel.edge = edge
            panel.applyFrame()
            panel.orderFrontRegardless()
            ProbeLog.write("COVER display=\(screen.frame) source=\(source) edge=\(edge.rawValue) frame=\(frame) margin=\(margin) level=\(coverLevel) labelClearance=\(labelClearance) grow=\(alwaysGrown ? "always" : "hover")")
        }
    }

    private func updateVisibility() {
        if cover && showing {
            activation += 1
            let current = activation
            layoutCover(pass: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.showing, self.activation == current else { return }
                self.layoutCover(pass: 2)
            }
            ProbeLog.write("cover panels laid out; visual coverage and click routing still require a person")
            return
        }
        if cover {
            // The Dock is still sliding out when the exit event arrives. One
            // bounded hide delay per exit, canceled by a new entry.
            activation += 1
            let current = activation
            DispatchQueue.main.asyncAfter(deadline: .now() + exitDelay) { [weak self] in
                guard let self, !self.showing, self.activation == current else { return }
                self.panels.forEach { $0.orderOut(nil) }
                ProbeLog.write("cover panels hidden \(self.exitDelay)s after exit")
            }
            return
        }
        for panel in panels {
            if showing { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        ProbeLog.write("panels \(showing ? "ordered front" : "hidden"); visual occlusion still requires a person")
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MC Probe"
        let menu = NSMenu()
        for (title, action) in [
            ("Toggle test panels", #selector(toggle)),
            ("Log window order in 3 seconds", #selector(delayedSnapshot)),
            ("Retry Accessibility subscriptions", #selector(retry)),
            ("Quit probe", #selector(quit))
        ] {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggle() { showing.toggle(); updateVisibility() }
    @objc private func retry() { notifications.start() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func delayedSnapshot() {
        ProbeLog.write("Window-order sample in 3s; enter Mission Control or App Expose")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.snapshot() }
    }

    private func snapshot() {
        ProbeLog.write("WINDOW ORDER front to back (metadata only, not proof of visual coverage)")
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            ProbeLog.write("Window list unavailable")
            return
        }
        for (rank, window) in windows.enumerated() {
            let owner = window[kCGWindowOwnerName as String] as? String ?? "unknown"
            let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard pid == getpid() || owner == "Dock" || owner == "WindowManager" else { continue }
            let layer = window[kCGWindowLayer as String] ?? "?"
            let bounds = window[kCGWindowBounds as String] ?? "?"
            ProbeLog.write("rank=\(rank) owner=\(pid == getpid() ? "probe" : owner) layer=\(layer) bounds=\(bounds)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if detect { WindowServerNotifications.shared.stop() }
        notifications.stop()
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        panels.forEach { $0.close() }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        ProbeLog.write("Stopped; received \(eventCount) Dock AX events. Zero events alone is inconclusive; compare with gestures you tried.")
    }
}

@main
private enum Main {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var duration = 180.0
        var eventsOnly = false
        var detect = false
        var cover = false
        var margin: CGFloat = 12
        var level = 25
        var exitDelay = 0.35
        var labelClearance: CGFloat = 40
        var alwaysGrown = false
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--events-only": eventsOnly = true
            case "--detect": detect = true
            case "--cover": cover = true
            case "--margin":
                guard let value = args.next(), let points = Double(value), (0...64).contains(points) else { usage(error: true) }
                margin = points
            case "--level":
                guard let value = args.next(), let raw = Int(value), (20...2000).contains(raw) else { usage(error: true) }
                level = raw
            case "--exit-delay":
                guard let value = args.next(), let seconds = Double(value), (0...2).contains(seconds) else { usage(error: true) }
                exitDelay = seconds
            case "--label-clearance":
                guard let value = args.next(), let points = Double(value), (0...120).contains(points) else { usage(error: true) }
                labelClearance = points
            case "--grow":
                guard let value = args.next(), ["always", "hover"].contains(value) else { usage(error: true) }
                alwaysGrown = value == "always"
            case "--duration":
                guard let value = args.next(), let seconds = Double(value), seconds.isFinite,
                      (1...600).contains(seconds) else { usage(error: true) }
                duration = seconds
            case "--help", "-h": usage(error: false)
            default: usage(error: true)
            }
        }
        guard !((detect || cover) && eventsOnly) else { usage(error: true) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = Probe(duration: duration, eventsOnly: eventsOnly, detect: detect, cover: cover, margin: margin,
                          coverLevel: level, exitDelay: exitDelay,
                          labelClearance: labelClearance, alwaysGrown: alwaysGrown)
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }

    private static func usage(error: Bool) -> Never {
        print("Usage: MissionControlProbe [--duration 1...600] [--events-only | --detect | --cover [--margin 0...64] [--level 20...2000] [--exit-delay 0...2] [--label-clearance 0...120] [--grow hover|always]]")
        print("Default: 180s, always-visible panels; AX notifications logged independently.")
        print("--detect: experimental WindowServer events show panels only while an Expose overlay is detected.")
        print("--cover: like --detect, but one clickable panel covers each display's native Dock bounds (AX), default margin 12, level 25, exit delay 0.35s, label clearance 40 while hovered (--grow always: for the whole mode).")
        exit(error ? 2 : 0)
    }
}
