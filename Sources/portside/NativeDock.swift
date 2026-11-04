import AppKit
import os

/// Hides the native Dock with the autohide-delay trick and restores it
/// exactly. No UI and no private APIs: reads and writes go through public
/// CFPreferences on the `com.apple.dock` domain, and the Dock is restarted
/// with `killall Dock` so it rereads them.
///
/// Safety model:
/// - Before the first write, the exact prior values (or "did not exist") of
///   every key in `savedKeys` go to `native-dock-backup.json`.
/// - An existing backup is never overwritten. It is the only record of the
///   user's real settings until a restore succeeds and deletes it.
/// - Any backup found at launch means the Dock may still be hidden by a
///   Portside that crashed or was killed, so it is restored first.
enum NativeDock {
    static let domain = "com.apple.dock" as CFString

    /// Keys saved before hiding and put back on restore. Only `touchedKeys`
    /// are ever written while hiding; the rest are saved so restore can
    /// prove (and if needed force) an exact match.
    static let savedKeys = [
        "autohide", "autohide-delay", "autohide-time-modifier", "orientation",
        "tilesize", "magnification", "largesize", "show-recents",
    ]
    static let touchedKeys = ["autohide", "autohide-delay"]

    /// Seconds before the native Dock reveals (about 11.5 days).
    static let hiddenDelay: Double = 1_000_000

    /// A prior delay at or above this means another app (or a crashed
    /// Portside) already hid the Dock this way. Saving that as the "real"
    /// value would make restore keep the Dock hidden, so hiding refuses.
    static let suspiciousDelay: Double = 1_000

    static let logger = Logger(subsystem: "com.james.portside", category: "NativeDock")

    // MARK: - Errors

    enum Failure: LocalizedError {
        case unreadableBackup(String)
        case unrestoredBackup
        case alreadyHiddenElsewhere(Double)
        case unsupportedValue(String)
        case backupWrite(String)
        case synchronize
        case dockRestart(String)
        case verify(String)

        var errorDescription: String? {
            switch self {
            case .unreadableBackup(let detail):
                return "The native Dock backup could not be read (\(detail)). It was left in place at \(NativeDock.backupURL.path)."
            case .unrestoredBackup:
                return "A native Dock backup that has not been restored already exists. Restore it first (menu bar: Restore macOS Dock)."
            case .alreadyHiddenElsewhere(let delay):
                return "The native Dock already has autohide-delay = \(delay), so something else is hiding it. Reset it first: defaults delete com.apple.dock autohide-delay; killall Dock"
            case .unsupportedValue(let key):
                return "com.apple.dock \(key) has an unexpected type."
            case .backupWrite(let detail):
                return "Could not save the native Dock backup: \(detail)"
            case .synchronize:
                return "Could not save com.apple.dock preferences."
            case .dockRestart(let detail):
                return "Could not restart the Dock: \(detail)"
            case .verify(let detail):
                return "Dock settings did not read back as expected: \(detail)"
            }
        }
    }

    // MARK: - Values

    /// One preference value with its exact plist type, so restore writes a
    /// bool as a bool and a real as a real (`defaults read` output matches).
    enum Value: Equatable {
        case bool(Bool)
        case integer(Int64)
        case real(Double)
        case string(String)
        /// Anything else (arrays, dicts, data), as a base64 binary plist.
        case plist(String)

        init(_ object: CFPropertyList) throws {
            let type = CFGetTypeID(object)
            if type == CFBooleanGetTypeID() {
                self = .bool(CFBooleanGetValue((object as! CFBoolean)))
            } else if type == CFNumberGetTypeID() {
                let number = object as! NSNumber
                self = CFNumberIsFloatType((object as! CFNumber)) ? .real(number.doubleValue) : .integer(number.int64Value)
            } else if type == CFStringGetTypeID() {
                self = .string(object as! String)
            } else {
                let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
                self = .plist(data.base64EncodedString())
            }
        }

        func propertyList() throws -> CFPropertyList {
            switch self {
            case .bool(let value): return (value ? kCFBooleanTrue : kCFBooleanFalse) as CFBoolean
            case .integer(let value): return NSNumber(value: value)
            case .real(let value): return NSNumber(value: value)
            case .string(let value): return value as NSString
            case .plist(let base64):
                guard let data = Data(base64Encoded: base64) else { throw Failure.unreadableBackup("bad plist value") }
                return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as CFPropertyList
            }
        }

        var description: String {
            switch self {
            case .bool(let value): return "bool \(value)"
            case .integer(let value): return "integer \(value)"
            case .real(let value): return "real \(value)"
            case .string(let value): return "string \(value)"
            case .plist: return "plist"
            }
        }
    }

    // MARK: - Backup file

    struct Backup: Codable {
        enum State: String, Codable {
            /// Backup saved, writes may have started. Restore is still safe:
            /// it only puts back the values saved here.
            case applying
            /// Hidden and verified.
            case hidden
        }

