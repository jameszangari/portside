import AppKit
// Window-fit probe target (see ProbeObserver.swift). Probe window. Logs every frame change with a mach-based timestamp so the
// observer process can line its AX notifications up against it.
final class D: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var w: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "Probe")
        appItem.submenu!.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let winItem = NSMenuItem(); let winMenu = NSMenu(title: "Window"); winItem.submenu = winMenu
        menu.addItem(winItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = winMenu
        w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 600, height: 400),
                     styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "PortsideProbe"
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        log("launch")
    }
    func log(_ what: String) {
        let f = w.frame
        print(String(format: "TARGET %.4f %@ x=%.0f y=%.0f w=%.0f h=%.0f", CACurrentMediaTime(), what, f.minX, f.minY, f.width, f.height))
        fflush(stdout)
    }
    func windowDidResize(_ n: Notification) { log("resize") }
    func windowDidMove(_ n: Notification) { log("move") }
}
let app = NSApplication.shared
let d = D(); app.delegate = d
app.setActivationPolicy(.regular)
app.run()
