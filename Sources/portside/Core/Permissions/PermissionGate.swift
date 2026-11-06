import ApplicationServices
import Foundation

/// What a command needs before it may run. Accessibility is an OS grant;
/// `app` scopes are Portside-level switches (a module or data scope) named
/// by the owner that registers the adapter.
enum PermissionScope: Hashable, CustomStringConvertible {
    case accessibility
    case app(String)

    var description: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .app(let name): return name
        }
    }
}

/// Observed state of one scope. macOS does not say whether MDM caused a
/// denial, so `restrictedOrUnknown` makes no managed-policy claim.
enum PermissionState: Equatable {
    case notRequested
    case granted
    case denied
    case unavailable
    case restrictedOrUnknown
}

/// Reads one scope's current state and, only when asked, requests it.
/// `currentState` must never prompt or show UI.
@MainActor
protocol PermissionAdapter {
    var scope: PermissionScope { get }
    func currentState() -> PermissionState
    /// Explicit user action only. Adapters that cannot ask return false.
    func request(forFeature feature: String) -> Bool
}

extension PermissionAdapter {
    func request(forFeature feature: String) -> Bool { false }
}

/// Accessibility trust, read with `AXIsProcessTrusted` (never the prompting
/// option). The OS reports only trusted or not, so "not trusted" is `denied`.
@MainActor
struct AccessibilityPermissionAdapter: PermissionAdapter {
    let scope = PermissionScope.accessibility

    func currentState() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    func request(forFeature feature: String) -> Bool {
        AccessibilityTrust.shared.requestAccess(forFeature: feature)
        return true
    }
}

/// An app-level scope backed by a closure the owner supplies, for example a
/// module switch. It is independent of `UsageConsent` unless an owner chooses
/// to read that from the closure.
@MainActor
struct AppPermissionAdapter: PermissionAdapter {
    let scope: PermissionScope
    private let state: () -> PermissionState
    private let requester: ((String) -> Bool)?

    init(
        name: String,
        state: @escaping () -> PermissionState,
        request: ((String) -> Bool)? = nil
    ) {
        self.scope = .app(name)
        self.state = state
        self.requester = request
    }

    func currentState() -> PermissionState { state() }

    func request(forFeature feature: String) -> Bool { requester?(feature) ?? false }
}

/// Proof that every scope was granted when it was issued. It is not an
/// approval to execute: `authorizeExecution` re-reads live state.
struct PermissionTicket: Equatable {
    let scopes: [PermissionScope]
}

struct PermissionDenial: Error, Equatable {
    let scope: PermissionScope
    let state: PermissionState

    /// Text for a person. No managed-policy diagnosis.
    var reason: String {
        switch state {
        case .granted: return "\(scope) is allowed."
        case .notRequested: return "\(scope) permission has not been requested yet."
        case .denied: return "\(scope) permission is denied or was revoked."
        case .unavailable: return "\(scope) is unavailable on this Mac. Contact your administrator if it is managed."
        case .restrictedOrUnknown: return "\(scope) permission could not be confirmed."
        }
    }
}

/// One place that answers "may this run now?". It observes through adapters,
/// asks the OS only from `request`, and never grants anything itself. Main
/// actor only.
@MainActor
final class PermissionGate {
    private var adapters: [PermissionScope: any PermissionAdapter] = [:]

    nonisolated init() {}

    /// Registering reads nothing and prompts for nothing. A second adapter
    /// for the same scope replaces the first.
    func register(_ adapter: any PermissionAdapter) {
        adapters[adapter.scope] = adapter
    }

    /// Live state. A scope with no adapter is `unavailable`.
    func state(of scope: PermissionScope) -> PermissionState {
        adapters[scope]?.currentState() ?? .unavailable
    }

    /// First scope that is not granted, in the order given.
    func firstDenial(for scopes: [PermissionScope]) -> PermissionDenial? {
        for scope in scopes {
            let current = state(of: scope)
            if current != .granted { return PermissionDenial(scope: scope, state: current) }
        }
        return nil
    }

    /// Validation step: a ticket when everything is granted right now.
    func prepare(_ scopes: [PermissionScope]) -> Result<PermissionTicket, PermissionDenial> {
        if let denial = firstDenial(for: scopes) { return .failure(denial) }
        return .success(PermissionTicket(scopes: scopes))
    }

    /// Execution step: re-reads every scope, so a revocation after `prepare`
    /// blocks the handler.
    func authorizeExecution(_ ticket: PermissionTicket) -> PermissionDenial? {
        firstDenial(for: ticket.scopes)
    }

    /// Explicit user action only (a button or menu choice). Returns whether a
    /// request was started; the caller re-reads state afterward.
    @discardableResult
    func request(_ scope: PermissionScope, forFeature feature: String) -> Bool {
        adapters[scope]?.request(forFeature: feature) ?? false
    }
}
