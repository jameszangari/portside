import AppKit
import Darwin
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
        let reopened = arguments.contains(afterDevCopyFlag)
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
                // A copy still starting is not an app yet; it has changed nothing, so a signal is safe.
                if NSRunningApplication(processIdentifier: copy.pid)?.terminate() != true { kill(copy.pid, SIGTERM) }
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
            // Reopened by a development copy that quit while another started: nothing to explain.
            if !reopened { showYieldAlert() }
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

    /// Other Portside processes, from the process table rather than
    /// `NSWorkspace`: a copy that is still starting is not a registered app
    /// yet, and two copies started together would each miss the other.
    /// Matched by executable name; command-line runs (`--dump-debug`, probes,
    /// a copy's `--watch-native-dock` helper) are skipped by their arguments.
    private static func runningCopies() -> [PortsideCopy] {
        let me = ProcessInfo.processInfo.processIdentifier
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var paths: [pid_t: String] = [:]
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, found)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if (path as NSString).lastPathComponent == "portside" { paths[pid] = path }
        }
        return paths.keys.sorted().compactMap { pid in
            guard pid != me, let arguments = arguments(of: pid), isCopy(arguments: arguments) else { return nil }
            let path = paths[pid] ?? ""
            let bundle = path.range(of: ".app/Contents/MacOS/").map { URL(fileURLWithPath: String(path[..<$0.lowerBound]) + ".app") }
            return PortsideCopy(pid: pid, isInstalledApp: bundle != nil, bundleURL: bundle)
        }
    }

    /// A copy runs with no arguments, or as a reopened installed copy.
    /// Internal for tests.
    static func isCopy(arguments: [String]) -> Bool {
        let rest = Array(arguments.dropFirst())
        return rest.isEmpty || (rest.count == 2 && rest[0] == afterDevCopyFlag)
    }

    /// A process's arguments, the executable first (`KERN_PROCARGS2`).
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        let argc = Int(data.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding NULs, then argv.
        while index < size, data[index] != 0 { index += 1 }
        while index < size, data[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, data[index] != 0 { index += 1 }
            arguments.append(String(decoding: data[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
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
