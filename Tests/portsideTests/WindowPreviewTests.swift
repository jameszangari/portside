import CoreGraphics
import XCTest
@testable import portside

/// A capturer that never touches ScreenCaptureKit. `hold` keeps `image`
/// waiting so a test can change a gate while a picture is in flight.
final class FakePreviewCapturer: WindowImageCapturer, @unchecked Sendable {
    private let lock = NSLock()
    private var _windows: [CapturableWindow] = []
    private var _hold = false
    private var _failing = false
    private var _listCalls = 0
    private var _imageCalls: [CGWindowID] = []
    private var _active = 0
    private var _peak = 0

    var windowList: [CapturableWindow] {
        get { lock.withLock { _windows } }
        set { lock.withLock { _windows = newValue } }
    }
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    var listCalls: Int { lock.withLock { _listCalls } }
    var imageCalls: [CGWindowID] { lock.withLock { _imageCalls } }
    var peakConcurrency: Int { lock.withLock { _peak } }

    func windows() async throws -> [CapturableWindow] {
        lock.withLock { _listCalls += 1 }
        return windowList
    }

    func image(of window: CGWindowID, maxPixels: Int) async throws -> CGImage {
        lock.withLock {
            _imageCalls.append(window)
            _active += 1
            _peak = max(_peak, _active)
        }
        defer { lock.withLock { _active -= 1 } }
        while hold { try await Task.sleep(nanoseconds: 2_000_000) }
        if failing { throw CocoaError(.fileReadUnknown) }
        return FakePreviewCapturer.pixel
    }

    static let pixel: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()
}

private let appA = AppKey(pid: 10, generation: 1)

private func target(_ serial: UInt64, title: String = "Doc", frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600),
                    minimized: Bool = false, app: AppKey = appA) -> PreviewTarget {
    PreviewTarget(window: WindowID(app: app, serial: serial), title: title, frame: frame, isMinimized: minimized)
}

private func capturable(_ id: CGWindowID, pid: pid_t = 10, title: String = "Doc",
                        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
                        layer: Int = 0, onScreen: Bool = true) -> CapturableWindow {
    CapturableWindow(id: id, pid: pid, title: title, frame: frame, layer: layer, isOnScreen: onScreen)
}

final class PreviewMatcherTests: XCTestCase {
    func testOneEqualFrameMatchesWithinTolerance() {
        let near = CGRect(x: 101, y: 99, width: 801, height: 599)
        XCTAssertEqual(PreviewMatcher.match(target(1), in: [capturable(7, frame: near)]), 7)
        let far = CGRect(x: 110, y: 100, width: 800, height: 600)
        XCTAssertNil(PreviewMatcher.match(target(1), in: [capturable(7, frame: far)]))
    }

    func testOtherAppsOffScreenAndNonStandardLayersNeverMatch() {
        let candidates = [capturable(1, pid: 99), capturable(2, layer: 25), capturable(3, onScreen: false)]
        XCTAssertNil(PreviewMatcher.match(target(1), in: candidates))
    }

    func testTiedFramesNeedAnExactUniqueTitle() {
        let candidates = [capturable(1, title: "Doc"), capturable(2, title: "Other")]
        XCTAssertEqual(PreviewMatcher.match(target(1, title: "Other"), in: candidates), 2)
        XCTAssertNil(PreviewMatcher.match(target(1, title: "Missing"), in: candidates), "an icon beats another window's picture")
        XCTAssertNil(PreviewMatcher.match(target(1, title: ""), in: candidates))
        XCTAssertNil(PreviewMatcher.match(target(1, title: "Doc"), in: [capturable(1), capturable(2)]), "same title, same frame")
    }

    func testNoFrameNoMatch() {
        XCTAssertNil(PreviewMatcher.match(target(1, frame: nil), in: [capturable(1)]))
    }
}

@MainActor
final class WindowPreviewServiceTests: XCTestCase {
    private let capturer = FakePreviewCapturer()
    private var permission = PermissionState.granted
    private var locked = false

    private lazy var service = WindowPreviewService(
        capturer: capturer,
        permission: { [unowned self] in permission },
        isLocked: { [unowned self] in locked },
        now: { 0 },
        watchesSystem: false
    )

