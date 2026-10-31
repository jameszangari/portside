import AppKit
import AppLoginItemList
import CoreServices
import os
import ServiceManagement

/// "Open at Login" for an arbitrary app tile, matching the native Dock menu.
///
/// Reads use the session login-items list (`LSSharedFileList` via
/// `AppLoginItemList.c`), which still mirrors System Settings > Open at Login
/// and needs no Automation permission. Writes go through System Events (the
/// only mutation path that still persists on current macOS); the first toggle
/// may ask for Automation. Portside's own tile uses `SMAppService.mainApp`
/// when running as an .app, same as Settings > Open Portside at login.
enum AppLoginItem {
    private static let logger = Logger(subsystem: "com.james.portside", category: "AppLoginItem")

    /// Whether `app` currently appears under Open at Login.
    static func isEnabled(for app: PinnedApp) -> Bool {
        if isPortside(app), Bundle.main.bundleURL.pathExtension == "app" {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        return sessionListContains(app.url)
    }

    /// Turns Open at Login on or off for `app`. Returns an error message on
    /// failure (Automation denied, script error); nil on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool, for app: PinnedApp) -> String? {
        if isPortside(app), Bundle.main.bundleURL.pathExtension == "app" {
            return setPortsideEnabled(enabled)
        }
        return setSessionItemEnabled(enabled, url: app.url, name: app.displayName)
    }

    private static func isPortside(_ app: PinnedApp) -> Bool {
        if app.bundleIdentifier == "com.james.portside" { return true }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return app.url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
        return false
    }

    private static func setPortsideEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            logger.info("Portside login item \(enabled ? "on" : "off", privacy: .public)")
            return nil
        } catch {
            logger.error("Portside login item failed: \(error.localizedDescription, privacy: .public)")
            return "Could not update Open at Login: \(error.localizedDescription)"
        }
    }

    // MARK: - Session list (read)

    private static func sessionListContains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        if AppLoginItemListContainsPath(target.path) { return true }
        // Same app installed in two places (Applications vs User Applications).
        // Re-check by walking known login paths via System Events is heavy; a
        // second probe by bundle id uses the list helper on each candidate
        // from Launch Services.
        guard let bundleID = Bundle(url: target)?.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?
            .takeRetainedValue() as? [URL] {
            for candidate in urls {
                if AppLoginItemListContainsPath(candidate.standardizedFileURL.path) { return true }
            }
        }
        return false
    }

    // MARK: - System Events (write)

    private static func setSessionItemEnabled(_ enabled: Bool, url: URL, name: String) -> String? {
        let path = url.standardizedFileURL.path
        let status = systemEventsAutomationStatus(askUser: true)
        if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
            logger.error("System Events Automation denied (\(status)) for \(name, privacy: .public)")
            return "Allow System Events in Privacy & Security > Automation to change Open at Login."
        }
        let quoted = appleScriptString(path)
        let source: String
        if enabled {
            source = """
            tell application "System Events"
              if (path of every login item) does not contain \(quoted) then
                make login item at end with properties {path:\(quoted), hidden:false}
              end if
            end tell
            """
        } else {
            source = """
            tell application "System Events"
              delete (every login item whose path is \(quoted))
            end tell
            """
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            logger.error("System Events \(enabled ? "add" : "remove", privacy: .public) failed (\(number)): \(message, privacy: .public)")
            if number == Int(errAEEventNotPermitted) {
                return "Allow System Events in Privacy & Security > Automation to change Open at Login."
            }
            return "Could not update Open at Login for \(name)."
        }
        let nowOn = sessionListContains(url)
        if nowOn != enabled {
            logger.error("Open at Login for \(name, privacy: .public) did not stick (wanted \(enabled))")
            return "Could not update Open at Login for \(name)."
        }
        logger.info("Open at Login \(enabled ? "on" : "off", privacy: .public) for \(name, privacy: .public)")
        return nil
    }

    private static func systemEventsAutomationStatus(askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let desc = target.aeDesc else { return OSStatus(errAEEventNotPermitted) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Alert when a toggle fails, then hand focus back to the previous app.
    static func presentError(_ message: String) {
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        let alert = NSAlert()
        alert.messageText = "Open at Login"
        alert.informativeText = message
        alert.icon = AppIcon.image(points: 64)
        alert.addButton(withTitle: "OK")
        if message.contains("Automation") {
            alert.addButton(withTitle: "Open Settings")
        }
        NSApp.activate()
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
        if let previous, !previous.isTerminated {
            previous.activate(from: .current)
        } else if previous == nil, NSApp.activationPolicy() == .accessory {
            NSApp.deactivate()
        }
    }
}
