import AppKit
import SwiftUI
import os.log

private let itemLogger = Logger(subsystem: "com.james.portside", category: "DockItem")

/// Caches app icons by path; NSWorkspace icon lookup hits the disk.
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let cached = cache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = image
        return image
    }
}

/// Launch or activate an app, like clicking it in the native Dock.
enum AppLauncher {
    static func open(_ app: PinnedApp, running: NSRunningApplication?) {
        let url = running?.bundleURL ?? app.url
        let started = CACurrentMediaTime()
        let action = running == nil ? "launching" : "activating"
        itemLogger.info("\(action, privacy: .public) \(app.displayName, privacy: .public)")

        running?.unhide()
        // openApplication goes through Launch Services, which may activate
        // another app even though Portside itself is never active. For a running
        // app it also sends the reopen event, so an app with no windows opens
        // one, matching the native Dock.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { result, error in
            let ms = (CACurrentMediaTime() - started) * 1000
            if let error {
                itemLogger.error("open failed for \(app.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                itemLogger.info("opened \(result?.localizedName ?? "?", privacy: .public) in \(ms, format: .fixed(precision: 1))ms")
            }
        }
    }
}

/// One app tile: icon, running indicator, click and context menu.
struct DockItemView: View {
    let app: PinnedApp
    let running: NSRunningApplication?
    let isPinned: Bool
    let size: CGFloat
    @ObservedObject var dockModel: DockModel

    var body: some View {
        VStack(spacing: 2) {
            // A tap gesture rather than a Button so the strip's drag gesture
            // can take over once the cursor moves.
            Image(nsImage: IconCache.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .onTapGesture {
                    AppLauncher.open(app, running: running)
                }

            Circle()
                .fill(Color.primary.opacity(running == nil ? 0 : 0.75))
                .frame(width: 4, height: 4)
        }
        .help(app.displayName)
        .contextMenu {
            if isPinned {
                Button("Remove from Dock") { dockModel.unpin(app) }
            } else {
                Button("Keep in Dock") { dockModel.pin(app) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            if let running {
                Divider()
                Button("Quit") { running.terminate() }
            }
        }
    }
}
