import AppKit

/// The optional `menuBarShelf` module (P2-MENU-03 prototype). Off by default
/// and held off by restricted mode. Needs no permission: it only draws two
/// status items of its own. See `MenuBarShelf` for how recovery works.
@MainActor
final class MenuBarShelfModule: PortsideModule {
    static let moduleID = ModuleID("menuBarShelf")!
    static let toggleCommand = CommandID("menuBarShelf.toggle")!

    let id = MenuBarShelfModule.moduleID
    let title = "Menu Bar Shelf (prototype)"
    let summary = "Adds a Portside control to the menu bar that hides the items to its left and shows them again. Prototype: items already clipped by the notch stay clipped, and it can fight another menu bar manager, so turn that one off first. It starts shown every launch, shows everything again on sleep, wake or a display change, and goes away completely when you turn it off or quit. Right-click the control for Turn Off."
    let fallback = "Your menu bar stays exactly as macOS lays it out."

    private let shelf: MenuBarShelf

    init(shelf: MenuBarShelf) {
        self.shelf = shelf
    }

    var mode: MenuBarShelf.Mode { shelf.mode }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.toggleCommand,
                title: "Hide or Show Menu Bar Items",
                keywords: ["shelf", "status", "menu extra", "bartender"],
                symbolName: "menubar.rectangle",
                handler: { [shelf] _ in
                    shelf.toggle()
                    return .success(nil)
                }
            ),
        ]
    }

    func start(_ context: ModuleContext) throws {
        shelf.start()
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let watched: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "the Mac went to sleep"),
            (workspace, NSWorkspace.didWakeNotification, "the Mac woke"),
            (workspace, NSWorkspace.screensDidWakeNotification, "the screens woke"),
            (center, NSApplication.didChangeScreenParametersNotification, "the displays changed"),
        ]
        for (source, name, reason) in watched {
            let token = source.addObserver(forName: name, object: nil, queue: .main) { [shelf] _ in
                MainActor.assumeIsolated { shelf.failOpen(reason) }
            }
            context.onStop { source.removeObserver(token) }
        }
        context.onStop { [shelf] in
            MainActor.assumeIsolated { shelf.stop() }
        }
    }
}
