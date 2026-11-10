import Foundation

/// Whether iPhone Live Activities appear in the menu bar. The one place
/// Portside edits `com.apple.controlcenter` (AGENTS.md rule 7 exception): this
/// one key, only when the user flips the switch, with a backup first.
/// MenuBarAgent watches the key, so a change applies at once.
@MainActor
final class MenuBarLiveActivities: ObservableObject {
    static let iPhoneKey = "RemoteLiveActivitiesEnabled"

    /// Nil when this macOS does not have the setting.
    @Published private(set) var iPhoneEnabled: Bool?

    private nonisolated static let domain = "com.apple.controlcenter"
    private let read: (String) -> Any?
    private let write: (String, Any) -> Void
    private let backupURL: URL

    init(
        read: @escaping (String) -> Any? = { CFPreferencesCopyAppValue($0 as CFString, MenuBarLiveActivities.domain as CFString) },
        write: @escaping (String, Any) -> Void = {
            CFPreferencesSetAppValue($0 as CFString, $1 as CFPropertyList, MenuBarLiveActivities.domain as CFString)
            CFPreferencesAppSynchronize(MenuBarLiveActivities.domain as CFString)
        },
        backupURL: URL = MenuBarControlImage.folder.appendingPathComponent("live-activities-backup.plist")
    ) {
        self.read = read
        self.write = write
        self.backupURL = backupURL
        refresh()
    }

    func refresh() {
        iPhoneEnabled = read(Self.iPhoneKey) as? Bool
    }

    func setIPhone(_ enabled: Bool) {
        guard iPhoneEnabled != nil, backUpOnce() else { return }
        write(Self.iPhoneKey, enabled)
        refresh()
    }

    /// The value from before Portside first changed the switch.
    private func backUpOnce() -> Bool {
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return true }
        guard let value = read(Self.iPhoneKey),
              let data = try? PropertyListSerialization.data(fromPropertyList: [Self.iPhoneKey: value], format: .xml, options: 0) else { return false }
        try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: backupURL, options: .atomic)) != nil
    }
}