    private func ready(_ target: PreviewTarget) -> Bool {
        if case .ready = service.state(for: target) { return true }
        return false
    }

    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    private func armed() {
        capturer.windowList = (1...20).map { capturable(CGWindowID($0), frame: CGRect(x: 0, y: 0, width: 100 + 10 * CGFloat($0), height: 100)) }
        service.setOptedIn(true)
        service.attach(surface: "switcher")
    }

    private func spot(_ serial: UInt64) -> PreviewTarget {
        target(serial, frame: CGRect(x: 0, y: 0, width: 100 + 10 * CGFloat(serial), height: 100))
    }

    func testOffByDefaultNothingIsCaptured() async {
        capturer.windowList = [capturable(1)]
        service.attach(surface: "switcher")
        service.request(target(1))
        await settle()
        XCTAssertEqual(capturer.listCalls, 0)
        XCTAssertEqual(service.blocker, .notEnabled)
        guard case .fallback(.notEnabled) = service.state(for: target(1)) else { return XCTFail("expected notEnabled") }
    }

    func testNothingIsCapturedWithoutAShowingSurface() async {
        capturer.windowList = [capturable(1)]
        service.setOptedIn(true)
        service.request(target(1))
        await settle()
        XCTAssertEqual(capturer.listCalls, 0)
        XCTAssertEqual(service.blocker, .noSurface)
    }

    func testWithoutScreenRecordingScreenCaptureKitIsNeverCalled() async {
        permission = .denied
        armed()
        service.request(spot(1))
        await settle()
        XCTAssertEqual(capturer.listCalls, 0, "not even the window list, which could raise the system prompt")
        XCTAssertEqual(capturer.imageCalls, [])
        guard case .fallback(.noPermission) = service.state(for: spot(1)) else { return XCTFail("expected noPermission") }
    }

    func testAPictureArrivesForAVisibleRow() async {
        armed()
        service.request(spot(1))
        guard case .loading = service.state(for: spot(1)) else { return XCTFail("loading first") }
        await wait("picture") { ready(spot(1)) }
        XCTAssertEqual(capturer.imageCalls, [1])
    }

    func testSurfacesAskingForTheSameWindowCaptureItOnce() async {
        armed()
        service.attach(surface: "dock")
        service.request(spot(1))
        service.request(spot(1))
        await wait("picture") { ready(spot(1)) }
        service.request(spot(1))
        await settle()
        XCTAssertEqual(capturer.imageCalls, [1], "one capture however many surfaces ask")
    }

    func testABurstOfRowsReadsTheWindowListOnce() async {
        armed()
        for serial in 1...5 { service.request(spot(UInt64(serial))) }
        await wait("pictures") { (1...5).allSatisfy { ready(spot(UInt64($0))) } }
        XCTAssertEqual(capturer.listCalls, 1)
    }

    func testMinimizedWindowsKeepTheirIconAndAreNotCaptured() async {
        armed()
        let minimized = target(1, minimized: true)
        service.request(minimized)
        await settle()
        XCTAssertEqual(capturer.imageCalls, [])
        guard case .fallback(.minimized) = service.state(for: minimized) else { return XCTFail("expected minimized") }
    }

    func testAWindowThatCannotBeFoundOrCapturedFallsBack() async {
        armed()
        let missing = target(99, frame: CGRect(x: 5, y: 5, width: 5, height: 5))
        service.request(missing)
        await wait("not found") { if case .fallback(.notFound) = service.state(for: missing) { return true } else { return false } }
        XCTAssertEqual(capturer.imageCalls, [])
        capturer.failing = true
        service.request(spot(2))
        await wait("failed") { if case .fallback(.failed) = service.state(for: spot(2)) { return true } else { return false } }
    }

    func testMemoryCacheIsBounded() async {
        armed()
        for serial in 1...20 { service.request(spot(UInt64(serial))) }
        await wait("all done") { capturer.imageCalls.count == 20 && service.inFlightCount == 0 }
        XCTAssertEqual(service.storedImageCount, WindowPreviewService.maxImages)
        XCTAssertFalse(ready(spot(1)), "oldest dropped first")
        XCTAssertTrue(ready(spot(20)))
    }

