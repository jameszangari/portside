import AppKit
import ApplicationServices
// Window-fit probe (Phase 0 of "windows respect Portside"). Drives the probe
// window: Rectangle maximize, native Window > Fill, macOS Dock hiding
// toggles. Logs AX moved/resized notifications and can clamp a window out of
// a fake 80pt reserved band. Run through run.sh, which restores any
// com.apple.dock or Rectangle value it touches.
//
// Modes: rect, native, gap, dock, dock2, dock3, fit, fillwait, hold, all (rect + native + gap).
setvbuf(stdout, nil, _IOLBF, 0)
func now() -> Double { CACurrentMediaTime() }
func log(_ s: String) { print(String(format: "OBS    %.4f ", now()) + s) }

let reserve: CGFloat = 80
let screenH = NSScreen.screens[0].frame.height
log("screens=\(NSScreen.screens.count) primary=\(NSScreen.screens[0].frame) visible=\(NSScreen.screens[0].visibleFrame)")

guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.james.portside.probe").first else { log("no probe"); exit(1) }
let pid = target.processIdentifier
let appEl = AXUIElementCreateApplication(pid)
func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}
func window() -> AXUIElement? { (attr(appEl, kAXWindowsAttribute) as [AXUIElement]?)?.first }
func frame(_ w: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv: AXValue = attr(w, kAXPositionAttribute) { AXValueGetValue(pv, .cgPoint, &p) }
    if let sv: AXValue = attr(w, kAXSizeAttribute) { AXValueGetValue(sv, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func setFrame(_ w: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}
func setSize(_ w: AXUIElement, _ size: CGSize) {
    var s = size
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}

var clampOn = false
var phase = "idle"
var clampCount = 0
var observer: AXObserver?
enum H { static func handle(_ el: AXUIElement, _ note: String) {
    let f = frame(el)
    log("AX \(phase) \(note) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height)) bottomAX=\(Int(f.maxY))")
    settleEvent(el)
    guard clampOn else { return }
    let limit = screenH - reserve
    if f.maxY >= screenH - 2, f.maxY > limit + 1, clampCount < 3 {
        clampCount += 1
        let t = now()
        setSize(el, CGSize(width: f.width, height: limit - f.minY))
        log(String(format: "CLAMP set h=%.0f took %.2fms", limit - f.minY, (now() - t) * 1000))
    }
}}
func axCallback(_ o: AXObserver, _ el: AXUIElement, _ note: CFString, _ ctx: UnsafeMutableRawPointer?) { H.handle(el, note as String) }
AXObserverCreate(pid, axCallback, &observer)
for n in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowCreatedNotification] {
    var r = AXError.cannotComplete
    for _ in 0..<40 {
        r = AXObserverAddNotification(observer!, appEl, n as CFString, nil)
        if r == .success { break }
        usleep(100_000)
    }
    log("add \(n): \(r.rawValue)")
}
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer!), .defaultMode)

func front() -> Bool {
    AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let w = window() { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
    return true
}
func isFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
func reset() { if let w = window() { setFrame(w, CGRect(x: 300, y: 300, width: 600, height: 400)) } }
func rectangle(_ action: String) {
    guard isFront() else { log("SKIP rectangle \(action): probe not frontmost (\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))"); return }
    log("RECT start \(action)")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "rectangle://execute-action?name=\(action)"]
    try? p.run()
}
func menuItems(_ el: AXUIElement, depth: Int = 0, into out: inout [(String, AXUIElement)]) {
    guard depth < 6, let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) else { return }
    for k in kids {
        if let t: String = attr(k, kAXTitleAttribute), !t.isEmpty { out.append((t, k)) }
        menuItems(k, depth: depth + 1, into: &out)
    }
}
func pressMenu(_ title: String) {
    guard let bar: AXUIElement = attr(appEl, kAXMenuBarAttribute) else { log("no menubar"); return }
    var items: [(String, AXUIElement)] = []
    menuItems(bar, into: &items)
    guard let hit = items.first(where: { $0.0 == title }) else { log("no menu item \(title)"); return }
    log("MENU press \(title)")
    AXUIElementPerformAction(hit.1, kAXPressAction as CFString)
}
func defaults(_ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); p.arguments = args
    try? p.run(); p.waitUntilExit()
    log("defaults \(args.joined(separator: " ")) -> \(p.terminationStatus)")
}

var steps: [(Double, () -> Void)] = []
func at(_ t: Double, _ f: @escaping () -> Void) { steps.append((t, f)) }
let mode = CommandLine.arguments.dropFirst().first ?? "all"
var t = 0.5
func step(_ dt: Double, _ f: @escaping () -> Void) { at(t, f); t += dt }

