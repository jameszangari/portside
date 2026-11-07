import Foundation

/// The optional `intelligence` module. Off by default like every optional
/// module, and sensitive, so the restricted work-Mac preset holds it off.
/// Running, it activates the router and reads the provider's availability
/// once; stopping cancels any request and releases the provider. Nothing in
/// Portside depends on it and it adds no commands yet: search and commands
/// work the same while it is off.
@MainActor
final class IntelligenceModule: PortsideModule {
    static let moduleID = ModuleID("intelligence")!

    let id = IntelligenceModule.moduleID
    let title = "Local Intelligence"
    let summary = "On-device models only. Portside sends nothing to hosted services, has no cloud fallback, and never downloads a model or starts a runtime."
    let fallback = "Search, commands and the dock work the same without it."

    private let router: ModelRouter

    init(router: ModelRouter) {
        self.router = router
    }

    func start(_ context: ModuleContext) throws {
        router.activate()
        context.task { [router] in await router.refreshAvailability() }
        context.onStop { [router] in
            MainActor.assumeIsolated { router.deactivate() }
        }
    }
}

extension IntelligenceState {
    /// Short status for Settings.
    var label: String {
        switch self {
        case .disabled: return "Off"
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .busy: return "Busy"
        case .unsupported: return "Not supported"
        case .unavailable: return "Unavailable"
        case .notReady: return "Not ready"
        }
    }

    /// One line under the status. No managed-policy diagnosis.
    var detail: String {
        switch self {
        case .disabled: return "Turn on Local Intelligence under Modules to check this Mac."
        case .checking: return "Asking the provider whether it can run."
        case .ready: return "The local model can answer requests on this Mac."
        case .busy: return "A request is running. One runs at a time."
        case .unsupported(let reason), .notReady(let reason): return reason
        case .unavailable(let reason): return "\(reason) Contact your administrator if this Mac is managed."
        }
    }

    var symbol: String {
        switch self {
        case .disabled: return "circle"
        case .checking: return "clock"
        case .ready: return "checkmark.circle"
        case .busy: return "hourglass"
        case .unsupported: return "nosign"
        case .unavailable: return "exclamationmark.circle"
        case .notReady: return "clock.badge.exclamationmark"
        }
    }
}
