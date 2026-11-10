import AppKit
import Combine

/// The optional `menuBarShelf` module (P2-MENU-03 prototype). Off by default
/// and held off by restricted mode. Needs no permission: it only draws two
/// status items of its own. See `MenuBarShelf` for how recovery works.
@MainActor
final class MenuBarShelfModule: PortsideModule {
    static let moduleID = ModuleID("menuBarShelf")!
    static let toggleCommand = CommandID("menuBarShelf.toggle")!
    nonisolated static let collapseDelay: Duration = .seconds(1)

    let id = MenuBarShelfModule.moduleID
    let title = "Menu Bar Shelf"
    let summary = "Hides the menu bar items you choose and shows them again. An open eye in the menu bar means your items are showing and a crossed eye means they are hidden. Click it to show or hide, double-click or Option-click for Always Hidden, and right-click for Turn Off. Hold Command and drag an icon across the divider to change its section. macOS hides by app, so all of an app's items move together. Needs Portside installed in /Applications and Accessibility. If hiding fails, the bar stays as macOS drew it."
    let fallback = "Your menu bar stays exactly as macOS lays it out."

    private let shelf: MenuBarShelf
    private let triggers: MenuBarTriggerService
    private let settings: AnyPublisher<MenuBarTriggerSettings, Never>
    private let overlay = MenuBarStyleOverlay()

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
        let saved = settings.sink { [triggers, shelf, overlay] value in
            MainActor.assumeIsolated {
                triggers.apply(value)
                shelf.applyLook(value.look)
                overlay.apply(value.look)
            }
        }
        context.onStop { [overlay] in
            saved.cancel()
            MainActor.assumeIsolated { overlay.stop() }
        }
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
                    // An assertion is not tied to display geometry, so a
                    // collapsed bar stays collapsed across sleep and displays.
                    guard !shelf.hidesByMembership else {
                        triggers.displayChanged()
                        shelf.revalidate()
                        return
                    }
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
        let space = workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [triggers] _ in
            MainActor.assumeIsolated { triggers.spaceChanged() }
        }
        context.onStop { workspace.removeObserver(space) }
        // The bar starts collapsed. Shortly after launch, so the saved choices
        // are applied and login items have had a moment to appear.
        let collapse = Task { [triggers] in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled else { return }
            triggers.startCollapsed()
        }
        context.onStop { collapse.cancel() }
        context.onStop { [shelf, triggers] in
            MainActor.assumeIsolated {
                triggers.stop()
                shelf.stop()
            }
        }
    }
}
