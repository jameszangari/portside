import AppKit
import OSLog

/// A named set of apps, shown as one row in the Portside Bar. `showsIcon` adds
/// a menu bar icon that opens just this group.
struct MenuBarGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var bundles: [String] = []
    var showsIcon = false
}

/// A saved arrangement: sections, order, groups and Always Hidden. `displayKey`
/// makes it apply itself whenever that set of displays is connected.
struct MenuBarProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var assignments: [String: String] = [:]
    var order: [String: [String]] = [:]
    var groups: [MenuBarGroup] = []
    var alwaysHidden = false
    var displayKey: String?
    var hotkey: HotkeyChord?
}

/// Arrangement state beyond the section map, in Portside's own defaults.
struct MenuBarArrangementStore {
    static let orderKey = "menuBarLayout.order"
    static let groupsKey = "menuBarLayout.groups"
    static let profilesKey = "menuBarLayout.profiles"
    static let activeProfileKey = "menuBarLayout.activeProfile"
    static let knownOwnersKey = "menuBarLayout.knownOwners"
    static let menuBarOnlyKey = "menuBarLayout.menuBarOnly"
    /// Answer only a real click on a drawn icon, or get stuck when pressed hidden.
    static let knownMenuBarOnly: Set<String> = ["com.malwarebytes.mbam.frontend.agent", "com.portkiller.app", "com.sattlerjoshua.bettercapture"]

    let defaults: UserDefaults

