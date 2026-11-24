import AppKit

/// Settings > General > More > Copy Diagnostics: a plain-text report for
/// bug reports. Version, macOS, the main dock settings, module and
/// permission states, the native Dock backup, and reveal latency. No app
/// names, file contents, clipboard, calendar or agent data, and the home
/// folder is shown as `~`.
enum Diagnostics {
    struct Input {
        var versionLine = AppInfo.versionLine
        var macOS = ProcessInfo.processInfo.operatingSystemVersionString
        var bundlePath = Bundle.main.bundlePath
        var home = FileManager.default.homeDirectoryForCurrentUser.path
        var settings: [(String, String)]
        var modules: [IntegrationSettings.ModuleRow]
        var permissions: [IntegrationSettings.PermissionRow]
        var nativeDockBackup: Bool
        var revealLatency: String
    }

    static func report(_ input: Input) -> String {
        var lines = [
            "Portside diagnostics",
            input.versionLine,
            "macOS \(input.macOS)",
            "App: \(redact(input.bundlePath, home: input.home))\(input.bundlePath.hasSuffix(".app") ? "" : " (development copy)")",
            "",
            "Settings",
        ]
        lines += input.settings.map { "  \($0.0): \($0.1)" }
        lines += ["  native Dock backup: \(input.nativeDockBackup ? "present (hidden by Portside, or not yet restored)" : "none")", "", "Modules"]
        lines += input.modules.map { row in
            var parts = ["  \(row.id.rawValue): \(state(row.state))"]
            if !row.isEnabled { parts.append("off") }
            if row.isRestricted { parts.append("held by restricted mode") }
            return parts.joined(separator: ", ")
        }
        lines += ["", "Permissions"]
        lines += input.permissions.map { "  \($0.scope.description): \(String(describing: $0.state))" }
        lines += ["", input.revealLatency]
        return lines.joined(separator: "\n") + "\n"
    }

    static func redact(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func state(_ state: ModuleState) -> String {
        switch state {
        case .disabled: "disabled"
        case .running: "running"
        case .waiting(let reason): "waiting (\(reason))"
        case .failed(let reason): "failed (\(reason))"
        }
    }

    @MainActor static func settings(_ model: DockModel) -> [(String, String)] {
        [
            ("edge", model.edge.rawValue),
            ("auto-hide", "\(model.autoHide)"),
            ("hide the macOS Dock", "\(model.hideNativeDock)"),
            ("reveal delay", String(format: "%.2f s", model.revealDelay)),
            ("hide delay", String(format: "%.2f s", model.hideDelay)),
            ("icon size", "\(Int(model.iconSize))"),
            ("magnification", "\(model.magnificationEnabled)"),
            ("widgets", "\(model.widgetKinds.count)"),
            ("Top Notch", "\(model.showAgentNotch)"),
            ("restricted mode", "\(model.restrictedMode)"),
            ("screens", "\(NSScreen.screens.count)"),
        ]
    }

    @MainActor static func text(model: DockModel, integrations: IntegrationSettings) -> String {
        integrations.reload()
        return report(Input(
            settings: settings(model),
            modules: integrations.modules,
            permissions: integrations.permissions,
            nativeDockBackup: NativeDock.backupExists,
            revealLatency: RevealLatency.shared.summary
        ))
    }

    @MainActor static func copy(model: DockModel, integrations: IntegrationSettings) {
        let text = text(model: model, integrations: integrations)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