if mode == "all" || mode == "rect" {
    step(0.6) { phase = "A-reset"; reset(); _ = front() }
    step(1.2) { phase = "A-rect-noclamp"; rectangle("maximize") }
    step(0.6) { phase = "B-reset"; reset(); _ = front() }
    step(1.2) { phase = "B-rect-clamp"; clampOn = true; clampCount = 0; rectangle("maximize") }
    step(0.6) { clampOn = false; phase = "C-reset"; reset(); _ = front() }
}
if mode == "all" || mode == "native" {
    step(2.0) { phase = "C-fill"; pressMenu("Fill") }
    step(0.6) { phase = "D-reset"; reset(); _ = front() }
    step(2.0) { phase = "D-fill-clamp"; clampOn = true; clampCount = 0; pressMenu("Fill") }
    step(0.6) { clampOn = false; phase = "E-reset"; reset(); _ = front() }
    step(2.0) { phase = "E-zoom"; pressMenu("Zoom") } // no Zoom item in the probe menu; logs "no menu item"
    step(0.6) { phase = "F-reset"; reset() }
}
if mode == "all" || mode == "gap" {
    step(0.8) { phase = "G-gapwrite"; defaults(["write", "com.knollsoft.Rectangle", "screenEdgeGapBottom", "-int", "\(Int(reserve))"]); reset(); _ = front() }
    step(1.2) { phase = "G-rect-gap"; rectangle("maximize") }
    step(0.8) { phase = "G-gapdelete"; defaults(["delete", "com.knollsoft.Rectangle", "screenEdgeGapBottom"]); reset() }
}
func run(_ path: String, _ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; try? p.run(); p.waitUntilExit() }
func report(_ tag: String) { if let w = window() { log("\(tag) frame=\(frame(w)) visible=\(NSScreen.screens[0].visibleFrame)") } }
if mode == "dock" {
    step(0.6) { phase = "K-reset"; reset(); _ = front() }
    step(1.5) { phase = "K-fill-hidden"; pressMenu("Fill") }
    step(0.3) { report("K after fill, dock hidden") }
    step(3.0) { phase = "K-dock-shown"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide false + killall") }
    step(0.3) { report("K after dock shown") }
    step(1.5) { phase = "K-fill-shown"; _ = front(); pressMenu("Fill") }
    step(0.3) { report("K after fill, dock shown") }
    step(3.0) { phase = "K-dock-hidden"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide true + killall") }
    step(0.3) { report("K after dock hidden again") }
}
if mode == "dock2" {
    step(0.6) { phase = "R-reset"; reset(); _ = front() }
    step(1.2) { phase = "R-rect"; rectangle("maximize") }
    step(0.3) { report("R after rectangle max, dock hidden") }
    step(3.0) { phase = "R-dock-shown"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide false + killall") }
    step(0.5) { report("R after dock shown (rectangle window)") }
    step(0.3) { phase = "O-place"; if let w = window() { setFrame(w, CGRect(x: 300, y: 780, width: 600, height: 300)) } }
    step(0.3) { report("O overlap placed, dock shown") }
    step(3.0) { phase = "O-dock-hidden"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide true + killall") }
    step(0.3) { report("O after dock hidden") }
    step(0.3) { phase = "P-place"; if let w = window() { setFrame(w, CGRect(x: 300, y: 780, width: 600, height: 300)) } }
    step(3.0) { phase = "P-dock-shown"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide false + killall") }
    step(0.3) { report("P overlap window after dock shown") }
    step(3.0) { phase = "P-dock-hidden"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide true + killall") }
    step(0.3) { report("P after dock hidden") }
}
if mode == "dock3" {
    step(0.6) { phase = "S-reset"; reset(); _ = front() }
    step(3.0) { phase = "S-dock-shown"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide false + killall") }
    step(1.2) { phase = "S-rect"; _ = front(); rectangle("maximize") }
    step(0.3) { report("S rectangle max with dock shown") }
    step(3.0) { phase = "S-dock-hidden"; run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]); run("/usr/bin/killall", ["Dock"]); log("dock autohide true + killall") }
    step(0.3) { report("S after dock hidden") }
}
// fit: no probe clamping. Run with Portside pinned to check WindowFitter.
if mode == "fit" {
    step(0.6) { phase = "F1-reset"; reset(); _ = front() }
    step(1.0) { phase = "F1-rect-max"; rectangle("maximize") }
    step(0.3) { report("F1 rectangle maximize") }
    step(0.6) { phase = "F2-reset"; reset(); _ = front() }
    step(1.0) { phase = "F2-rect-left-half"; rectangle("left-half") }
    step(0.3) { report("F2 rectangle left half") }
    step(0.6) { phase = "F3-reset"; reset(); _ = front() }
    step(1.5) { phase = "F3-fill"; pressMenu("Fill") }
    step(0.3) { report("F3 window fill") }
    step(0.6) { phase = "F4-overlap"; if let w = window() { setFrame(w, CGRect(x: 300, y: 700, width: 600, height: 380)) } }
    step(0.6) { report("F4 overlap, not flush (expect unchanged)") }
}
// fillwait: Fill, then one clamp after DELAY ms of quiet (env DELAY, default
// 60). Shows whether macOS snaps a just-Filled window back.
var settleItem: DispatchWorkItem?
var settleArmed = false
func settleEvent(_ el: AXUIElement) {
    guard settleArmed else { return }
    settleItem?.cancel()
    let delay = Double(ProcessInfo.processInfo.environment["DELAY"] ?? "60") ?? 60
    let item = DispatchWorkItem {
        settleArmed = false
        let f = frame(el)
        setSize(el, CGSize(width: f.width, height: screenH - reserve - f.minY))
        log("SETTLE clamp after \(Int(delay))ms quiet")
    }
    settleItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000, execute: item)
}
if mode == "fillwait" {
    step(0.6) { phase = "W-reset"; reset(); _ = front() }
    step(2.0) { phase = "W-fill"; settleArmed = true; pressMenu("Fill") }
    step(0.3) { report("W after fill + settle clamp") }
}
// hold: Rectangle maximize, then report the frame every 0.5s for HOLD
// seconds (env, default 20) while something else toggles Portside.
if mode == "hold" {
    step(0.6) { phase = "H-reset"; reset(); _ = front() }
    step(1.0) { phase = "H-rect-max"; rectangle("maximize") }
    let seconds = Double(ProcessInfo.processInfo.environment["HOLD"] ?? "20") ?? 20
    for _ in 0..<Int(seconds * 2) { step(0.5) { if let w = window() { log("HOLD frame=\(frame(w))") } } }
}
step(0.5) { if let w = window() { log("final frame \(frame(w))") }; exit(0) }
for (time, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: f) }
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
