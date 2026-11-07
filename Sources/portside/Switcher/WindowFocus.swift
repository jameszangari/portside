import AppKit
import ApplicationServices

/// An AX element is an immutable CF reference, safe to hand to another
/// thread; every call on it below runs on the focus queue.
private struct WindowRef: @unchecked Sendable {
    let element: AXUIElement
}

enum WindowFocusResult: Equatable {
    /// Raised, and its app asked to come forward.
    case focused
    /// The window closed, its app quit, or the pid now belongs to another launch.
    case gone
    /// The window is there but refused to raise (protected or not answering).
    case refused
}

/// Brings one window forward through public Accessibility calls, the way
/// clicking it would: unminimize if needed, raise, make it main, then make
/// its app frontmost. It never moves or resizes the window, so a window on
/// another display stays there; a full-screen window's Space comes forward
/// as macOS does for any activation.
///
/// The launch is checked on the main thread before dispatch and again on
/// the focus queue right before the first call, and the element must still
/// be a window of that pid, so a stale id or a reused pid focuses nothing.
/// Every Accessibility call runs on one serial queue with a short timeout.
enum WindowFocuser {
    private static let queue = DispatchQueue(label: "com.james.portside.switcher.focus", qos: .userInteractive)

    @MainActor
    static func focus(_ target: WindowFocusTarget, completion: @escaping @MainActor (WindowFocusResult) -> Void) {
        guard let element = (target.handle.base as? AXElementKey)?.element,
              let running = sameLaunch(target.app) else { return completion(.gone) }
        if running.isHidden { running.unhide() }
        let record = target.app, window = WindowRef(element: element)
        queue.async {
            let (result, frontmost) = raise(window.element, of: record)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The window is raised but the app did not take the
                    // frontmost request: activate it the dock's way.
                    if result == .focused, !frontmost, let app = sameLaunch(record),
                       let url = app.bundleURL, let pinned = PinnedApp(appURL: url) {
                        AppLauncher.open(pinned, running: app)
                    }
                    completion(result)
                }
            }
        }
    }

    /// The running app, only if it is still the launch the registry read.
    /// `NSRunningApplication` properties are safe to read from any thread.
    private static func sameLaunch(_ record: RunningAppRecord) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
              RunningAppRecord(app).isSameLaunch(as: record) else { return nil }
        return app
    }

    private static func raise(_ window: AXUIElement, of record: RunningAppRecord) -> (WindowFocusResult, frontmost: Bool) {
        guard sameLaunch(record) != nil else { return (.gone, false) }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == record.pid else { return (.gone, false) }
        AXUIElementSetMessagingTimeout(window, AXWindowSource.axTimeout)
        var role: CFTypeRef?
        switch AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) {
        case .success where role as? String == kAXWindowRole: break
        case .invalidUIElement, .success: return (.gone, false)
        default: return (.refused, false)
        }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? NSNumber)?.boolValue == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return (.refused, false) }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(record.pid)
        AXUIElementSetMessagingTimeout(app, AXWindowSource.axTimeout)
        let frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        return (.focused, frontmost)
    }

    /// Display names by id, only while more than one display is connected
    /// (with one, saying which display is noise).
    @MainActor
    static func displayNames() -> [CGDirectDisplayID: String] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return [:] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[number.uint32Value] = screen.localizedName
        }
        return names
    }
}
