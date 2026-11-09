import AppKit
import Combine

/// State and actions behind Settings > Integrations: the registered modules,
/// the permissions they need, and the restricted work-Mac preset. Reads live
/// state from `ModuleRegistry` and `PermissionGate` on `reload` only (pane
/// shown, Portside active again, after an action); nothing polls. Requests
/// a permission only from `request`, which a button calls. Main actor only.
@MainActor
final class IntegrationSettings: ObservableObject {
    struct ModuleRow: Identifiable, Equatable {
        let id: ModuleID
        let title: String
        let summary: String
        let fallback: String
        let isRequired: Bool
        let isSensitive: Bool
        /// The user's choice (always true for required modules).
        let isEnabled: Bool
        let state: ModuleState
        let permissions: [PermissionScope]
        /// Off, and kept off, by the restricted preset.
        let isRestricted: Bool

        /// Whether the switch can be flipped from here.
        var canToggle: Bool { !isRequired && !isRestricted }
    }

    struct PermissionRow: Identifiable, Equatable {
        let scope: PermissionScope
        let state: PermissionState
        /// The adapter can start a request and the OS has not already
        /// allowed or ruled it out.
        let canRequest: Bool
        /// Titles of the registered modules that depend on this scope.
        let usedBy: [String]

        var id: String { scope.description }
    }

    @Published private(set) var modules: [ModuleRow] = []
    @Published private(set) var permissions: [PermissionRow] = []
    @Published private(set) var restricted = false

    /// Local Intelligence status for its section; nil hides the section.
    let intelligence: ModelRouter?

    private let registry: ModuleRegistry
    private let gate: PermissionGate
    private let model: DockModel

    init(registry: ModuleRegistry, permissions: PermissionGate, model: DockModel, intelligence: ModelRouter? = nil) {
        self.registry = registry
        self.gate = permissions
        self.model = model
        self.intelligence = intelligence
        reload()
    }

    /// Re-reads permissions, lets the registry start or stop modules whose
    /// dependencies changed, and rebuilds the rows.
    func reload() {
        registry.refresh()
        restricted = model.restrictedMode
        let all = registry.modules
        modules = all.map { module in
            let held = restricted && !module.isRequired && module.isSensitive
            return ModuleRow(
                id: module.id,
                title: module.title,
                summary: module.summary,
                fallback: module.fallback,
                isRequired: module.isRequired,
                isSensitive: module.isSensitive,
                isEnabled: module.isRequired || registry.isEnabled(module.id),
                state: registry.state(of: module.id) ?? .disabled,
                permissions: module.dependencies.compactMap {
                    if case .permission(let scope) = $0 { return scope }
                    return nil
                },
                isRestricted: held
            )
        }
        // Registered scopes, then any a module needs that nothing registered
        // (shown as unavailable rather than hidden).
        var scopes = gate.scopes
        for module in all {
            for case .permission(let scope) in module.dependencies where !scopes.contains(scope) { scopes.append(scope) }
        }
        permissions = scopes.map { scope in
            let state = gate.state(of: scope)
            return PermissionRow(
                scope: scope,
                state: state,
                canRequest: gate.canRequest(scope) && state.isRequestable,
                usedBy: all.filter { $0.dependencies.contains(.permission(scope)) }.map(\.title)
            )
        }
    }

    /// Turns an optional module on or off, saves the choice, and starts or
    /// stops it. Turning off cancels its tasks and releases its resources
    /// (the registry closes its context). Required modules and modules the
    /// restricted preset holds off are left alone.
    func setEnabled(_ enabled: Bool, for id: ModuleID) {
        guard let module = registry.modules.first(where: { $0.id == id }), !module.isRequired else { return }
        if enabled && restricted && module.isSensitive { return }
        model.setModuleEnabled(id, enabled)
        if enabled { registry.enable(id) } else { registry.disable(id) }
        reload()
    }

    /// The restricted work-Mac preset. On: every sensitive optional module is
    /// turned off and saved off, and stays off until the preset is turned
    /// off and the user turns it back on. Off: nothing is turned on. Never
    /// changes macOS security, privacy or managed settings.
    func setRestricted(_ on: Bool) {
        model.setRestrictedMode(on)
        if on {
            for module in registry.modules where !module.isRequired && module.isSensitive {
                if model.modules.savedEnabled(module.id) == true { model.setModuleEnabled(module.id, false) }
                registry.disable(module.id)
            }
        }
        reload()
    }

    /// Permissions a request could still change, in Settings order. The
    /// setup row walks these one at a time, because macOS allows only you to
    /// turn each one on and stacked system dialogs hide each other.
    var missingPermissions: [PermissionRow] { permissions.filter(\.canRequest) }

    /// Explicit user action (a button). Starts the OS or adapter request,
    /// then re-reads; a grant that lands later shows on the next reload.
    func request(_ scope: PermissionScope) {
        let users = registry.modules.filter { $0.dependencies.contains(.permission(scope)) }.map(\.title)
        let feature = users.isEmpty ? "Portside features that use it" : users.joined(separator: ", ")
        gate.request(scope, forFeature: feature)
        reload()
    }
}

extension PermissionState {
    /// Short status for Settings.
    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notRequested: return "Not requested"
        case .unavailable: return "Unavailable"
        case .restrictedOrUnknown: return "Unknown"
        }
    }

    /// One line under the status. No managed-policy diagnosis: macOS does
    /// not say why a permission is unavailable.
    var detail: String {
        switch self {
        case .granted: return "Allowed in System Settings."
        case .denied: return "Not allowed yet, or turned off in System Settings > Privacy & Security."
        case .notRequested: return "Portside has not asked for this yet. It asks only when you press Request."
        case .unavailable: return "Unavailable on this Mac. Contact your administrator if it is managed."
        case .restrictedOrUnknown: return "Portside could not confirm this permission. Contact your administrator if this Mac is managed."
        }
    }

    /// A request could change the answer. `unavailable` is never requested:
    /// Portside does not try to get around the OS or a managed policy.
    var isRequestable: Bool {
        switch self {
        case .notRequested, .denied, .restrictedOrUnknown: return true
        case .granted, .unavailable: return false
        }
    }
}

extension PermissionScope {
    /// Whether System Settings has a pane for this scope.
    var hasPrivacyPane: Bool {
        switch self {
        case .accessibility, .screenRecording: return true
        case .app: return false
        }
    }

    /// Opens this scope's list in System Settings. Changes nothing.
    @MainActor
    func openPrivacyPane() {
        switch self {
        case .accessibility:
            AccessibilityTrust.shared.openSettings()
        case .screenRecording:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .app:
            break
        }
    }

    /// What Portside uses the permission for, for Settings.
    var purpose: String {
        switch self {
        case .accessibility:
            return "Lets Portside read and move other apps' windows: Keep windows clear of the dock, and the window list and recent documents in tile menus."
        case .screenRecording:
            return "Lets the App Switcher show a picture of each window, when you turn on Window previews. Portside takes one still picture of each visible row, only while the switcher is open. It never records video, and nothing is saved or sent."
        case .app(let name):
            return "A Portside switch for \(name)."
        }
    }

    /// What still works without it.
    var fallback: String {
        switch self {
        case .accessibility:
            return "Without it, windows can extend under the dock and tile menus offer Show Windows and Recents instead. The dock, launching apps and Settings keep working."
        case .screenRecording:
            return "Without it, the switcher keeps showing app icons and window titles. Nothing else in Portside needs it."
        case .app:
            return "Features that need it stay off."
        }
    }
}
