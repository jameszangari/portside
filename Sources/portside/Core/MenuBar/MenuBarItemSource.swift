import AppKit
import ApplicationServices

/// One status item another app exposes in its `AXExtrasMenuBar` (P2-MENU-02,
/// following the REA-03 report). Only what Accessibility reports: no
/// position (frames were unreliable), no visibility, no thumbnail.
struct MenuBarItem: Equatable, Identifiable, Sendable {
    /// Cap on every text field read from another app.
    static let textLimit = 120

    let pid: pid_t
    let ownerBundleID: String?
    let ownerName: String
    /// Position among the owner's menu extras, in the order the owner reports.
    let ordinal: Int
    let identifier: String?
    /// May be empty: many items expose no title.
    let title: String
    /// The item reports an `AXPress` action.
    let canPress: Bool

    /// Stable within a session: `<bundle id or pid>:<identifier or #ordinal>`.
    var id: String {
        let owner = ownerBundleID?.lowercased() ?? "pid\(pid)"
        return "\(owner):\(identifier.map { "id=\($0)" } ?? "#\(ordinal)")"
    }

    var displayTitle: String { title.isEmpty ? ownerName : title }
}

/// What a sweep found. `denied` is distinct from an empty `items`.
struct MenuBarSnapshot: Equatable, Sendable {
    enum Access: Equatable, Sendable { case ready, accessibilityDenied }

    var access: Access
    var items: [MenuBarItem]
    /// Apps skipped because they did not answer in time or the sweep ran out of time.
    var skippedApps: Int = 0
    /// Menu extras listed by an owner that cannot be pressed through AX
    /// (Control Center groups). Counted, never listed.
    var unsupportedCount: Int = 0

    static let denied = MenuBarSnapshot(access: .accessibilityDenied, items: [])
}

enum MenuBarPressOutcome: Equatable, Sendable {
    case pressed
    /// The owner quit, or the element no longer matches what was listed.
    case stale
    case unsupported
    case denied
    /// The item is not on screen: hidden by a menu bar manager, clipped by the notch or covered.
    case hidden
    case failed(Int32)
}

/// Reads and presses menu bar items. The live one uses Accessibility; tests
/// inject a fixture. Both calls may block on another app, so callers run them
/// off the main actor.
protocol MenuBarItemSource: Sendable {
    func snapshot() -> MenuBarSnapshot
    func press(_ item: MenuBarItem) -> MenuBarPressOutcome
    /// Whether a click would land on this item now. False when it is hidden,
    /// clipped or covered, or no longer matches what was listed.
    func isReachable(_ item: MenuBarItem) -> Bool
}

/// Accessibility reader. A press is one click at the item, and only when a
/// hit test proves it is the element at that point. `AXPress` is not used:
/// it reports success and does nothing on some items (SwiftUI window-style
/// extras), and on an item a menu bar manager hid it cannot be told apart
/// from a press that worked. No attribute is set and no other app's
/// preference is touched.
struct AXMenuBarItemSource: MenuBarItemSource {
    /// Longest one AX call may wait on an unresponsive app.
    static let axTimeout: Float = 0.5
    /// Longest a whole sweep may take before it returns what it has.
    static let sweepDeadline: TimeInterval = 3

    let isTrusted: @Sendable () -> Bool
    let running: @Sendable () -> [(pid: pid_t, bundleID: String?, name: String)]

