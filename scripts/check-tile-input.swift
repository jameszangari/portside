import AppKit
import ApplicationServices

// Integration check against the real dock, not a simplified gesture harness.
// Usage: swift scripts/check-tile-input.swift <portside-pid> <bottom|left|right>
// Requires Accessibility access for the terminal. Keep the mouse still while
// it runs. Opens Finder, exercises hold/Escape/click, and checks label centering.
guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]),
      ["bottom", "left", "right"].contains(CommandLine.arguments[2]) else {
    fatalError("Usage: check-tile-input.swift <portside-pid> <bottom|left|right>")
}
let edge = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
let original = CGEvent(source: nil)!.location
let started = Date()
func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &result)
    return result
}
func find(_ element: AXUIElement, role: String, depth: Int = 0) -> CGRect? {
    guard depth < 16 else { return nil }
    let label = value(element, kAXDescriptionAttribute) as? String
        ?? value(element, kAXValueAttribute) as? String
        ?? value(element, kAXTitleAttribute) as? String
    if value(element, kAXRoleAttribute) as? String == role, label == "Finder",
       let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) {
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        if extent.width > 0 { return CGRect(origin: point, size: extent) }
    }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let rect = find(child, role: role, depth: depth + 1) { return rect }
    }
    return nil
}
func send(_ type: CGEventType, at point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}
defer { send(.mouseMoved, at: original) }
let screen = CGDisplayBounds(CGMainDisplayID())
let reveal = edge == "bottom" ? CGPoint(x: screen.midX, y: screen.maxY - 1)
    : CGPoint(x: edge == "left" ? 0 : screen.maxX - 1, y: screen.midY)
send(.mouseMoved, at: reveal)
Thread.sleep(forTimeInterval: 0.5)
func hoverFinder() -> CGPoint {
    guard let tile = find(app, role: kAXImageRole) else { fatalError("Finder tile unavailable (check Accessibility permission)") }
    let point = CGPoint(x: tile.midX, y: tile.midY)
    send(.mouseMoved, at: point)
    Thread.sleep(forTimeInterval: 0.6)
    return point
}
func click(seconds: Double) {
    let point = hoverFinder()
    send(.leftMouseDown, at: point)
    Thread.sleep(forTimeInterval: seconds)
    send(.leftMouseUp, at: point)
    Thread.sleep(forTimeInterval: 0.4)
}
click(seconds: 0.1)
click(seconds: 0.7)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.3)
click(seconds: 0.1)
_ = hoverFinder()
// Ensure a mouse move after clicking, which intentionally clears the label.
let point = CGEvent(source: nil)!.location
send(.mouseMoved, at: CGPoint(x: point.x + 1, y: point.y))
Thread.sleep(forTimeInterval: 0.4)
guard let tile = find(app, role: kAXImageRole), let label = find(app, role: kAXStaticTextRole) else {
    fatalError("Finder tile/label unavailable")
}
let error = edge == "bottom" ? abs(tile.midX - label.midX) : abs(tile.midY - label.midY)
assert(error <= 1.5, "Label is off center by \(error) points")
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
let log = Process()
log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
log.arguments = ["show", "--start", formatter.string(from: started), "--info", "--style", "compact",
                 "--predicate", "processID == \(pid) AND subsystem == 'com.james.portside'"]
let pipe = Pipe()
log.standardOutput = pipe
try log.run()
let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
log.waitUntilExit()
let lines = output.components(separatedBy: "\n")
let launches = lines.filter { $0.contains("activating Finder") || $0.contains("launching Finder") }.count
let menus = lines.filter { $0.contains("press and hold: opening menu") }.count
assert(launches == 2, "Expected exactly two Finder actions, got \(launches)\n\(output)")
assert(menus == 1, "Expected one hold menu, got \(menus)\n\(output)")
assert(!lines.contains { $0.contains("portside active: true") }, "Portside stole focus")
print("PASS \(edge): 2 clicks, 1 hold, no hold-release launch; label center error \(error)pt; Portside inactive")
