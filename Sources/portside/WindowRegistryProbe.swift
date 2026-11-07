#if DEBUG
import AppKit

/// `portside --check-windows`: runs the live `WindowRegistry` for up to three
/// seconds against the apps that are open now and prints counts only (no
/// app names or window titles). Read-only: it observes, never moves or
/// focuses anything, and never asks for Accessibility.
enum WindowRegistryProbe {
    @MainActor static func run() -> Int32 {
        _ = NSApplication.shared
        let runningApps = RunningApps()
        let registry = WindowRegistry.live(runningApps: runningApps)
        let started = CACurrentMediaTime()
        let release = registry.addClient()
        let startMs = (CACurrentMediaTime() - started) * 1000
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, registry.snapshot.apps.contains(where: { $0.windowAccess == .loading }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let settledMs = (CACurrentMediaTime() - started) * 1000
        let snapshot = registry.snapshot
        let access = Dictionary(grouping: snapshot.apps, by: \.windowAccess).mapValues(\.count)
        print("""
            accessibility: \(snapshot.accessibilityGranted ? "granted" : "not granted (app-only)")
            apps: \(snapshot.apps.count) (ready \(access[.ready] ?? 0), loading \(access[.loading] ?? 0), \
            unresponsive \(access[.unresponsive] ?? 0), app-only \(access[.appOnly] ?? 0))
            windows: \(snapshot.windows.count), with display \(snapshot.windows.filter { $0.displayID != nil }.count), \
            focused \(snapshot.windows.filter { $0.isFocused }.count)
            main-thread start: \(String(format: "%.1f", startMs)) ms, settled: \(String(format: "%.0f", settledMs)) ms
            """)
        release()
        let stopped = registry.snapshot == .empty
        print(stopped ? "PASS registry released on last client" : "FAIL registry kept state after release")
        // Starting must not wait on any app.
        return stopped && startMs < 50 ? 0 : 1
    }
}
#endif
