import Foundation
import os

/// How long a reveal takes from the edge touch (the event's own timestamp)
/// to the start of the slide, without the user's reveal delay. AGENTS.md
/// sets about one frame. Each reveal is also an `os_signpost` interval
/// ("Reveal" category) for Instruments. Recorded on the main thread only,
/// once per reveal; nothing polls.
struct RevealLatency {
    static let budgetMs = 16.7
    static let capacity = 200

    private(set) var samples: [Double] = []

    mutating func add(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        samples.append(ms)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// Nearest-rank percentile, `p` in 0...100.
    func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    var overBudget: Int { samples.filter { $0 > Self.budgetMs }.count }

    var summary: String {
        guard let p50 = percentile(50), let p95 = percentile(95), let worst = samples.max() else {
            return "Reveal latency: no reveals yet"
        }
        let format = { (ms: Double) in String(format: "%.1f ms", ms) }
        return "Reveal latency (last \(samples.count)): median \(format(p50)), p95 \(format(p95)), worst \(format(worst)), "
            + "\(overBudget) over \(format(Self.budgetMs))"
    }

    /// Main thread only.
    nonisolated(unsafe) static var shared = RevealLatency()
    static let signposter = OSSignposter(subsystem: "com.james.portside", category: "Reveal")
}
