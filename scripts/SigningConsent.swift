#!/usr/bin/env swift
import AppKit
import LocalAuthentication

/// Native consent for Portside builds. Exit 0 = Okay + auth succeeded (or
/// auth unavailable but user confirmed), 1 = Not Now / auth cancelled / timeout.
///
/// Uses stock NSAlert (no custom panel, so no extra border/shadow frame).
/// Okay is the default/primary action; Not Now is destructive. After Okay,
/// LocalAuthentication shows the system Touch ID / password sheet.
///
/// Optional arg: unused icon path kept for call-site compatibility.

enum Consent {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Ready to build Portside"
        alert.informativeText = "macOS may ask once so rebuilds keep your app permissions."
        alert.icon = NSImage(named: NSImage.applicationIconName)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

        if let path = CommandLine.arguments.dropFirst().first,
           FileManager.default.fileExists(atPath: path),
           let image = NSImage(contentsOfFile: path) {
            alert.icon = image
        }

        alert.addButton(withTitle: "Okay")
        alert.addButton(withTitle: "Not Now")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        if #available(macOS 11.0, *) {
            alert.buttons[1].hasDestructiveAction = true
        }

        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn else { return 1 }

        return authenticate() ? 0 : 1
    }

    /// System Touch ID / password sheet. Success unlocks owner auth for this
    /// process so the follow-up keychain partition fix can often proceed
    /// without typing into a custom dialog.
    private static func authenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            // No biometrics/password UI available; treat Okay as consent alone.
            return true
        }

        let reason = "Confirm it’s you so Portside can sign this build"
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
            ok = success
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 180)
        return ok
    }
}

exit(Consent.run())
