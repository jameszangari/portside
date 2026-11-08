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
    let summary = "Switch between running apps or their windows from the keyboard, most recently used first, with its own shortcut (default ⌥Tab, set in General > Keyboard). Tap it for the previous app; hold it and press Tab or Shift-Tab to choose, Down for a window, / to search window titles, then let go. Window previews are a separate opt-in that needs Screen Recording. Native ⌘Tab is unchanged."
    let fallback = "⌘Tab, the dock and Command Center still switch apps."
    /// A Carbon hotkey is not key interception, and it shows only app names,
    /// icons and window titles (titles only with Accessibility; without it,
    /// apps only).
    let isSensitive = false

    private let switcher: AppSwitcher
    private let chords: AnyPublisher<HotkeyChord?, Never>
    private let preferences: AnyPublisher<SwitcherPreferences, Never>

    /// `chords` publishes the saved shortcut and `preferences` the mode and
    /// search choice, current values first.
    init(switcher: AppSwitcher, chords: AnyPublisher<HotkeyChord?, Never>,
         preferences: AnyPublisher<SwitcherPreferences, Never> = Just(SwitcherPreferences()).eraseToAnyPublisher()) {
        self.switcher = switcher
        self.chords = chords
        self.preferences = preferences
    }

    func start(_ context: ModuleContext) throws {
        switcher.setEnabled(true)
        let subscription = chords.sink { [switcher] chord in
            MainActor.assumeIsolated { switcher.setHotkey(chord) }
        }
        let choices = preferences.sink { [switcher] preferences in
            MainActor.assumeIsolated { switcher.setPreferences(preferences) }
        }
        context.onStop { [switcher] in
            subscription.cancel()
            choices.cancel()
            MainActor.assumeIsolated { switcher.setEnabled(false) }
        }
    }
}
