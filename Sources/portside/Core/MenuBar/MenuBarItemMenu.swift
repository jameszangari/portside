import AppKit
import ApplicationServices

/// An Accessibility element that crosses threads. AX calls are thread safe.
struct MenuBarAXHandle: @unchecked Sendable {
    let element: AXUIElement
}

/// One row of another app's status item menu. Read while that menu is closed,
/// so the Portside Bar can show it as its own native menu.
struct MenuBarMirrorRow: Sendable {
    enum Mark: Sendable { case none, on, mixed }

    var title = ""
    var enabled = false
    var mark = Mark.none
    var key = ""
    /// `AXMenuItemCmdModifiers`: 1 Shift, 2 Option, 4 Control, 8 no Command.
    var axModifiers = 0
    var children: [MenuBarMirrorRow] = []
    var isSeparator = false
    var handle: MenuBarAXHandle?

    static let separator = MenuBarMirrorRow(isSeparator: true)

    var keyModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = axModifiers & 8 == 0 ? [.command] : []
        if axModifiers & 1 != 0 { flags.insert(.shift) }
        if axModifiers & 2 != 0 { flags.insert(.option) }
        if axModifiers & 4 != 0 { flags.insert(.control) }
        return flags
    }
}

/// Pure clean-up of what a menu reports.
enum MenuBarMirrorPlan {
    /// No leading, trailing or doubled separators, and no empty menu of them.
    static func tidy(_ rows: [MenuBarMirrorRow]) -> [MenuBarMirrorRow] {
        var result: [MenuBarMirrorRow] = []
        for row in rows {
            if row.isSeparator, result.last?.isSeparator ?? true { continue }
            result.append(row)
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }

    /// Menu titles are one line; some apps report an account on a second.
    static func title(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// Reads a status item's menu through public Accessibility, without opening
/// it. Empty means the app shows a window or popover instead.
enum MenuBarMenuReader {
    private static let depthLimit = 6
    private static let rowLimit = 400

    nonisolated static func rows(of item: MenuBarItem) -> [MenuBarMirrorRow] {
        guard AXIsProcessTrusted(), case .found(let elements) = AXMenuBarItemSource.elements(pid: item.pid), elements.indices.contains(item.ordinal),
              let menu = children(elements[item.ordinal]).first(where: { role($0) == "AXMenu" }) else { return [] }
        var budget = rowLimit
        return MenuBarMirrorPlan.tidy(read(menu, depth: 0, budget: &budget))
    }

    private nonisolated static func read(_ menu: AXUIElement, depth: Int, budget: inout Int) -> [MenuBarMirrorRow] {
        var rows: [MenuBarMirrorRow] = []
        for element in children(menu) where role(element) == "AXMenuItem" && budget > 0 {
            budget -= 1
            let inside = children(element)
            let submenu = depth < depthLimit ? inside.first { role($0) == "AXMenu" } : nil
            let button = inside.first { role($0) == "AXButton" && !label($0).isEmpty }
            let target = (MenuBarMirrorPlan.title(label(element)).isEmpty ? button : nil) ?? element
            let title = MenuBarMirrorPlan.title(label(target))
            guard !title.isEmpty else {
                rows.append(.separator)
                continue
            }
            var row = MenuBarMirrorRow(title: title)
            row.enabled = (attribute(element, kAXEnabledAttribute) as? Bool ?? true) && (submenu != nil || canPress(target))
            switch attribute(element, "AXMenuItemMarkChar") as? String {
            case "✓", "✔": row.mark = .on
            case "-", "–", "•": row.mark = .mixed
            default: break
            }
            row.key = (attribute(element, "AXMenuItemCmdChar") as? String ?? "").lowercased()
            row.axModifiers = attribute(element, "AXMenuItemCmdModifiers") as? Int ?? 0
            row.handle = MenuBarAXHandle(element: target)
            if let submenu { row.children = MenuBarMirrorPlan.tidy(read(submenu, depth: depth + 1, budget: &budget)) }
            rows.append(row)
        }
        return rows
    }

    /// Runs the row while its menu stays closed, off the main thread because
    /// the owner may be slow to answer.
    nonisolated static func press(_ handle: MenuBarAXHandle) {
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementSetMessagingTimeout(handle.element, 0.5)
            AXUIElementPerformAction(handle.element, kAXPressAction as CFString)
        }
    }

    private nonisolated static func label(_ element: AXUIElement) -> String {
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        return title.isEmpty ? attribute(element, kAXDescriptionAttribute) as? String ?? "" : title
    }

    private nonisolated static func canPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String])?.contains(kAXPressAction) ?? false
    }

    private nonisolated static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// Runs a closure from an `NSMenuItem`.
