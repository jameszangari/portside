import Combine
import Foundation

/// The optional `switcher` module. Off by default like every optional
/// module: until it is turned on in Settings > Integrations no shortcut is
/// registered and the window registry has no switcher client. Running, it
/// keeps the shortcut in step with `switcherHotkey`.
@MainActor
final class SwitcherModule: PortsideModule {
    static let moduleID = ModuleID("switcher")!

    let id = SwitcherModule.moduleID
    let title = "App Switcher"
    let summary = "Switch between running apps from the keyboard, most recently used first, with its own shortcut (default ⌥Tab, set in General > Keyboard). Tap it for the previous app; hold it and press Tab or Shift-Tab to choose, then let go. Native ⌘Tab is unchanged."
    let fallback = "⌘Tab, the dock and Command Center still switch apps."
    /// A Carbon hotkey is not key interception, and it shows only app names
    /// and icons. It works without Accessibility.
    let isSensitive = false

    private let switcher: AppSwitcher
    private let chords: AnyPublisher<HotkeyChord?, Never>

    /// `chords` publishes the saved shortcut, current value first.
    init(switcher: AppSwitcher, chords: AnyPublisher<HotkeyChord?, Never>) {
        self.switcher = switcher
        self.chords = chords
    }

    func start(_ context: ModuleContext) throws {
        switcher.setEnabled(true)
        let subscription = chords.sink { [switcher] chord in
            MainActor.assumeIsolated { switcher.setHotkey(chord) }
        }
        context.onStop { [switcher] in
            subscription.cancel()
            MainActor.assumeIsolated { switcher.setEnabled(false) }
        }
    }
}
