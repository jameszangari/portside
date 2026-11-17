import Combine
import Foundation

/// What Settings shows for local intelligence.
enum IntelligenceState: Equatable {
    /// The Intelligence module is off. Nothing is read or run.
    case disabled
    /// On; the provider's availability is being read.
    case checking
    case ready
    /// One request is running. A second one gets `.busy`.
    case busy
    case unsupported(String)
    case unavailable(String)
    case notReady(String)
}

/// The single result of one request. Every case except `completed` carries
/// what a person needs to know, and none of them falls back to another provider.
enum IntelligenceOutcome: Equatable {
    case completed(LocalModelResponse)
    case disabled
    case unsupported(String)
    case unavailable(String)
    case notReady(String)
    case busy
    case invalidRequest(String)
    case refused(String)
    case failed(String)
    case timedOut
    case canceled
}

/// Owns the provider's lifecycle and runs requests one at a time, local only.
/// Availability is read on activation, on `refreshAvailability` (Settings
/// shown, Portside active again) and before every request; nothing polls
/// and nothing runs in the background. Each request is bounded by a deadline
/// and ends on cancel, timeout or deactivation without waiting for a provider
/// that does not stop; a late answer is dropped. Prompts are never logged or
/// stored. Main actor only.
@MainActor
final class ModelRouter: ObservableObject {
    @Published private(set) var state = IntelligenceState.disabled

    let provider: any LocalModelProvider
    private let requestTimeout: Duration
    private let availabilityTimeout: Duration
    private var isActive = false
    private var availability: LocalModelAvailability?
    /// Bumped on activate, deactivate and each read, so only the latest read lands.
    private var generation = 0
    private var current: LocalModelRun?

    nonisolated init(
        provider: any LocalModelProvider,
        requestTimeout: Duration = .seconds(20),
        availabilityTimeout: Duration = .seconds(2)
    ) {
        self.provider = provider
        self.requestTimeout = requestTimeout
        self.availabilityTimeout = availabilityTimeout
    }

    /// The Intelligence module started. Reads nothing yet; call `refreshAvailability`.
    func activate() {
        guard !isActive else { return }
        isActive = true
        availability = nil
        generation += 1
        updateState()
    }

