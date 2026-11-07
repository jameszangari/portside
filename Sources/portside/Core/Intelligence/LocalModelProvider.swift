import Foundation

/// Where a provider runs. Every case is this Mac: there is no hosted case
/// and no cloud fallback. A loopback server still needs its own eligibility
/// check before use (a localhost server can proxy to a cloud service).
enum LocalModelLocality: Equatable, Sendable {
    /// A system framework or in-process model (Apple Foundation Models, MLX).
    case onDevice
    /// A separate local runtime on a loopback port (LM Studio, Ollama).
    case loopbackServer
}

/// What a provider reports when asked, read at use time and never cached as proof.
enum LocalModelAvailability: Equatable, Sendable {
    case available
    /// This Mac, OS, language or build cannot run the provider at all.
    case unsupported(String)
    /// Supported, but turned off or blocked outside Portside (Apple
    /// Intelligence off, runtime not running, a managed policy).
    case unavailable(String)
    /// Supported and allowed, still getting ready (the system is preparing
    /// the model). Portside never downloads or installs a model itself.
    case notReady(String)
}

/// One bounded request. The router validates the bounds before a provider sees it.
struct LocalModelRequest: Equatable, Sendable {
    static let maxPromptCharacters = 4096
    static let maxOutputCharacters = 4096

    let prompt: String
    let maxOutputCharacters: Int
}

struct LocalModelResponse: Equatable, Sendable {
    let text: String
}

/// Why a provider did not answer. Cancellation is `CancellationError`.
enum LocalModelError: Error, Equatable, Sendable {
    /// The model declined (a guardrail, an unsafe or unsupported request).
    case refused(String)
    /// Anything else: context too long, unsupported language, runtime error.
    case failed(String)
}

/// A local inference backend. Implementations read state without side
/// effects and run only when asked: no downloads, no runtime launches, no
/// background inference, no network outside a verified loopback endpoint.
protocol LocalModelProvider: AnyObject, Sendable {
    var id: String { get }
    /// Shown in Settings, for example "Apple on-device model".
    var displayName: String { get }
    var locality: LocalModelLocality { get }
    /// Current availability. Must not prompt, download, install or start anything.
    func availability() async -> LocalModelAvailability
    /// Answers one request. Throws `LocalModelError`, or `CancellationError`
    /// once the task is canceled; should stop work promptly when it is.
    func respond(to request: LocalModelRequest) async throws -> LocalModelResponse
    /// Proposes one intent for `request.prompt` from the closed `IntentKind`
    /// set. The result is untrusted; the router validates it. Same errors
    /// and cancellation as `respond`.
    func proposeIntent(for request: LocalModelRequest) async throws -> RawIntentProposal
    /// Releases sessions and resources Portside owns. Called when the module
    /// stops. Never unloads a model another app is using.
    func releaseResources() async
}

extension LocalModelProvider {
    func proposeIntent(for request: LocalModelRequest) async throws -> RawIntentProposal {
        throw LocalModelError.failed("\(displayName) cannot propose intents.")
    }

    func releaseResources() async {}
}

/// The provider this build ships with: none. Reports unsupported so
/// Settings says so plainly, and never infers.
final class NoLocalModelProvider: LocalModelProvider {
    let id = "none"
    let displayName = "None in this build"
    let locality = LocalModelLocality.onDevice

    func availability() async -> LocalModelAvailability {
        .unsupported("This build has no local model provider yet. On-device models arrive in a later update.")
    }

    func respond(to request: LocalModelRequest) async throws -> LocalModelResponse {
        throw LocalModelError.failed("This build has no local model provider.")
    }
}
