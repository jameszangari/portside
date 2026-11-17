import Foundation

/// Deterministic stand-in for tests and isolated hand checks. Answers from a
/// script, reads and sends nothing, and records only what it was asked.
actor FakeLocalModelProvider: LocalModelProvider {
    enum Reply: Sendable {
        case answer(String)
        /// A typed proposal, for `proposeIntent`.
        case intent(RawIntentProposal)
        case refuse(String)
        case fail(String)
        /// Waits until canceled.
        case hang
        /// Ignores cancellation and answers only after `finishStalled`, to
        /// prove the router does not wait for a provider that will not stop.
        case stall(String)
        /// `stall` for `proposeIntent`.
        case stallIntent(RawIntentProposal)
    }

    nonisolated let id = "fake"
    nonisolated let displayName = "Test provider"
    nonisolated let locality = LocalModelLocality.onDevice

    private var current: LocalModelAvailability
    private var replies: [Reply]
    private var availabilityDelay: Duration?
    private var stalled: [CheckedContinuation<Void, Never>] = []
    private(set) var availabilityReads = 0
    private(set) var requests: [LocalModelRequest] = []
    private(set) var cancellations = 0
    private(set) var releases = 0

    /// `replies` are used in order; once they run out every request answers
    /// "ok" and every intent request proposes `unsupported`.
    init(availability: LocalModelAvailability = .available, replies: [Reply] = []) {
        current = availability
        self.replies = replies
    }

    func setAvailability(_ availability: LocalModelAvailability) { current = availability }
    func setReplies(_ replies: [Reply]) { self.replies = replies }
    /// Every availability read waits this long first (canceled with the read).
    func setAvailabilityDelay(_ delay: Duration?) { availabilityDelay = delay }
    var stalledCount: Int { stalled.count }

    func finishStalled() {
        let waiting = stalled
        stalled.removeAll()
        waiting.forEach { $0.resume() }
    }

    func availability() async -> LocalModelAvailability {
        availabilityReads += 1
        if let availabilityDelay { try? await Task.sleep(for: availabilityDelay) }
        return current
    }

    func respond(to request: LocalModelRequest) async throws -> LocalModelResponse {
        requests.append(request)
        switch try await settle(replies.isEmpty ? .answer("ok") : replies.removeFirst()) {
        case .answer(let text): return LocalModelResponse(text: text)
        default: throw LocalModelError.failed("The test provider proposed an intent.")
        }
    }

    func proposeIntent(for request: LocalModelRequest) async throws -> RawIntentProposal {
        requests.append(request)
        let fallback = Reply.intent(RawIntentProposal(kind: IntentKind.unsupported.rawValue, port: nil))
        switch try await settle(replies.isEmpty ? fallback : replies.removeFirst()) {
        case .intent(let proposal): return proposal
        default: throw LocalModelError.failed("The test provider answered with text.")
        }
    }

    /// Waits out `hang` and the stalls, then returns an `answer` or `intent`.
    private func settle(_ reply: Reply) async throws -> Reply {
        switch reply {
        case .answer, .intent: return reply
        case .refuse(let reason): throw LocalModelError.refused(reason)
        case .fail(let reason): throw LocalModelError.failed(reason)
        case .hang:
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                cancellations += 1
                throw CancellationError()
            }
            return .answer("late")
        case .stall(let text):
            await withCheckedContinuation { stalled.append($0) }
            return .answer(text)
        case .stallIntent(let proposal):
            await withCheckedContinuation { stalled.append($0) }
            return .intent(proposal)
        }
    }

    func releaseResources() async { releases += 1 }
}

extension FakeLocalModelProvider {
    /// `PORTSIDE_INTELLIGENCE_FAKE=available|notReady|unavailable|unsupported`
    /// picks the fake for an isolated launch, honored only while
    /// `CFFIXED_USER_HOME` is under /tmp so a normal launch never uses it.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> FakeLocalModelProvider? {
        guard let home = environment["CFFIXED_USER_HOME"], home.hasPrefix("/tmp/"),
              let name = environment["PORTSIDE_INTELLIGENCE_FAKE"] else { return nil }
        switch name {
        case "available": return FakeLocalModelProvider(availability: .available)
        case "notReady": return FakeLocalModelProvider(availability: .notReady("The test model is still preparing."))
        case "unavailable": return FakeLocalModelProvider(availability: .unavailable("The test model is turned off."))
        case "unsupported": return FakeLocalModelProvider(availability: .unsupported("The test model does not run on this Mac."))
        default: return nil
        }
    }
}
