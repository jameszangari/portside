import Foundation

/// The always-on `portside` module: provides Portside's own commands (Open
/// Settings, dock hiding, About, Quit). It holds no resources; it exists so
/// built-in commands go through the same module gate as optional ones.
@MainActor
final class PortsideCoreModule: PortsideModule {
    static let moduleID = ModuleID("portside")!
    static let openSettingsCommand = CommandID("portside.openSettings")!
    static let toggleDockHidingCommand = CommandID("portside.toggleDockHiding")!
    static let showAboutCommand = CommandID("portside.showAbout")!
    static let quitCommand = CommandID("portside.quit")!

    let id = PortsideCoreModule.moduleID
    let title = "Portside"
    let isRequired = true
    let summary = "The dock, Settings and Portside's built-in commands. Always on."

    private let isStarting: () -> Bool
    private let openSettings: () -> Void
    private let toggleDockHiding: () -> Void
    private let showAbout: () -> Void
    private let quit: () -> Void

    /// `isStarting` is true until the Dock engine exists; `openSettings` shows the window.
    init(
        isStarting: @escaping () -> Bool,
        openSettings: @escaping () -> Void,
        toggleDockHiding: @escaping () -> Void = {},
        showAbout: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) {
        self.isStarting = isStarting
        self.openSettings = openSettings
        self.toggleDockHiding = toggleDockHiding
        self.showAbout = showAbout
        self.quit = quit
    }

    func commands() -> [CommandDescriptor] {
        let starting: () -> String? = { [isStarting] in isStarting() ? "Portside is still starting." : nil }
        return [
            CommandDescriptor(
                id: Self.openSettingsCommand,
                title: "Open Settings",
                keywords: ["preferences", "dock"],
                symbolName: "gearshape",
                unavailableReason: starting,
                handler: { [openSettings] _ in
                    openSettings()
                    return .success(nil)
                }
            ),
            CommandDescriptor(
                id: Self.toggleDockHidingCommand,
                title: "Toggle Dock Hiding",
                keywords: ["auto-hide", "autohide", "show", "hide"],
                symbolName: "dock.rectangle",
                unavailableReason: starting,
                handler: { [toggleDockHiding] _ in
                    toggleDockHiding()
                    return .success(nil)
                }
            ),
            CommandDescriptor(
                id: Self.showAboutCommand,
                title: "About Portside",
                keywords: ["version", "info"],
                symbolName: "info.circle",
                handler: { [showAbout] _ in
                    showAbout()
                    return .success(nil)
                }
            ),
            CommandDescriptor(
                id: Self.quitCommand,
                title: "Quit Portside",
                keywords: ["exit", "close"],
                symbolName: "power",
                handler: { [quit] _ in
                    quit()
                    return .success(nil)
                }
            ),
        ]
    }

    func start(_ context: ModuleContext) throws {}
}
