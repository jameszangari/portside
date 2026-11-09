import AppKit
import Combine

/// The optional `menuBarShelf` module (P2-MENU-03 prototype). Off by default
/// and held off by restricted mode. Needs no permission: it only draws two
/// status items of its own. See `MenuBarShelf` for how recovery works.
@MainActor
final class MenuBarShelfModule: PortsideModule {
    static let moduleID = ModuleID("menuBarShelf")!
    static let toggleCommand = CommandID("menuBarShelf.toggle")!

    let id = MenuBarShelfModule.moduleID
    let title = "Menu Bar Shelf (prototype)"
    let summary = "Adds a Portside control to the menu bar that hides the items to its left and shows them again. Prototype: items already clipped by the notch stay clipped, and it can fight another menu bar manager, so turn that one off first. It starts shown every launch, shows everything again on sleep, wake or a display change, and goes away completely when you turn it off or quit. The control shows an open eye while items are showing and a crossed eye while they are hidden. Click it, press an optional shortcut, and it can hide again by itself (Settings > Menu Bar > Show & Hide). Right-click the control for Turn Off."
    let fallback = "Your menu bar stays exactly as macOS lays it out."

    private let shelf: MenuBarShelf
    private let triggers: MenuBarTriggerService
    private let settings: AnyPublisher<MenuBarTriggerSettings, Never>

    /// `settings` publishes the saved trigger choices, current value first.
    init(shelf: MenuBarShelf, triggers: MenuBarTriggerService,
         settings: AnyPublisher<MenuBarTriggerSettings, Never> = Just(MenuBarTriggerSettings()).eraseToAnyPublisher()) {
        self.shelf = shelf
        self.triggers = triggers
        self.settings = settings
    }

    var mode: MenuBarShelf.Mode { shelf.mode }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.toggleCommand,
                title: "Hide or Show Menu Bar Items",
                keywords: ["shelf", "status", "menu extra", "bartender"],
                symbolName: "menubar.rectangle",
                handler: { [triggers] _ in
                    if case .refused(let reason) = triggers.activate(.command) {
                        return .failure(CommandFailure(reason: reason))
                    }
                    return .success(nil)
                }
            ),
        ]
    }

    func start(_ context: ModuleContext) throws {
        shelf.start()
        triggers.start(MenuBarTriggerSettings())
        let saved = settings.sink { [triggers] value in
            MainActor.assumeIsolated { triggers.apply(value) }
        }
        context.onStop { saved.cancel() }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let watched: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "the Mac went to sleep"),
            (workspace, NSWorkspace.didWakeNotification, "the Mac woke"),
            (workspace, NSWorkspace.screensDidWakeNotification, "the screens woke"),
            (center, NSApplication.didChangeScreenParametersNotification, "the displays changed"),
        ]
        for (source, name, reason) in watched {
            let token = source.addObserver(forName: name, object: nil, queue: .main) { [shelf, triggers] _ in
                MainActor.assumeIsolated {
                    triggers.cancelPending()
                    shelf.failOpen(reason)
                }
            }
            context.onStop { source.removeObserver(token) }
        }
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [triggers] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { triggers.appActivated(bundleID: bundleID) }
        }
        context.onStop { workspace.removeObserver(activation) }
        context.onStop { [shelf, triggers] in
            MainActor.assumeIsolated {
                triggers.stop()
                shelf.stop()
            }
        }
    }
}
