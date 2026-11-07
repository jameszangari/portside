import Combine
import Foundation

/// The optional `commandCenter` module. Off by default like every optional
/// module: until it is turned on in Settings > Integrations, no shortcut is
/// registered and the menu bar item is hidden. Running, it keeps the global
/// shortcut in step with `commandCenterHotkey`.
@MainActor
final class CommandCenterModule: PortsideModule {
    static let moduleID = ModuleID("commandCenter")!

    let id = CommandCenterModule.moduleID
    let title = "Command Center"
    let summary = "A search panel for Portside's commands, opened with a global shortcut (default ⌥Space, set in General > Keyboard)."
    let fallback = "Every command stays in the menu bar menu, the dock and Settings."
    /// A Carbon hotkey is not key interception and reads no data.
    let isSensitive = false

    private let center: CommandCenter
    private let chords: AnyPublisher<HotkeyChord?, Never>

    /// `chords` publishes the saved shortcut, current value first.
    init(center: CommandCenter, chords: AnyPublisher<HotkeyChord?, Never>) {
        self.center = center
        self.chords = chords
    }

    func start(_ context: ModuleContext) throws {
        center.setEnabled(true)
        let subscription = chords.sink { [center] chord in
            MainActor.assumeIsolated { center.setHotkey(chord) }
        }
        context.onStop { [center] in
            subscription.cancel()
            MainActor.assumeIsolated { center.setEnabled(false) }
        }
    }
}
