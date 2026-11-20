import AppKit
import ApplicationServices
import MachO
import OSLog

/// Settings > General > More > Export Debug Report, and `portside --dump-debug
/// [folder]`: a zip of what helps fix a bug on a Mac we can't test on (a
/// different macOS, a managed work Mac). More than Copy Diagnostics: it has
/// app names, menu bar item titles, settings and Portside's logs, so the
/// person reads it before sending. Nothing leaves the Mac by itself.
///
/// Files: `report.txt` (Copy Diagnostics, in the app only), `system.txt`,
/// `private-apis.txt`, `menubar.txt`, `logs.txt`, `system-logs.txt`,
/// `dock.json`, `defaults.txt`, and `crashes/` and `logs/` copies.
enum DebugDump {
    struct File: Sendable {
        let name: String
        let text: String
    }

    /// The parts that read AppKit or app state, on the main thread.
    @MainActor static func mainThreadFiles(report: String?) -> [File] {
        var files: [File] = []
        if let report { files.append(File(name: "report.txt", text: report)) }
        files.append(File(name: "system.txt", text: systemText()))
        files.append(File(name: "menubar-files.json", text: menuBarFilesText()))
        return files
    }

    static func defaultName(_ date: Date = Date()) -> String { "Portside Debug \(stamp(date)).zip" }

    /// Writes every file and zips them to `zip`. Slow (it runs `log show`),
    /// so call it off the main thread.
    static func write(_ mainFiles: [File], to zip: URL, home: String = NSHomeDirectory()) throws {
        let name = zip.deletingPathExtension().lastPathComponent
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }

