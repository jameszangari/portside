import AppKit
import ApplicationServices

/// Undocumented notification names, subscribed through the public AX API.
/// Unsupported subscriptions leave the independent window test available.
final class DockNotifications {
    static func checkWindowManagerAccessibility() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.WindowManager"
        }) else {
            ProbeLog.write("PUBLIC AX: WindowManager process not found")
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var windows: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
        ProbeLog.write("PUBLIC AX: WindowManager windows result=\(read.rawValue) count=\((windows as? [AXUIElement])?.count ?? 0)")
        var observer: AXObserver?
        let create = AXObserverCreate(app.processIdentifier, { _, _, _, _ in }, &observer)
        guard create == .success, let observer else {
            ProbeLog.write("PUBLIC AX: WindowManager observer result=\(create.rawValue)")
            return
        }
        for name in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            let result = AXObserverAddNotification(observer, element, name as CFString, nil)
            ProbeLog.write("PUBLIC AX: WindowManager \(name) result=\(result.rawValue)")
            if result == .success { AXObserverRemoveNotification(observer, element, name as CFString) }
        }
    }

    static let names = [
        "AXExposeShowAllWindows", "AXExposeShowFrontWindows",
        "AXExposeShowDesktop", "AXExposeExit"
    ]
    private var observer: AXObserver?
    private var element: AXUIElement?
    var received: (String) -> Void = { _ in }

    func start() {
        stop()
        ProbeLog.write("Accessibility trusted=\(AXIsProcessTrusted())")
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            ProbeLog.write("Dock not found; window test remains available")
            return
        }
        let result = AXObserverCreate(dock.processIdentifier, { _, _, name, context in
            guard let context else { return }
            let listener = Unmanaged<DockNotifications>.fromOpaque(context).takeUnretainedValue()
            listener.received(name as String)
        }, &observer)
        guard result == .success, let observer else {
            ProbeLog.write("AXObserverCreate error=\(result.rawValue); window test remains available")
            return
        }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.5)
        for name in Self.names {
            let result = AXObserverAddNotification(observer, element, name as CFString,
                                                   Unmanaged.passUnretained(self).toOpaque())
            ProbeLog.write("subscribe \(name) result=\(result.rawValue) (0=accepted, not proof of delivery)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let element {
                for name in Self.names {
                    AXObserverRemoveNotification(observer, element, name as CFString)
                }
            }
        }
        observer = nil
        element = nil
    }
}
