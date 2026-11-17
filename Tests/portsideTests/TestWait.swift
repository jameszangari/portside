import Foundation

/// Waits for `condition` instead of a fixed sleep, so a slow machine (CI)
/// gets the time it needs and a fast one does not wait. Returns at the
/// timeout either way; the caller's assertion reports a miss.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let end = clock.now + timeout
    while !condition(), clock.now < end {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
