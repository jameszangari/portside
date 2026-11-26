import AppKit
import ApplicationServices
import os.log

/// ChatGPT chats that are replying, read from the ChatGPT app's windows.
///
/// The app keeps no local record of a reply in progress (its
/// `active_chat_turns` table lists local Codex threads only). While a chat
/// replies, the composer's Send button becomes Stop, so each window is read
/// over Accessibility: its title names the chat, the button says whether it
/// is replying. Only the chat a window shows is seen. Chromium builds its
/// web accessibility tree only when asked, through the `AXManualAccessibility`
/// attribute Electron documents. Scans run off the main thread; `sessions()`
/// returns the last one and starts the next.
final class ChatGPTReplies {
    static let shared = ChatGPTReplies()
    static let bundleID = "com.openai.codex"

    /// Called on the main thread when a scan changes what is replying.
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.james.portside.chatgpt-replies", qos: .utility)
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")
    /// Main thread only.
    private var tracker = Tracker()
    private var scanning = false
    private var host: (pid: pid_t, name: String)?
    /// Why the last call skipped the scan, logged once per change.
    private var skipped: String?
    /// Read on `queue` only.
    private var enabledPID: pid_t = 0
    private var lastScan = ""

    func sessions() -> [AgentSession] {
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Self.bundleID }
        let reason = app == nil ? "app not running" : !AXIsProcessTrusted() ? "no Accessibility" : nil
        if reason != skipped {
            skipped = reason
            logger.info("chatgpt: \(reason ?? "reading windows", privacy: .public)")
        }
        guard let app, reason == nil else {
            host = nil
            tracker.update(replying: [], now: Date())
            return tracker.sessions(hostPID: 0, hostName: "ChatGPT")
        }
        host = (app.processIdentifier, app.localizedName ?? "ChatGPT")
        scan(app.processIdentifier)
        return tracker.sessions(hostPID: app.processIdentifier, hostName: host?.name ?? "ChatGPT")
    }

    private func scan(_ pid: pid_t) {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let replying = self.replyingChats(pid)
            DispatchQueue.main.async {
                self.scanning = false
                guard self.host?.pid == pid else { return }
                let before = self.tracker
                self.tracker.update(replying: replying, now: Date())
                if self.tracker.replying != before.replying {
                    self.logger.info("chatgpt: \(replying.count) replying")
                    self.onChange?()
                }
            }
        }
    }

    // MARK: - Accessibility

    /// Window titles whose composer shows Stop.
    private func replyingChats(_ pid: pid_t) -> Set<String> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if enabledPID != pid {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPID = pid
        }
        var titles = Set<String>()
        let windows = children(app, kAXWindowsAttribute)
        var buttons: [String] = []
        for window in windows {
            let label = composerButton(in: window, depth: 0).flatMap { string($0, kAXDescriptionAttribute) }
            buttons.append(label ?? "none")
            guard label == "Stop" else { continue }
            let title = string(window, kAXTitleAttribute) ?? ""
            titles.insert(title.isEmpty ? "ChatGPT" : title)
        }
        let summary = "\(windows.count) windows, composer \(buttons.joined(separator: ", "))"
        if summary != lastScan {
            lastScan = summary
            logger.info("chatgpt: \(summary, privacy: .public)")
        }
        return titles
    }

    /// The composer's Send/Stop button, marked by its class.
    private func composerButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 60 else { return nil }
        if string(element, kAXRoleAttribute) == kAXButtonRole,
           let classes = value(element, "AXDOMClassList") as? [String],
           classes.contains("size-token-button-composer") {
            return element
        }
        for child in children(element, kAXChildrenAttribute) {
            if let found = composerButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    #if DEBUG
    /// `--check-chatgpt`: two reads a second apart, printed.
    static func probe() -> Int32 {
        print("trusted:", AXIsProcessTrusted())
        for _ in 0..<2 {
            let sessions = shared.sessions()
            print(sessions.isEmpty ? "no chats" : sessions.map { "\($0.project ?? "?"): \($0.state)" }.joined(separator: ", "))
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        return 0
    }
    #endif

    // MARK: - State

    /// Replying chats, and when each one that stopped finished. Internal for tests.
    struct Tracker: Equatable {
        private(set) var replying: [String: Date] = [:]
        private(set) var finished: [String: Date] = [:]

        mutating func update(replying next: Set<String>, now: Date) {
            for title in replying.keys where !next.contains(title) {
                finished[title] = now
            }
            for title in next {
                finished[title] = nil
                if replying[title] == nil { replying[title] = now }
            }
            replying = replying.filter { next.contains($0.key) }
            finished = finished.filter { now.timeIntervalSince($0.value) < 1800 }
        }

        func sessions(hostPID: pid_t, hostName: String) -> [AgentSession] {
            func session(_ title: String, _ state: AgentState, _ updated: Date) -> AgentSession {
                AgentSession(id: "chatgpt:\(title)", provider: AgentProvider.named("chatgpt"), pid: hostPID,
                             state: state, needsAttention: false, ended: false, updated: updated,
                             project: title, host: hostName, focusBundleIDs: [ChatGPTReplies.bundleID])
            }
            return replying.map { session($0.key, .running, $0.value) }
                + finished.map { session($0.key, .done, $0.value) }
        }
    }
}