final class MenuBarMenuClosure: NSObject {
    static let shared = MenuBarMenuClosure()
    @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}

/// Builds the native menu shown from a Portside Bar icon.
@MainActor
enum MenuBarMirrorMenu {
    static func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuBarMenuClosure.run(_:)), keyEquivalent: "")
        item.target = MenuBarMenuClosure.shared
        item.representedObject = action
        item.isEnabled = enabled
        return item
    }

    static func make(_ rows: [MenuBarMirrorRow]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in rows {
            if row.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let handle = row.handle
            let item = self.item(row.title, enabled: row.enabled) { if let handle { MenuBarMenuReader.press(handle) } }
            item.keyEquivalent = row.key
            item.keyEquivalentModifierMask = row.keyModifiers
            switch row.mark {
            case .none: break
            case .on: item.state = .on
            case .mixed: item.state = .mixed
            }
            if !row.children.isEmpty {
                item.action = nil
                item.target = nil
                item.submenu = make(row.children)
            }
            menu.addItem(item)
        }
        return menu
    }
}

/// Where a window opened from the bar goes. Top-left coordinates. Pure.
struct MenuBarWindowPlacement: Sendable {
    var iconMidX: CGFloat
    var top: CGFloat
    var minX: CGFloat
    var maxX: CGFloat

    /// Anything wider is the app's main window rather than a popover.
    static let widestPlaced: CGFloat = 600

    func origin(for size: CGSize) -> CGPoint? {
        guard size.width <= Self.widestPlaced else { return nil }
        let margin: CGFloat = 8
        return CGPoint(x: max(minX + margin, min(iconMidX - size.width / 2, maxX - size.width - margin)), y: top)
    }
}

/// Opens a status item that shows a window instead of a menu. The item stays
/// hidden and the pointer stays put; the window is moved under its icon.
enum MenuBarWindowOpener {
    enum Outcome: Equatable, Sendable {
        case opened
        /// The app ignored the press, as window-style SwiftUI items do.
        case noEffect
        /// The press left the item selected in MenuBarAgent.
        case stuck
        case unavailable
    }

    nonisolated static func open(_ item: MenuBarItem, placement: MenuBarWindowPlacement) -> Outcome {
        guard AXIsProcessTrusted(), case .found(let elements) = AXMenuBarItemSource.elements(pid: item.pid), elements.indices.contains(item.ordinal) else { return .unavailable }
        let handle = MenuBarAXHandle(element: elements[item.ordinal])
        AXUIElementSetMessagingTimeout(handle.element, 0.25)
        let before = windows(pid: item.pid)
        // A popover can hold this call open until it closes.
        DispatchQueue.global(qos: .userInitiated).async { AXUIElementPerformAction(handle.element, kAXPressAction as CFString) }
        let deadline = Date().addingTimeInterval(0.8)
        var opened: [CGWindowID: CGRect] = [:]
        while opened.isEmpty, Date() < deadline {
            usleep(8000)
            opened = windows(pid: item.pid).filter { before[$0.key] == nil }
        }
        if isSelected(handle.element) { return .stuck }
        guard let window = opened.values.first else {
            return Set(windows(pid: item.pid).keys) == Set(before.keys) ? .noEffect : .opened
        }
        if let origin = placement.origin(for: window.size) { move(pid: item.pid, like: window.size, to: origin) }
        return .opened
    }

    private nonisolated static func isSelected(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelected" as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }

    private nonisolated static func windows(pid: pid_t) -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for window in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] where (window[kCGWindowOwnerPID as String] as? pid_t) == pid {
            if let id = window[kCGWindowNumber as String] as? CGWindowID,
               let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) {
                result[id] = bounds
            }
        }
        return result
    }

    /// The window can still be animating to full size, so the closest match wins.
    private nonisolated static func move(pid: pid_t, like size: CGSize, to origin: CGPoint) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let all = value as? [AXUIElement] else { return }
        func distance(_ window: AXUIElement) -> CGFloat {
            var raw: CFTypeRef?
            var found = CGSize.zero
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &raw) == .success, let raw, AXValueGetValue(raw as! AXValue, .cgSize, &found) else { return .infinity }
            return abs(found.width - size.width) + abs(found.height - size.height)
        }
        let movable = all.filter { window in
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        }
        guard let window = movable.min(by: { distance($0) < distance($1) }) else { return }
        var point = origin
        if let position = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
    }
}
