import AppKit
import ApplicationServices
import Combine

/// Whether Portside may use Accessibility (`WindowFitter` needs it), kept
/// current without polling: macOS posts `com.apple.accessibility.api`
/// whenever any app's Accessibility access changes, and the answer is
/// re-read on that and when Portside becomes active.
///
/// React analogy: a tiny context provider with one boolean.
final class AccessibilityTrust: ObservableObject {
    static let shared = AccessibilityTrust()

    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new value lands just after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
    }

    /// The system "would like to control this computer" prompt (it offers
    /// to open Privacy & Security). No-op when already trusted.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    /// System Settings > Privacy & Security > Accessibility.
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