    func testConcurrencyIsLimited() async {
        capturer.hold = true
        armed()
        for serial in 1...8 { service.request(spot(UInt64(serial))) }
        await wait("three started") { capturer.imageCalls.count == WindowPreviewService.maxConcurrent }
        await settle()
        XCTAssertEqual(capturer.imageCalls.count, WindowPreviewService.maxConcurrent)
        capturer.hold = false
        await wait("rest") { capturer.imageCalls.count == 8 }
        XCTAssertLessThanOrEqual(capturer.peakConcurrency, WindowPreviewService.maxConcurrent)
    }

    func testLastSurfaceLeavingCancelsAndForgetsEverything() async {
        armed()
        service.attach(surface: "dock")
        service.request(spot(1))
        await wait("picture") { ready(spot(1)) }
        service.detach(surface: "dock")
        XCTAssertEqual(service.storedImageCount, 1, "another surface is still showing")
        service.detach(surface: "switcher")
        XCTAssertEqual(service.storedImageCount, 0)
        XCTAssertEqual(service.blocker, .noSurface)
    }

    func testClosingWhileAPictureIsInFlightDropsItsResult() async {
        capturer.hold = true
        armed()
        service.request(spot(1))
        await wait("started") { capturer.imageCalls.count == 1 }
        service.detach(surface: "switcher")
        capturer.hold = false
        await settle()
        XCTAssertEqual(service.storedImageCount, 0)
        XCTAssertEqual(service.inFlightCount, 0)
    }

    func testTurningTheOptInOffStopsAndClears() async {
        capturer.hold = true
        armed()
        service.request(spot(1))
        await wait("started") { capturer.imageCalls.count == 1 }
        service.setOptedIn(false)
        capturer.hold = false
        await settle()
        XCTAssertEqual(service.storedImageCount, 0)
        XCTAssertEqual(service.inFlightCount, 0)
        service.request(spot(2))
        await settle()
        XCTAssertEqual(capturer.imageCalls, [1])
    }

    func testRevokedPermissionDuringCaptureDropsThePictureAndStops() async {
        capturer.hold = true
        armed()
        service.request(spot(1))
        await wait("started") { capturer.imageCalls.count == 1 }
        permission = .denied
        capturer.hold = false
        await settle()
        XCTAssertEqual(service.storedImageCount, 0)
        guard case .fallback(.noPermission) = service.state(for: spot(1)) else { return XCTFail("expected noPermission") }
    }

    func testLockedScreenCapturesNothingAndEndsWork() async {
        armed()
        service.request(spot(1))
        await wait("picture") { ready(spot(1)) }
        locked = true
        service.request(spot(2))
        await settle()
        XCTAssertEqual(service.storedImageCount, 0, "a lock drops what was stored")
        XCTAssertEqual(capturer.imageCalls, [1])
        guard case .fallback(.locked) = service.state(for: spot(1)) else { return XCTFail("expected locked") }
        locked = false
        service.request(spot(2))
        await wait("after unlock") { ready(spot(2)) }
    }

    func testStopCancelsQueuedWorkToo() async {
        capturer.hold = true
        armed()
        for serial in 1...8 { service.request(spot(UInt64(serial))) }
        await wait("three started") { capturer.imageCalls.count == 3 }
        service.stop()
        capturer.hold = false
        await settle()
        XCTAssertEqual(capturer.imageCalls.count, 3, "queued rows never started")
        XCTAssertEqual(service.storedImageCount, 0)
    }
}

/// `switcherPreviews` in dock.json.
final class SwitcherPreviewSettingsTests: XCTestCase {
    private func model(_ json: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
    }

    func testOffByDefaultMalformedReadsAsOffAndRoundTrips() throws {
        let empty = try model("{}")
        XCTAssertFalse(empty.switcherPreviews, "capture is an explicit opt-in")
        XCTAssertFalse(try model(#"{"switcherPreviews": "yes"}"#).switcherPreviews)
        XCTAssertFalse(try model(#"{"switcherPreviews": 1}"#).switcherPreviews)
        let on = try model(#"{"switcherPreviews": true}"#)
        XCTAssertTrue(on.switcherPreviews)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(on)) as? [String: Any])
        XCTAssertEqual(json["switcherPreviews"] as? Bool, true)
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        XCTAssertEqual(defaults["switcherPreviews"] as? Bool, false)
    }
}
