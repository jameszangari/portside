import XCTest
@testable import portside

final class RevealLatencyTests: XCTestCase {
    func testPercentilesAndBudget() {
        var latency = RevealLatency()
        XCTAssertNil(latency.percentile(50))
        XCTAssertEqual(latency.summary, "Reveal latency: no reveals yet")
        for ms in [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 40] { latency.add(ms) }
        XCTAssertEqual(latency.percentile(50), 5)
        XCTAssertEqual(latency.percentile(95), 40)
        XCTAssertEqual(latency.overBudget, 1)
        XCTAssertEqual(latency.summary, "Reveal latency (last 10): median 5.0 ms, p95 40.0 ms, worst 40.0 ms, 1 over 16.7 ms")
    }

    func testKeepsOnlyTheNewestSamplesAndDropsBadOnes() {
        var latency = RevealLatency()
        latency.add(-1)
        latency.add(.nan)
        XCTAssertTrue(latency.samples.isEmpty, "a clock step or a skipped delay never counts")
        for index in 0..<(RevealLatency.capacity + 5) { latency.add(Double(index)) }
        XCTAssertEqual(latency.samples.count, RevealLatency.capacity)
        XCTAssertEqual(latency.samples.first, 5)
    }
}
