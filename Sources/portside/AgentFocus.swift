import AppKit
import ApplicationServices
import os.log

/// Brings an agent's own window forward (Agents widget click).
///
/// Walks up from the agent process to the app hosting it. Terminal and
/// iTerm2 then select the exact tab by the agent's tty over AppleScript
/// (Automation, asked once per app). Other apps (T3 Code, VS Code, Ghostty)
/// raise the window whose title contains the project folder's name, through
/// Accessibility when Portside has it. Otherwise the app comes forward.
enum AgentFocus {
    private static let logger = Logger(subsystem: "com.james.portside", category: "Widgets")
    /// AppleScript can wait on a busy app or the Automation prompt.
    private static let queue = DispatchQueue(label: "com.james.portside.agentfocus")

    static func focus(pid: pid_t, project: String?) {
        guard let app = hostApp(of: pid) else {
            logger.info("agents: no app hosts pid \(pid)")
            return
        }
        let tty = ttyPath(of: pid)
        queue.async {
            var selected = false
            if let tty, let script = tabScript(for: app.bundleIdentifier, tty: tty) {
                selected = runScript(script)
            }
            DispatchQueue.main.async {
                let raised = selected || raiseWindow(of: app, matching: project)
                bringForward(app)
                logger.info("agents: focus \(app.bundleIdentifier ?? "?", privacy: .public) \(selected ? "tab" : raised ? "window" : "app", privacy: .public)")
            }
        }
    }

    /// `NSRunningApplication.activate()` is ignored while Portside is not
    /// the active app, which it never is. Launch Services activates from
    /// the background (the same path app tiles use).
    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                logger.error("agents: activate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Process tree

    /// The nearest ancestor of `pid` that is a regular app.
    static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let info = processInfo(current) else { return nil }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// "/dev/ttys003", or nil when the agent has no terminal (an app
    /// running it as a subprocess).
    private static func ttyPath(of pid: pid_t) -> String? {
        guard let device = processInfo(pid)?.kp_eproc.e_tdev, device != -1,
              let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length > 0 else { return nil }
        return info
    }

    // MARK: - Terminal tabs

    private static func tabScript(for bundleID: String?, tty: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            nil
        }
    }

    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of 5 seconds\n\(source)\nend timeout")?
            .executeAndReturnError(&error)
        if let error {
            logger.error("agents: focus script failed (\(error[NSAppleScript.errorNumber] as? Int ?? 0))")
            return false
        }
        return result?.booleanValue ?? false
    }

    // MARK: - Accessibility

    /// Raises the window whose title names the project. False without
    /// Accessibility access or a matching window.
    private static func raiseWindow(of app: NSRunningApplication, matching project: String?) -> Bool {
        guard let project, AXIsProcessTrusted() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let title = title as? String, title.localizedCaseInsensitiveContains(project) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            return true
        }
        return false
    }
}
