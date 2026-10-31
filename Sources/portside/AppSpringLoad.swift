import AppKit
import os.log

private let springLogger = Logger(subsystem: "com.james.portside", category: "AppSpringLoad")

/// Brings a running app forward when a file drag rests on its tile, like the
/// native Dock. One-shot cancelable delay; no polling. Does not launch apps
/// that are not running (drop still opens the files).
final class AppSpringLoad {
    static let delay: TimeInterval = 0.6

    private var pending: DispatchWorkItem?
    private var currentID: String?

    /// Call whenever the file-drag target app changes (nil when none).
    func update(app: PinnedApp?, running: NSRunningApplication?) {
        let id = app?.id
        guard id != currentID else { return }
        cancel()
        currentID = id
        guard let app, let running else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            springLogger.info("spring-load: bringing \(app.displayName, privacy: .public) forward")
            running.activate()
        }
        pending = work
        springLogger.info("spring-load: armed for \(app.displayName, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func cancel() {
        guard let pending else {
            currentID = nil
            return
        }
        pending.cancel()
        self.pending = nil
        currentID = nil
        springLogger.info("spring-load: canceled")
    }
}