    /// The module stopped: cancels the running request, drops pending reads
    /// and releases the provider's resources.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        availability = nil
        generation += 1
        current?.cancel()
        current = nil
        updateState()
        Task { [provider] in await provider.releaseResources() }
    }

    /// Reads availability again, bounded by the availability deadline.
    /// Does nothing while off or busy (the request reads it itself).
    @discardableResult
    func refreshAvailability() async -> IntelligenceState {
        guard isActive, current == nil else { return state }
        _ = await readAvailability(run: LocalModelRun())
        return state
    }

    /// Cancels the running request, if any. It returns `.canceled`.
    func cancel() {
        current?.cancel()
    }

    /// Runs one request if the provider is ready now. Canceling the calling
    /// task returns `.canceled` at once.
    func respond(to prompt: String, maxOutputCharacters: Int = LocalModelRequest.maxOutputCharacters) async -> IntelligenceOutcome {
        let request = LocalModelRequest(prompt: prompt, maxOutputCharacters: maxOutputCharacters)
        switch await run(request, { try await $0.respond(to: request) }) {
        case .finished(let response):
            return .completed(LocalModelResponse(text: String(response.text.prefix(maxOutputCharacters))))
        case .stopped(let outcome): return outcome
        }
    }

    /// Asks the provider for one typed intent and validates it against
    /// `text` with `IntentValidator`. Same rules as `respond`: one at a time,
    /// availability at use time, deadline, cancel, and a late proposal is
    /// dropped, so a canceled or timed-out request never yields `.proposed`.
    /// Nothing is executed here.
    func proposeIntent(for text: String) async -> IntentOutcome {
        let request = LocalModelRequest(prompt: text, maxOutputCharacters: IntentValidator.maxOutputCharacters)
        switch await run(request, { try await $0.proposeIntent(for: request) }) {
        case .finished(let proposal): return IntentValidator.validate(proposal, request: text)
        case .stopped(let outcome): return .stopped(outcome)
        }
    }

    private enum Step<T> {
        case finished(T)
        /// Never `.completed`.
        case stopped(IntelligenceOutcome)
    }

    private func run<T: Sendable>(
        _ request: LocalModelRequest,
        _ operation: @escaping @Sendable (any LocalModelProvider) async throws -> T
    ) async -> Step<T> {
        guard isActive else { return .stopped(.disabled) }
        guard current == nil else { return .stopped(.busy) }
        if let problem = Self.validate(request.prompt, maxOutputCharacters: request.maxOutputCharacters) {
            return .stopped(.invalidRequest(problem))
        }
        if Task.isCancelled { return .stopped(.canceled) }
        let run = LocalModelRun()
        current = run
        updateState()
        defer {
            if current === run { current = nil }
            updateState()
        }
        return await withTaskCancellationHandler {
            await perform(run: run, operation)
        } onCancel: {
            Task { @MainActor in run.cancel() }
        }
    }

    static func validate(_ prompt: String, maxOutputCharacters: Int) -> String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The request is empty." }
        if prompt.count > LocalModelRequest.maxPromptCharacters {
            return "The request is longer than \(LocalModelRequest.maxPromptCharacters) characters."
        }
        if !(1...LocalModelRequest.maxOutputCharacters).contains(maxOutputCharacters) {
            return "The answer limit must be 1 to \(LocalModelRequest.maxOutputCharacters) characters."
        }
        return nil
    }

    private func perform<T: Sendable>(
        run: LocalModelRun,
        _ operation: @escaping @Sendable (any LocalModelProvider) async throws -> T
    ) async -> Step<T> {
        // Checked at use time: Apple Intelligence can be turned off at any moment.
        guard let availability = await readAvailability(run: run) else { return .stopped(.canceled) }
        switch availability {
        case .available: break
        case .unsupported(let reason): return .stopped(.unsupported(reason))
        case .unavailable(let reason): return .stopped(.unavailable(reason))
        case .notReady(let reason): return .stopped(.notReady(reason))
        }
        let provider = provider
        let outcome = await run.race(timeout: requestTimeout) { try await operation(provider) }
        guard isActive, !run.isCanceled else { return .stopped(.canceled) }
        switch outcome {
        case .value(let value): return .finished(value)
        case .error(LocalModelError.refused(let reason)): return .stopped(.refused(reason))
        case .error(LocalModelError.failed(let reason)): return .stopped(.failed(reason))
        case .error(is CancellationError): return .stopped(.canceled)
        case .error: return .stopped(.failed("\(provider.displayName) stopped with an error."))
        case .timedOut: return .stopped(.timedOut)
        case .canceled: return .stopped(.canceled)
        }
    }

    /// nil when canceled or superseded (deactivated, or a newer read started).
    private func readAvailability(run: LocalModelRun) async -> LocalModelAvailability? {
        generation += 1
        let mine = generation
        let provider = provider
        let outcome = await run.race(timeout: availabilityTimeout) { await provider.availability() }
        guard isActive, mine == generation, !run.isCanceled else { return nil }
        let read: LocalModelAvailability
        switch outcome {
        case .value(let value): read = value
        case .timedOut: read = .unavailable("\(provider.displayName) did not answer in time.")
        case .error, .canceled: return nil
        }
        availability = read
        updateState()
        return read
    }

    private func updateState() {
        let next: IntelligenceState
        if !isActive { next = .disabled }
        else if current != nil { next = .busy }
        else {
            switch availability {
            case nil: next = .checking
            case .available: next = .ready
            case .unsupported(let reason): next = .unsupported(reason)
            case .unavailable(let reason): next = .unavailable(reason)
            case .notReady(let reason): next = .notReady(reason)
            }
        }
        if next != state { state = next }
    }
}

/// How one raced step ended.
enum LocalModelRaceOutcome<T> {
    case value(T)
    case error(any Error)
    case timedOut
    case canceled
}

/// One request's cancel switch. Each `race` resumes exactly once: with the
/// operation's result, at the deadline, or on `cancel`, whichever is first.
/// The losing tasks are canceled and their results dropped.
@MainActor
final class LocalModelRun {
    private(set) var isCanceled = false
    private var cancelStep: (() -> Void)?

    func cancel() {
        guard !isCanceled else { return }
        isCanceled = true
        cancelStep?()
    }

    func race<T: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async -> LocalModelRaceOutcome<T> {
        if isCanceled { return .canceled }
        let step = RaceStep<T>()
        cancelStep = { step.end(.canceled) }
        defer { cancelStep = nil }
        return await withCheckedContinuation { continuation in
            step.continuation = continuation
            if isCanceled { return step.end(.canceled) }
            step.tasks = [
                Task { @MainActor in
                    let outcome: LocalModelRaceOutcome<T>
                    do { outcome = .value(try await operation()) } catch { outcome = .error(error) }
                    step.end(outcome)
                },
                Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    step.end(.timedOut)
                },
            ]
        }
    }
}

@MainActor
private final class RaceStep<T> {
    var continuation: CheckedContinuation<LocalModelRaceOutcome<T>, Never>?
    var tasks: [Task<Void, Never>] = []

    func end(_ outcome: LocalModelRaceOutcome<T>) {
        guard let continuation else { return }
        self.continuation = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        continuation.resume(returning: outcome)
    }
}