        var files = mainFiles
        files.append(File(name: "private-apis.txt", text: privateAPIText()))
        files.append(File(name: "menubar.txt", text: menuBarText()))
        files.append(File(name: "logs.txt", text: portsideLogs()))
        files.append(File(name: "system-logs.txt", text: systemLogs()))
        files.append(File(name: "defaults.txt", text: defaultsText()))
        for file in files {
            try Data(file.text.utf8).write(to: work.appendingPathComponent(file.name))
        }
        copy(DockModel.storageDirectory.appendingPathComponent("dock.json"), into: work)
        copyRecent(in: URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/DiagnosticReports"),
                   matching: { $0.lowercased().hasPrefix("portside") }, into: work.appendingPathComponent("crashes"))
        copyRecent(in: URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Portside"),
                   matching: { _ in true }, into: work.appendingPathComponent("logs"))
        for path in ["/tmp/portside-assertion-diag.json", "/tmp/portside-file-schema.json"] {
            copy(URL(fileURLWithPath: path), into: work)
        }

        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: zip)
        let result = run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", work.path, zip.path], timeout: 60)
        guard FileManager.default.fileExists(atPath: zip.path) else {
            throw NSError(domain: "DebugDump", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not zip the report: \(result)"])
        }
    }

    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmmss"
        return format.string(from: date)
    }

    // MARK: - system.txt

    @MainActor private static func systemText() -> String {
        let info = ProcessInfo.processInfo
        var lines = [
            AppInfo.versionLine,
            "macOS \(info.operatingSystemVersionString)",
            run("/usr/bin/sw_vers", []).trimmingCharacters(in: .whitespacesAndNewlines),
            "model: \(sysctl("hw.model")), \(machine()), \(info.processorCount) cores, \(info.physicalMemory / 1_073_741_824) GB",
            "uptime: \(Int(info.systemUptime / 60)) min, locale \(Locale.current.identifier), \(TimeZone.current.identifier)",
            "",
            "App",
            "  bundle: \(Bundle.main.bundlePath)",
            "  in /Applications: \(Bundle.main.bundlePath.hasPrefix("/Applications/"))",
            "  bundle id: \(Bundle.main.bundleIdentifier ?? "none")",
            "  pid: \(info.processIdentifier), running as app: \(NSApp?.isRunning == true)",
            "  signature:",
        ]
        lines += run("/usr/bin/codesign", ["-dv", "--verbose=2", Bundle.main.bundlePath]).split(separator: "\n")
            .filter { !$0.hasPrefix("CDHash") }.map { "    " + $0 }
        lines += [
            "",
            "Permissions (this process; from Terminal they are Terminal's)",
            "  Accessibility: \(AXIsProcessTrusted())",
            "  Screen Recording: \(CGPreflightScreenCaptureAccess())",
            "  Input Monitoring: \(CGPreflightListenEventAccess())",
            "",
            "Menu bar",
            "  assertion hiding: \(MenuBarAssertionOptIn.isEnabled()) (needs macOS \(MenuBarAssertionOptIn.minimumOSMajor)+)",
            "  developer hooks: \(MenuBarAssertionOptIn.developerHooks())",
            "  assertion bridge: \(LiveMenuBarAssertionBridge().unavailableReason ?? "available")",
            "",
            "Environment",
        ]
        let environment = info.environment.filter { $0.key.hasPrefix("PORTSIDE") || $0.key == "CFFIXED_USER_HOME" }
        lines += environment.isEmpty ? ["  (no PORTSIDE variables)"] : environment.sorted { $0.key < $1.key }.map { "  \($0.key)=\($0.value)" }
        lines += ["", "Screens"]
        for (index, screen) in NSScreen.screens.enumerated() {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            lines += [
                "  \(index): \(screen.localizedName) id \(id)\(screen == NSScreen.main ? " (main)" : "")",
                "    frame \(screen.frame), visible \(screen.visibleFrame), scale \(screen.backingScaleFactor)",
                "    menu bar height \(screen.frame.maxY - screen.visibleFrame.maxY), safe area top \(screen.safeAreaInsets.top)",
                "    notch areas: left \(screen.auxiliaryTopLeftArea.map { "\($0)" } ?? "none"), right \(screen.auxiliaryTopRightArea.map { "\($0)" } ?? "none")",
            ]
        }
        lines += ["", "Appearance: \(NSApp?.effectiveAppearance.name.rawValue ?? NSAppearance.currentDrawing().name.rawValue)",
                  "Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), Reduce Transparency: \(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)",
                  "Menu bar auto-hide: \(UserDefaults.standard.bool(forKey: "_HIHideMenuBar"))"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The shape of the two system menu bar files, when granted.
    @MainActor private static func menuBarFilesText() -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("portside-menubar-files-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        MenuBarSystemFiles.dumpSchema([("layout", MenuBarSystemFiles.layoutGrant()), ("appList", MenuBarSystemFiles.appListGrant())], to: path)
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "{}\n"
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    private static func machine() -> String {
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    // MARK: - private-apis.txt

    /// Every private symbol and class Portside loads, found or missing on
    /// this macOS, plus the menu bar framework's classes and methods so a
    /// changed API can be matched without that Mac.
    private static let symbols: [(framework: String, names: [String])] = [
        ("/System/Library/Frameworks/CoreServices.framework/CoreServices",
         ["_LSASNCreateWithPid", "_LSCopyApplicationInformationItem"]),
        ("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
         ["DisplayServicesGetBrightness", "DisplayServicesSetBrightness",
          "DisplayServicesRegisterForBrightnessChangeNotifications", "DisplayServicesUnregisterForBrightnessChangeNotifications"]),
        ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
         ["SLSMainConnectionID", "CGSMainConnectionID", "SLSSetConnectionProperty", "CGSSetConnectionProperty",
          "SLSCopyConnectionProperty", "CGSCopyConnectionProperty", "SLSRegisterConnectionNotifyProc",
          "SLSRequestNotificationsForWindows", "SLSGetWindowOwner", "SLSConnectionGetPID", "SLSGetWindowLevel", "SLSGetWindowBounds"]),
    ]
    private static let menuBarFramework = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

    private static func privateAPIText() -> String {
        var lines: [String] = []
        for (framework, names) in symbols {
            let handle = dlopen(framework, RTLD_LAZY)
            lines.append("\(framework): \(handle == nil ? "not loadable" : "loaded")")
            for name in names {
                lines.append("  \(name): \(handle.flatMap { dlsym($0, name) } == nil ? "MISSING" : "ok")")
            }
        }
        for name in ["CABackdropLayer", "CAFilter"] {
            lines.append("QuartzCore \(name): \(NSClassFromString(name) == nil ? "MISSING" : "ok")")
        }
        lines += ["", "\(menuBarFramework): \(dlopen(menuBarFramework, RTLD_LAZY) == nil ? "not loadable" : "loaded")"]
        // The class list wants the path dyld loaded it from, which can differ.
        let image = (0..<_dyld_image_count()).lazy.compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
            .first { $0.hasSuffix("/MenuBarClientCore") } ?? menuBarFramework
        var count: UInt32 = 0
        if let names = objc_copyClassNamesForImage(image, &count), count > 0 {
            defer { free(names) }
            for index in 0..<Int(count) {
                let name = String(cString: names[index])
                lines.append("  class \(name)")
                guard let type = objc_getClass(name) as? AnyClass else { continue }
                lines += methods(of: type).map { "    - \($0)" }
                if let meta = object_getClass(type) { lines += methods(of: meta).map { "    + \($0)" } }
            }
        } else {
            lines.append("  (no classes)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func methods(of type: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(type, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { index in
            let method = list[index]
            let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            return "\(NSStringFromSelector(method_getName(method))) \(encoding)"
        }.sorted()
    }

    // MARK: - menubar.txt

    private static func menuBarText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let names = Dictionary(NSWorkspace.shared.runningApplications.map {
            ($0.processIdentifier, "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "no id"))")
        }, uniquingKeysWith: { first, _ in first })
        func owner(_ pid: pid_t) -> String { "\(pid) \(names[pid] ?? "?")" }

        var lines = ["System menu bar processes"]
        for bundle in ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.WindowManager", "com.apple.dock"] {
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map { "\($0.processIdentifier)" }
            lines.append("  \(bundle): \(pids.isEmpty ? "not running" : pids.joined(separator: ", "))")
        }

        lines += ["", "Windows at menu bar levels (CGWindowList, on screen)"]
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= menuLevel - 1, layer <= Int(CGWindowLevelForKey(.popUpMenuWindow)) else { continue }
            let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            let title = (window[kCGWindowName as String] as? String).map { " \"\($0)\"" } ?? ""
            lines.append("  layer \(layer) #\(window[kCGWindowNumber as String] ?? "?") \(bounds)\(title) \(owner(pid))")
        }
        lines.append("  (status level is \(Int(CGWindowLevelForKey(.statusWindow))), main menu \(menuLevel))")

        lines += ["", "Drawn items as Portside reads them (macOS \(os): \(os < 27 ? "status windows, owner by Accessibility hit test" : "MenuBarAgent over Accessibility"))"]
        if let items = MenuBarDrawnOwners.ownedItems() {
            lines += items.sorted { $0.frame.minX < $1.frame.minX }.map {
                "  x \(Int($0.frame.minX))...\(Int($0.frame.maxX)) y \(Int($0.frame.minY)) \(owner($0.pid))\($0.isOverflowControl ? " [overflow control]" : "")"
            }
            if items.isEmpty { lines.append("  (none)") }
        } else {
            lines.append("  unreadable (Accessibility off, or MenuBarAgent not running)")
        }

        lines += ["", "Menu extras over Accessibility (AXExtrasMenuBar of every app)"]
        let snapshot = AXMenuBarItemSource.live.snapshot()
        lines.append("  access \(snapshot.access), \(snapshot.items.count) items, \(snapshot.unsupportedCount) unsupported, \(snapshot.skippedApps) apps skipped")
        for item in snapshot.items {
            lines.append("  \(item.id) \"\(item.title)\" press \(item.canPress) \(owner(item.pid))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - logs

    /// Portside's own log, plus system frameworks' errors in this process:
    /// `log show` for the last day, or, if that is not
    /// allowed (it needs an admin account), this process since launch.
    private static func portsideLogs() -> String {
        let shown = run("/usr/bin/log", ["show", "--last", "24h", "--info", "--debug", "--style", "compact",
                                         "--predicate", "subsystem == \"com.james.portside\" OR (process == \"portside\" AND (messageType == error OR messageType == fault OR eventMessage BEGINSWITH \"portside\"))"], timeout: 90)
        if shown.split(separator: "\n").count > 3 { return shown }
        var lines = ["log show gave nothing (\(shown.trimmingCharacters(in: .whitespacesAndNewlines))); this process since launch:"]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0),
                                               matching: NSPredicate(format: "subsystem == %@", AppInfo.bundleIdentifier))
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(entry.date) \(entry.level.rawValue) [\(entry.category)] \(entry.composedMessage)")
            }
        } catch {
            lines.append("unreadable: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last hour of the processes the menu bar and dock features talk
    /// to: errors, and anything that names Portside.
    private static func systemLogs() -> String {
        run("/usr/bin/log", ["show", "--last", "1h", "--info", "--style", "compact", "--predicate",
                             "(process IN {\"MenuBarAgent\", \"ControlCenter\", \"SystemUIServer\", \"Dock\", \"WindowManager\", \"tccd\"}) AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] \"portside\")"],
            timeout: 90)
    }

    private static func defaultsText() -> String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? AppInfo.bundleIdentifier) ?? [:]
        return domain.sorted { $0.key < $1.key }.map { key, value in
            let text = value is Data ? "<data, \((value as? Data)?.count ?? 0) bytes>" : String(describing: value)
            return "\(key) = \(text.prefix(2000))"
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - helpers

    private static func copy(_ source: URL, into folder: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
    }

    /// Files from the last 14 days, newest 20.
    private static func copyRecent(in folder: URL, matching: (String) -> Bool, into destination: URL) {
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { matching($0.lastPathComponent) }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > cutoff else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
        for (url, _) in files { copy(url, into: destination) }
    }

    /// Output and errors of a command, cut at 8 MB. Killed after `timeout`.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("portside-dump-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return "could not run \(path)" }
        defer { try? FileManager.default.removeItem(at: output) }
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return "could not run \(path): \(error.localizedDescription)" }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? handle.close()
        guard var data = try? Data(contentsOf: output) else { return "" }
        let limit = 8 * 1_048_576
        var suffix = ""
        if data.count > limit { data = data.prefix(limit); suffix = "\n(cut at 8 MB)\n" }
        return String(decoding: data, as: UTF8.self) + suffix
    }
}
