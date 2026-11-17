import AppKit
import os

/// One running Portside other than this process.
struct PortsideCopy: Equatable {
    let pid: pid_t
    /// Inside a `.app` (a signed release or a `build-app.sh` bundle). A
    /// `swift run` or `.build` executable is a development copy.
    let isInstalledApp: Bool
    let bundleURL: URL?
}

/// Keeps one Portside on screen at a time. A development copy started while
/// another copy runs quits that copy first (so it restores the native Dock,
/// menu bar and settings itself) and reopens an installed copy when it quits.
/// An installed copy started while a development copy runs steps aside.
/// `PORTSIDE_ALLOW_SECOND_COPY=1` turns all of this off.
enum CopyHandoff {
    enum Decision: Equatable {
        case proceed
        /// Quit these copies, then start; reopen `relaunch` on quit.
        case takeOver(quit: [PortsideCopy], relaunch: URL?)
        /// A development copy runs; show why and quit.
        case yield(to: PortsideCopy)
    }

    static let allowSecondCopyVariable = "PORTSIDE_ALLOW_SECOND_COPY"
    /// Passed to the installed copy this process reopens, so it waits for
    /// this process to exit instead of stepping aside.
    static let afterDevCopyFlag = "--after-dev-copy"
    static let quitTimeout: TimeInterval = 10

    private static let logger = Logger(subsystem: "com.james.portside", category: "CopyHandoff")
    private static var relaunchURL: URL?

    static func decide(isDevCopy: Bool, others: [PortsideCopy], allowSecondCopy: Bool) -> Decision {
        guard !allowSecondCopy, !others.isEmpty else { return .proceed }
        if isDevCopy {
            return .takeOver(quit: others, relaunch: others.first(where: \.isInstalledApp)?.bundleURL)
        }
        // Two installed copies keep today's behavior.
        if let dev = others.first(where: { !$0.isInstalledApp }) { return .yield(to: dev) }
        return .proceed
    }

    /// True for a `swift run` or `.build` executable, false inside a `.app`.
    static var isDevCopy: Bool { Bundle.main.bundleURL.pathExtension != "app" }

    /// Runs before native Dock recovery and before `dock.json` loads, so a
    /// copy that is quitting has saved and restored everything first.
    static func runAtLaunch(arguments: [String] = CommandLine.arguments,
                            environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let flag = arguments.firstIndex(of: afterDevCopyFlag), flag + 1 < arguments.count,
           let pid = pid_t(arguments[flag + 1]) {
            if !waitForExit(pid, timeout: quitTimeout) {
                logger.error("development copy (pid \(pid)) still running after \(quitTimeout)s")
            }
        }
        let decision = decide(isDevCopy: isDevCopy, others: runningCopies(),
                              allowSecondCopy: environment[allowSecondCopyVariable] == "1")
        switch decision {
        case .proceed:
            return
        case let .takeOver(quit, relaunch):
            for copy in quit {
                logger.notice("quitting the other Portside (pid \(copy.pid)) before starting")
                NSRunningApplication(processIdentifier: copy.pid)?.terminate()
            }
            for copy in quit where !waitForExit(copy.pid, timeout: quitTimeout) {
                let message = "portside: the other Portside (pid \(copy.pid)) did not quit within \(Int(quitTimeout)) s. "
                    + "Quit it, or set \(allowSecondCopyVariable)=1 to run both.\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
            relaunchURL = relaunch
        case let .yield(to: dev):
            logger.notice("a development copy (pid \(dev.pid)) is running; not starting")
            showYieldAlert()
            exit(0)
        }
    }

    /// Reopens the installed copy this process quit at launch. Called once,
    /// from every normal quit path; a crash skips it.
    static func relaunchIfNeeded() {
        guard let url = relaunchURL else { return }
        relaunchURL = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path, "--args", afterDevCopyFlag, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
            logger.notice("reopening \(url.path, privacy: .public)")
        } catch {
            logger.error("could not reopen \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Other Portside processes. An installed copy has the bundle ID; a
    /// development executable has none, so it is matched by name.
    private static func runningCopies() -> [PortsideCopy] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != me, !app.isTerminated, app.activationPolicy != .prohibited else { return nil }
            let isApp = app.bundleURL?.pathExtension == "app"
            let matches = app.bundleIdentifier == AppInfo.bundleIdentifier
                || (app.bundleIdentifier == nil && app.executableURL?.lastPathComponent == "portside")
            guard matches else { return nil }
            return PortsideCopy(pid: app.processIdentifier, isInstalledApp: isApp, bundleURL: isApp ? app.bundleURL : nil)
        }
    }

    /// Waits on the kernel's exit event, not a timer loop.
    private static func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { exited.signal() }
        source.resume()
        defer { source.cancel() }
        // Gone before the source was armed: no event comes.
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        return exited.wait(timeout: .now() + timeout) == .success
    }

    private static func showYieldAlert() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()
        let alert = NSAlert()
        alert.messageText = "A development copy of Portside is running"
        alert.informativeText = "Quit it, then open Portside again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