        struct Entry: Codable {
            let key: String
            /// nil = the key did not exist; restore deletes it.
            let value: Value?

            private enum CodingKeys: String, CodingKey { case key, existed, type, value }

            init(key: String, value: Value?) {
                self.key = key
                self.value = value
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                key = try c.decode(String.self, forKey: .key)
                guard try c.decode(Bool.self, forKey: .existed) else {
                    value = nil
                    return
                }
                switch try c.decode(String.self, forKey: .type) {
                case "bool": value = .bool(try c.decode(Bool.self, forKey: .value))
                case "integer": value = .integer(try c.decode(Int64.self, forKey: .value))
                case "real": value = .real(try c.decode(Double.self, forKey: .value))
                case "string": value = .string(try c.decode(String.self, forKey: .value))
                case "plist": value = .plist(try c.decode(String.self, forKey: .value))
                case let other:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(key, forKey: .key)
                try c.encode(value != nil, forKey: .existed)
                switch value {
                case nil: break
                case .bool(let v): try c.encode("bool", forKey: .type); try c.encode(v, forKey: .value)
                case .integer(let v): try c.encode("integer", forKey: .type); try c.encode(v, forKey: .value)
                case .real(let v): try c.encode("real", forKey: .type); try c.encode(v, forKey: .value)
                case .string(let v): try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
                case .plist(let v): try c.encode("plist", forKey: .type); try c.encode(v, forKey: .value)
                }
            }
        }

        var version = 1
        var state: State
        var createdAt: Date
        var entries: [Entry]
    }

    static var backupURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return directory
            .appendingPathComponent("com.james.portside")
            .appendingPathComponent("native-dock-backup.json")
    }

    static var backupExists: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    /// nil when there is no backup. Throws when one exists but cannot be
    /// decoded, so callers never mistake a damaged backup for "none".
    static func loadBackup() throws -> Backup? {
        guard backupExists else { return nil }
        do {
            let data = try Data(contentsOf: backupURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Backup.self, from: data)
        } catch {
            throw Failure.unreadableBackup(error.localizedDescription)
        }
    }