    /// Bundles left to right, per section.
    var order: [MenuBarSection: [String]] {
        get {
            let raw = defaults.dictionary(forKey: Self.orderKey) as? [String: [String]] ?? [:]
            var out: [MenuBarSection: [String]] = [:]
            for (key, value) in raw { if let section = MenuBarSection(rawValue: key) { out[section] = value } }
            return out
        }
        nonmutating set {
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }), forKey: Self.orderKey)
        }
    }

    var groups: [MenuBarGroup] {
        get { decode(Self.groupsKey) ?? [] }
        nonmutating set { encode(newValue, Self.groupsKey) }
    }

    var profiles: [MenuBarProfile] {
        get { decode(Self.profilesKey) ?? [] }
        nonmutating set { encode(newValue, Self.profilesKey) }
    }

    var activeProfileID: UUID? {
        get { defaults.string(forKey: Self.activeProfileKey).flatMap(UUID.init) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Self.activeProfileKey) }
    }

    /// Bundles that have ever drawn an item, so a truly new one can be placed.
    var knownOwners: Set<String>? {
        get { (defaults.array(forKey: Self.knownOwnersKey) as? [String]).map(Set.init) }
        nonmutating set { defaults.set(newValue.map { Array($0).sorted() }, forKey: Self.knownOwnersKey) }
    }

    func opensOnlyFromMenuBar(_ bundle: String) -> Bool {
        Self.knownMenuBarOnly.contains(bundle) || (defaults.stringArray(forKey: Self.menuBarOnlyKey) ?? []).contains(bundle)
    }

    func markMenuBarOnly(_ bundle: String) {
        let known = Set(defaults.stringArray(forKey: Self.menuBarOnlyKey) ?? []).union([bundle])
        defaults.set(known.sorted(), forKey: Self.menuBarOnlyKey)
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// Turns a desired left-to-right order into new weights for the position
/// table. Pure. A weight is an item's distance from the trailing edge, so a
/// bigger weight sits further left. Only the existing numbers are reshuffled,
/// so items not taking part keep their places.
enum MenuBarOrderPlanner {
    static let prefix = "status:"

    /// `status:<bundle>::<name>` to the lowercased bundle, nil for anything else.
    static func bundle(ofKey key: String) -> String? {
        guard key.hasPrefix(prefix), let range = key.range(of: "::") else { return nil }
        return String(key[key.index(key.startIndex, offsetBy: prefix.count)..<range.lowerBound]).lowercased()
    }

    /// Each bundle's keys, left to right as they stand.
    static func keysByBundle(_ table: [String: Int]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for key in table.keys.sorted(by: { (table[$0]!, $0) > (table[$1]!, $1) }) {
            if let bundle = bundle(ofKey: key) { out[bundle, default: []].append(key) }
        }
        return out
    }

    /// `desired` holds bundles, or literal keys for Portside's dividers, left
    /// to right. Returns only the keys whose weight must change.
    static func changes(table: [String: Int], desired: [String]) -> [String: Int] {
        let byBundle = keysByBundle(table)
        var keys: [String] = []
        for entry in desired {
            if entry.hasPrefix(prefix) {
                if table[entry] != nil { keys.append(entry) }
            } else {
                keys.append(contentsOf: byBundle[entry] ?? [])
            }
        }
        var seen = Set<String>()
        keys = keys.filter { seen.insert($0).inserted }
        let pool = keys.map { table[$0]! }.sorted(by: >)
        var out: [String: Int] = [:]
        for (key, weight) in zip(keys, pool) where table[key] != weight { out[key] = weight }
        return out
    }

    /// Bundles left to right per the table, for recording what the bar shows.
    static func observedOrder(table: [String: Int], members: Set<String>) -> [String] {
        var out: [String] = []
        for key in table.keys.sorted(by: { (table[$0]!, $0) > (table[$1]!, $1) }) {
            if let bundle = bundle(ofKey: key), members.contains(bundle), !out.contains(bundle) { out.append(bundle) }
        }
        return out
    }
}

/// What restoring order needs from MenuBarAgent's table. Tests inject a fake.
@MainActor
protocol MenuBarPositionStoring: AnyObject {
    func read() -> [String: Int]?
    /// Applies the changed weights. False when nothing was written.
    func write(_ changes: [String: Int]) -> Bool
    /// Puts back the order from before Portside's first write.
    @discardableResult func restoreBackup() -> Bool
    /// Makes MenuBarAgent pick up what was written. It reads the table only
    /// when it starts, so this relaunches it, and the bar blinks once.
    func reload()
}

extension MenuBarPositionStoring {
    @discardableResult func restoreBackup() -> Bool { false }
    func reload() {}
}

/// MenuBarAgent's saved order, `TrailingItemPreferredPositions`, in
/// `com.apple.MenuBar.plist`. Readable and writable only after the user grants
/// that file. A copy from before the first write is kept next to Portside's
/// settings, so `restoreBackup` can undo everything.
@MainActor
final class MenuBarPositionTable: MenuBarPositionStoring {
    static let key = "TrailingItemPreferredPositions"
    private let grant: MenuBarFileGrant
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-table")

    init(grant: MenuBarFileGrant) { self.grant = grant }

    private var backupURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("com.james.portside")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("menu-bar-order-backup.plist")
    }

    func read() -> [String: Int]? {
        grant.read()?[Self.key] as? [String: Int]
    }

    func write(_ changes: [String: Int]) -> Bool {
        guard !changes.isEmpty, var table = read() else { return false }
        if !FileManager.default.fileExists(atPath: backupURL.path), let data = try? Data(contentsOf: grant.fileURL) {
            try? data.write(to: backupURL)
        }
        table.merge(changes) { _, new in new }
        return store(table)
    }

    func reload() { MenuBarSystemProcess.killall("MenuBarAgent") }

    /// Puts back the order from before Portside's first write.
    @discardableResult
    func restoreBackup() -> Bool {
        guard let data = try? Data(contentsOf: backupURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let table = plist[Self.key] as? [String: Int] else { return false }
        return store(table)
    }

    private func store(_ table: [String: Int]) -> Bool {
        let path = grant.fileURL.deletingPathExtension().path as CFString
        CFPreferencesSetValue(Self.key as CFString, table as CFDictionary, path, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if CFPreferencesSynchronize(path, kCFPreferencesCurrentUser, kCFPreferencesAnyHost), read() == table { return true }
        // The preferences daemon cannot always reach a group container.
        guard var plist = grant.read() else { return false }
        plist[Self.key] = table
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              (try? data.write(to: grant.fileURL, options: .atomic)) != nil else {
            log.error("could not write the menu bar order")
            return false
        }
        return read() == table
    }
}

/// macOS's own per-app switch (System Settings > Menu Bar), Control Center's
/// `trackedApplications`. Unlike the assertion this outlives Portside, so every
/// switch it turns off is journaled first and turned back on at reveal, quit
/// or the next launch.
@MainActor
final class MenuBarNativeHider {
    static let key = "trackedApplications"
    private let grant: MenuBarFileGrant
    private let restartControlCenter: () -> Void

    init(grant: MenuBarFileGrant, restartControlCenter: @escaping () -> Void = { MenuBarSystemProcess.killall("ControlCenter") }) {
        self.grant = grant
        self.restartControlCenter = restartControlCenter
    }

    var isAvailable: Bool { grant.isGranted && decodedList() != nil }

    private var journalURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("com.james.portside")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("menu-bar-native-journal.json")
    }

    private var journal: Set<String> {
        get { (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? [] }
        set {
            if newValue.isEmpty {
                try? FileManager.default.removeItem(at: journalURL)
            } else if let data = try? JSONEncoder().encode(newValue) {
                try? data.write(to: journalURL, options: .atomic)
            }
        }
    }

    private func decodedList() -> [Any]? {
        guard let data = grant.read()?[Self.key] as? Data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any]
    }

    /// Turns off exactly `bundles`, and back on anything Portside turned off
    /// earlier. Switches the user turned off themselves are never touched.
    /// Returns the bundles macOS has no record of. Nil when the list is unusable.
    @discardableResult
    func setHidden(_ bundles: Set<String>) -> Set<String>? {
        guard let list = decodedList() else { return nil }
        let result = MenuBarNativeList.applying(list: list, hide: bundles, previouslyHiddenByUs: journal)
        journal = result.nowHiddenByUs
        guard result.changed else { return result.untracked }
        guard save(result.list) else { return nil }
        restartControlCenter()
        return result.untracked
    }

    /// Undoes a hide left by a crash. Safe to call when nothing is pending.
    func recover() {
        if !journal.isEmpty { setHidden([]) }
    }

    private func save(_ list: [Any]) -> Bool {
        let backup = journalURL.deletingLastPathComponent().appendingPathComponent("menu-bar-app-list-backup.plist")
        if !FileManager.default.fileExists(atPath: backup.path), let original = try? Data(contentsOf: grant.fileURL) { try? original.write(to: backup) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0), var plist = grant.read() else { return false }
        plist[Self.key] = data
        let path = grant.fileURL.deletingPathExtension().path as CFString
        CFPreferencesSetValue(Self.key as CFString, data as CFData, path, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if CFPreferencesSynchronize(path, kCFPreferencesCurrentUser, kCFPreferencesAnyHost), (grant.read()?[Self.key] as? Data) == data { return true }
        guard let file = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return false }
        return (try? file.write(to: grant.fileURL, options: .atomic)) != nil
    }
}

/// The pure edit of Control Center's list: entries alternate between a
/// location and a record with `isAllowed`.
enum MenuBarNativeList {
    struct Result {
        var list: [Any]
        var changed: Bool
        var nowHiddenByUs: Set<String>
        var untracked: Set<String>
    }

    static func bundle(ofRecord record: [String: Any]) -> String? {
        ((record["location"] as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }

    static func applying(list: [Any], hide: Set<String>, previouslyHiddenByUs: Set<String>) -> Result {
        var out = list
        var changed = false
        var ours = previouslyHiddenByUs
        var seen = Set<String>()
        for (index, entry) in list.enumerated() {
            guard var record = entry as? [String: Any], let id = bundle(ofRecord: record)?.lowercased(), let allowed = record["isAllowed"] as? Bool else { continue }
            seen.insert(id)
            if hide.contains(id), allowed {
                record["isAllowed"] = false
                ours.insert(id)
            } else if !hide.contains(id), !allowed, ours.contains(id) {
                record["isAllowed"] = true
                ours.remove(id)
            } else {
                continue
            }
            out[index] = record
            changed = true
        }
        return Result(list: out, changed: changed, nowHiddenByUs: ours, untracked: hide.subtracting(seen))
    }
}

/// Relaunching a system agent: launchd brings it straight back.
enum MenuBarSystemProcess {
    nonisolated static func killall(_ name: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = [name]
        try? task.run()
    }
}

/// The display set a profile can follow.
enum MenuBarDisplaySet {
    @MainActor static var current: String {
        NSScreen.screens.map { "\($0.localizedName)#\(Int($0.frame.width))x\(Int($0.frame.height))" }.sorted().joined(separator: ",")
    }
}
