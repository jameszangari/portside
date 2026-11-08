import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit behind `WindowImageCapturer` (public API, macOS 14+).
/// `windows()` lists on-screen windows (no pixels). `image(of:)` takes one
/// still picture of one window with `SCScreenshotManager`, so there is no
/// stream and no full-screen capture. Callers check Screen Recording first;
/// this type never does and may raise the system prompt if they do not.
final class ScreenCaptureKitCapturer: WindowImageCapturer, @unchecked Sendable {
    private let lock = NSLock()
    private var known: [CGWindowID: SCWindow] = [:]

    func windows() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var seen: [CGWindowID: SCWindow] = [:]
        var result: [CapturableWindow] = []
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            seen[window.windowID] = window
            result.append(CapturableWindow(
                id: window.windowID, pid: app.processID, title: window.title ?? "",
                frame: window.frame, layer: window.windowLayer, isOnScreen: window.isOnScreen
            ))
        }
        lock.withLock { known = seen }
        return result
    }

    func image(of window: CGWindowID, maxPixels: Int) async throws -> CGImage {
        guard let target = lock.withLock({ known[window] }) else { throw CaptureError.unknownWindow }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var width = max(filter.contentRect.width * scale, 1)
        var height = max(filter.contentRect.height * scale, 1)
        let longest = max(width, height)
        if longest > CGFloat(maxPixels) {
            let ratio = CGFloat(maxPixels) / longest
            width *= ratio
            height *= ratio
        }
        configuration.width = max(Int(width.rounded()), 1)
        configuration.height = max(Int(height.rounded()), 1)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    enum CaptureError: Error {
        case unknownWindow
    }
}
