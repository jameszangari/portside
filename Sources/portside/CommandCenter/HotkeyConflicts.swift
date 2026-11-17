import Carbon.HIToolbox
import Combine
import Foundation

/// One entry of macOS's own keyboard shortcuts (System Settings > Keyboard >
/// Keyboard Shortcuts). `modifiers` are Carbon flags.
struct SymbolicHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool
}

/// Read-only conflict checks for a global shortcut. Nothing here changes a
/// system or another app's shortcut.
enum HotkeyConflicts {
    private static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    private static let spotlight = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))

    /// macOS's symbolic hotkeys through `CopySymbolicHotKeys` (public
    /// HIToolbox, read only). Empty if the call fails.
    static func systemHotkeys() -> [SymbolicHotkey] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let entries = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue ?? false
            return SymbolicHotkey(keyCode: code, modifiers: modifiers, enabled: enabled)
        }
    }

    /// Why `chord` may not work, or nil. `portside` lists Portside's other
    /// shortcuts by name. Only enabled system shortcuts count.
    static func conflict(
        for chord: HotkeyChord,
        system: [SymbolicHotkey],
        portside: [(name: String, chord: HotkeyChord?)]
    ) -> String? {
        if let owner = portside.first(where: { $0.chord == chord }) {
            return "\(chord.displayString) is already Portside's \(owner.name) shortcut. Choose another."
        }
        let taken = system.contains {
            $0.enabled && $0.keyCode == chord.keyCode && $0.modifiers & modifierMask == chord.modifiers & modifierMask
        }
        guard taken else { return nil }
        let owner = chord == spotlight ? "Spotlight's shortcut" : "an enabled macOS shortcut"
        return "\(chord.displayString) is \(owner), and macOS handles it first. Choose another, or turn it off in System Settings > Keyboard > Keyboard Shortcuts. Portside does not change it."
    }
}

/// Live Command Center state for Settings and the menu bar: whether the
/// module runs, and why macOS refused the shortcut (another app holding the
/// same chord makes Carbon refuse it).
final class CommandCenterStatus: ObservableObject {
    static let shared = CommandCenterStatus()
    @Published var isEnabled = false
    @Published var hotkeyFailure: String?
}

/// Owns one global shortcut and re-registers it when the chord changes.
/// The registrar is injectable so tests never touch Carbon.
@MainActor
final class CommandCenterHotkey {
    enum Status: Equatable {
        case off
        case registered(HotkeyChord)
        case failed(HotkeyChord)
    }

    typealias Registrar = (HotkeyChord, @escaping () -> Void) -> AnyObject?

    private(set) var status = Status.off
    private var registration: AnyObject?
    private let registrar: Registrar
    private let onPress: () -> Void
    private let report: (String?) -> Void

    nonisolated static let carbon: Registrar = { chord, action in
        HotKey(chord: chord, name: "Command Center \(chord.displayString)", action: action)
    }

    init(
        registrar: @escaping Registrar = CommandCenterHotkey.carbon,
        report: @escaping (String?) -> Void = { CommandCenterStatus.shared.hotkeyFailure = $0 },
        onPress: @escaping () -> Void
    ) {
        self.registrar = registrar
        self.report = report
        self.onPress = onPress
    }

    /// Idempotent per chord. nil (cleared in Settings) unregisters.
    func update(_ chord: HotkeyChord?) {
        switch status {
        case .registered(let current) where current == chord: return
        case .off where chord == nil: return
        default: break
        }
        // Release first: the same chord cannot be held twice.
        registration = nil
        guard let chord, chord.isRegisterable else {
            status = .off
            report(nil)
            return
        }
        registration = registrar(chord) { [onPress] in onPress() }
        if registration != nil {
            status = .registered(chord)
            report(nil)
        } else {
            status = .failed(chord)
            report("macOS refused \(chord.displayString). Another app may already use it. Choose another shortcut.")
        }
    }
}