    static let live = AXMenuBarItemSource(
        isTrusted: { AXIsProcessTrusted() },
        running: {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, app.processIdentifier != getpid() else { return nil }
                return (app.processIdentifier, app.bundleIdentifier, app.localizedName ?? app.bundleIdentifier ?? "App")
            }
        }
    )

    func snapshot() -> MenuBarSnapshot {
        guard isTrusted() else { return .denied }
        let deadline = Date().addingTimeInterval(Self.sweepDeadline)
        var snapshot = MenuBarSnapshot(access: .ready, items: [])
        for app in running() {
            if Date() >= deadline { snapshot.skippedApps += 1; continue }
            switch Self.extras(pid: app.pid, bundleID: app.bundleID, name: app.name) {
            case .none: break
            case .unresponsive: snapshot.skippedApps += 1
            case .found(let items, let unsupported):
                snapshot.items += items
                snapshot.unsupportedCount += unsupported
            }
        }
        return snapshot
    }

    func press(_ item: MenuBarItem) -> MenuBarPressOutcome {
        guard isTrusted() else { return .denied }
        guard item.canPress else { return .unsupported }
        guard let app = running().first(where: { $0.pid == item.pid }), app.bundleID == item.ownerBundleID else { return .stale }
        // Re-read the owner now and press only an element that still matches.
        guard case .found(let all) = Self.elements(pid: item.pid), all.indices.contains(item.ordinal),
              let current = Self.read(all[item.ordinal], pid: item.pid, bundleID: item.ownerBundleID, name: item.ownerName, ordinal: item.ordinal),
              current == item else { return .stale }
        let element = all[item.ordinal]
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return .failed(AXError.cannotComplete.rawValue) }
        guard let point = Self.hitTestedCenter(of: element) else { return .hidden }
        Self.click(at: point)
        return .pressed
    }

    func isReachable(_ item: MenuBarItem) -> Bool {
        guard isTrusted(), item.canPress, running().contains(where: { $0.pid == item.pid && $0.bundleID == item.ownerBundleID }),
              case .found(let all) = Self.elements(pid: item.pid), all.indices.contains(item.ordinal),
              Self.read(all[item.ordinal], pid: item.pid, bundleID: item.ownerBundleID, name: item.ownerName, ordinal: item.ordinal) == item
        else { return false }
        return Self.hitTestedCenter(of: all[item.ordinal]) != nil
    }

    /// The item's center, only if the element at that point is this item.
    /// Frames alone are not enough: covered and hidden items still report one.
    static func hitTestedCenter(of element: AXUIElement) -> CGPoint? {
        var position = CGPoint.zero, size = CGSize.zero
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(center.x), Float(center.y), &found) == .success,
              let found, CFEqual(found, element) else { return nil }
        return center
    }

    /// One left click, as a person would: the pointer goes there first so the
    /// menu bar registers it, then comes back. Runs off the main actor.
    private static func click(at point: CGPoint) {
        let origin = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved)
        usleep(120_000)
        post(.leftMouseDown)
        usleep(80_000)
        post(.leftMouseUp)
        usleep(60_000)
        if let origin { CGWarpMouseCursorPosition(origin) }
    }

    private enum Extras {
        case none, unresponsive
        case found([MenuBarItem], unsupported: Int)
    }

    enum Elements {
        case none, unresponsive
        case found([AXUIElement])
    }

    /// The owner's menu extra elements: none, unresponsive, or the list.
    static func elements(pid: pid_t) -> Elements {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var bar: CFTypeRef?
        let started = Date()
        switch AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) {
        case .success: break
        // Helpers with no AX tree also answer cannotComplete, at once. Only a
        // call that used up its wait counts as an app that did not answer.
        case .cannotComplete: return Date().timeIntervalSince(started) >= Double(axTimeout) * 0.9 ? .unresponsive : .none
        default: return .none
        }
        guard let bar else { return .none }
        var children: CFTypeRef?
        switch AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) {
        case .success: return (children as? [AXUIElement]).map { $0.isEmpty ? .none : .found($0) } ?? .none
        case .cannotComplete: return .unresponsive
        default: return .none
        }
    }

    private static func extras(pid: pid_t, bundleID: String?, name: String) -> Extras {
        switch elements(pid: pid) {
        case .none: return .none
        case .unresponsive: return .unresponsive
        case .found(let elements):
            var items: [MenuBarItem] = []
            var unsupported = 0
            for (ordinal, element) in elements.enumerated() {
                if let item = read(element, pid: pid, bundleID: bundleID, name: name, ordinal: ordinal) { items.append(item) } else { unsupported += 1 }
            }
            return .found(items, unsupported: unsupported)
        }
    }

    static func read(_ element: AXUIElement, pid: pid_t, bundleID: String?, name: String, ordinal: Int) -> MenuBarItem? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        guard string(element, kAXSubroleAttribute) == "AXMenuExtra" else { return nil }
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        let actions = names as? [String] ?? []
        let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
        return MenuBarItem(
            pid: pid, ownerBundleID: bundleID, ownerName: String(name.prefix(MenuBarItem.textLimit)), ordinal: ordinal,
            identifier: string(element, kAXIdentifierAttribute).flatMap { $0.isEmpty ? nil : $0 },
            title: title, canPress: actions.contains(kAXPressAction)
        )
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String else { return nil }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MenuBarItem.textLimit))
    }
}
