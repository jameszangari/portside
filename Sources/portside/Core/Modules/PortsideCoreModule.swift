import Foundation

/// The always-on `portside` module: provides Portside's own commands, starting
/// with Open Settings. It holds no resources; it exists so built-in commands
/// go through the same module gate as optional ones.
@MainActor
final class PortsideCoreModule: PortsideModule {
    static let moduleID = ModuleID("portside")!
    static let openSettingsCommand = CommandID("portside.openSettings")!

    let id = PortsideCoreModule.moduleID
    let title = "Portside"
    let isRequired = true
    let summary = "The dock, Settings and Portside's built-in commands. Always on."

    private let isStarting: () -> Bool
    private let openSettings: () -> Void

    /// `isStarting` is true until the Dock engine exists; `openSettings` shows the window.
    init(isStarting: @escaping () -> Bool, openSettings: @escaping () -> Void) {
        self.isStarting = isStarting
        self.openSettings = openSettings
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.openSettingsCommand,
                title: "Open Settings",
                keywords: ["preferences", "dock"],
                unavailableReason: { [isStarting] in isStarting() ? "Portside is still starting." : nil },
                handler: { [openSettings] _ in
                    openSettings()
                    return .success(nil)
                }
            )
        ]
    }

    func start(_ context: ModuleContext) throws {}
}
