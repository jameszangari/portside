import Foundation

/// Deterministic stand-in for tests and isolated hand checks. Answers from a
/// script, reads and sends nothing, and records only what it was asked.
actor FakeLocalModelProvider: LocalModelProvider {
    enum Reply: Sendable {
        case answer(String)
        case refuse(String)
        case fail(String)
        /// Waits until canceled.
        case hang
        /// Ignores cancellation and answers only after `finishStalled`, to
        /// prove the router does not wait for a provider that will not stop.
        case stall(String)
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

    /// `replies` are used in order; once they run out every request answers "ok".
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
        let reply = replies.isEmpty ? .answer("ok") : replies.removeFirst()
        switch reply {
        case .answer(let text): return LocalModelResponse(text: text)
        case .refuse(let reason): throw LocalModelError.refused(reason)
        case .fail(let reason): throw LocalModelError.failed(reason)
        case .hang:
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                cancellations += 1
                throw CancellationError()
            }
            return LocalModelResponse(text: "late")
        case .stall(let text):
            await withCheckedContinuation { stalled.append($0) }
            return LocalModelResponse(text: text)
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