    private static func writeBackup(_ backup: Backup) throws {
        do {
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backup).write(to: backupURL, options: .atomic)
        } catch {
            throw Failure.backupWrite(error.localizedDescription)
        }
    }

    // MARK: - Preferences

    static func read(_ key: String) throws -> Value? {
        guard let object = CFPreferencesCopyAppValue(key as CFString, domain) else { return nil }
        do {
            return try Value(object)
        } catch {
            throw Failure.unsupportedValue(key)
        }
    }

    /// nil deletes the key.
    private static func write(_ key: String, _ value: Value?) throws {
        CFPreferencesSetAppValue(key as CFString, try value?.propertyList(), domain)
        logger.info("write \(key, privacy: .public) = \(value?.description ?? "(deleted)", privacy: .public)")
    }

    private static func synchronize() throws {
        guard CFPreferencesAppSynchronize(domain) else {
            logger.error("CFPreferencesAppSynchronize failed")
            throw Failure.synchronize
        }
    }

    /// The Dock only rereads these keys at launch. launchd restarts it.
    private static func restartDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("killall Dock could not run: \(error.localizedDescription, privacy: .public)")
            throw Failure.dockRestart(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            logger.info("killall Dock: ok")
            return
        }
        // Exit 1 = no Dock process. If the Dock is mid-relaunch it reads the
        // new values when it comes up, which is what a restart is for.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty {
            logger.info("killall Dock: no Dock running (status \(process.terminationStatus)); it reads the new values when launchd starts it")
            return
        }
        logger.error("killall Dock failed with status \(process.terminationStatus)")
        throw Failure.dockRestart("killall exited with status \(process.terminationStatus)")
    }

    /// True when the current values are the ones `hide()` writes.
    static func looksHidden() -> Bool {
        guard case .bool(true)? = try? read("autohide") else { return false }
        switch try? read("autohide-delay") {
        case .real(let delay)?: return delay == hiddenDelay
        case .integer(let delay)?: return Double(delay) == hiddenDelay
        default: return false
        }
    }

    // MARK: - Watchdog

    private static var watchdog: Process?

    /// Starts a small child process (`portside --watch-native-dock <pid>`)
    /// that outlives a crash or `kill -9`: signal handlers cannot run then, so
    /// without it the Dock stays hidden, showing only in App Expose, until
    /// Portside opens again. Started when the Dock gets hidden.
    static func startWatchdog() {
        guard watchdog?.isRunning != true, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--watch-native-dock", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdog = process
            logger.info("watchdog started, pid \(process.processIdentifier)")
        } catch {
            logger.error("watchdog did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The child's side: waits for `pid` to exit, then restores if a backup is
    /// still there. A clean quit already restored and removed it.
    static func runWatchdog(watching pid: pid_t) -> Never {
        // Same process group as a terminal launch: Ctrl+C must not end this first.
        for number in [SIGINT, SIGHUP, SIGTERM] { signal(number, SIG_IGN) }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let finish: () -> Never = {
            if backupExists {
                logger.notice("watchdog: Portside (pid \(pid)) exited without restoring")
                recoverIfNeeded()
            }
            exit(0)
        }
        source.setEventHandler { finish() }
        source.resume()
        // It may have gone before the source was armed.
        if kill(pid, 0) != 0 { finish() }
        dispatchMain()
    }

    // MARK: - Hide

    /// Save the backup, then hide. On any failure after the backup is
    /// written, rolls back with `restore()` and rethrows, so the caller can
    /// leave the setting off.
    static func hide() throws {
        logger.info("hide: start")
        if let existing = try loadBackup() {
            if existing.state == .hidden && looksHidden() {
                logger.info("hide: already hidden by Portside (backup from \(existing.createdAt.description, privacy: .public))")
                return
            }
            logger.error("hide: refusing, an unrestored backup exists (state \(existing.state.rawValue, privacy: .public))")
            throw Failure.unrestoredBackup
        }

        var entries: [Backup.Entry] = []
        for key in savedKeys {
            let value = try read(key)
            logger.info("hide: saved \(key, privacy: .public) = \(value?.description ?? "(not set)", privacy: .public)")
            entries.append(Backup.Entry(key: key, value: value))
        }
        switch entries.first(where: { $0.key == "autohide-delay" })?.value {
        case .real(let delay)? where delay >= suspiciousDelay:
            throw Failure.alreadyHiddenElsewhere(delay)
        case .integer(let delay)? where Double(delay) >= suspiciousDelay:
            throw Failure.alreadyHiddenElsewhere(Double(delay))
        default:
            break
        }

        var backup = Backup(state: .applying, createdAt: Date(), entries: entries)
        try writeBackup(backup)
        // Read it back before touching anything: a backup that cannot be
        // decoded is no backup.
        guard (try? loadBackup())?.entries.count == entries.count else {
            try? FileManager.default.removeItem(at: backupURL)
            throw Failure.backupWrite("backup did not read back")
        }
        logger.info("hide: backup written to \(backupURL.path, privacy: .public)")

        do {
            try write("autohide", .bool(true))
            try write("autohide-delay", .real(hiddenDelay))
            try synchronize()
            try restartDock()
            guard looksHidden() else {
                throw Failure.verify("autohide = \(String(describing: try? read("autohide"))), autohide-delay = \(String(describing: try? read("autohide-delay")))")
            }
            backup.state = .hidden
            try writeBackup(backup)
            logger.info("hide: done, verified autohide = true and autohide-delay = \(hiddenDelay, format: .fixed(precision: 0))")
        } catch {
            logger.error("hide: failed (\(error.localizedDescription, privacy: .public)), rolling back")
            do {
                try restore()
            } catch {
                logger.error("hide: rollback failed (\(error.localizedDescription, privacy: .public)); backup kept for the next launch")
            }
            throw error
        }
    }

    // MARK: - Restore

    enum RestoreResult {
        case restored
        case nothingToRestore
    }

    /// Put every saved key back exactly (deleting keys that did not exist),
    /// restart the Dock, verify, then delete the backup. The backup is kept
    /// on any failure so a later restore can try again.
    @discardableResult
    static func restore() throws -> RestoreResult {
        guard let backup = try loadBackup() else {
            logger.info("restore: no backup, nothing to restore")
            return .nothingToRestore
        }
        logger.info("restore: start (backup state \(backup.state.rawValue, privacy: .public), from \(backup.createdAt.description, privacy: .public))")

        for entry in backup.entries {
            let current = try? read(entry.key)
            if current == entry.value {
                logger.info("restore: \(entry.key, privacy: .public) already \(entry.value?.description ?? "(not set)", privacy: .public)")
                continue
            }
            if !touchedKeys.contains(entry.key) {
                // Portside never writes these, so the user or the system
                // changed it while hidden. Restoring exactly wins.
                logger.notice("restore: \(entry.key, privacy: .public) changed while hidden (\(current?.description ?? "(not set)", privacy: .public)), putting back the saved value")
            }
            try write(entry.key, entry.value)
        }
        try synchronize()
        try restartDock()

        let mismatches = backup.entries.filter { (try? read($0.key)) != $0.value }.map(\.key)
        guard mismatches.isEmpty else {
            logger.error("restore: verify failed for \(mismatches.joined(separator: ", "), privacy: .public); backup kept")
            throw Failure.verify(mismatches.joined(separator: ", "))
        }
        try FileManager.default.removeItem(at: backupURL)
        logger.info("restore: done, all \(backup.entries.count) keys verified, backup removed")
        return .restored
    }

    /// Launch-time crash recovery. Any backup means a previous run may have
    /// left the Dock hidden ("applying" or "hidden"), so restore it before
    /// anything else runs.
    static func recoverIfNeeded() {
        guard backupExists else { return }
        logger.notice("launch: found a native Dock backup from a previous run, restoring")
        do {
            try restore()
        } catch {
            logger.error("launch: restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
