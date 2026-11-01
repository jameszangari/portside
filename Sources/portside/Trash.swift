import AppKit
import CoreServices
import SwiftUI
import os.log

private let trashLogger = Logger(subsystem: "com.james.portside", category: "Trash")

/// The Trash tile's state and actions: empty or full, open, empty, and
/// moving dropped files to the Trash.
///
/// Event-driven: FSEvents watches ~/.Trash and the contents are re-read
/// only when it reports a change. No timers.
///
/// Fullness:
/// 1. Prefer listing ~/.Trash (needs Full Disk Access on modern macOS).
/// 2. If listing is denied, ask Finder for `count of items of the trash`
///    when Automation is already allowed (no prompt from the watcher).
/// 3. If neither works, show empty, set `accessDenied`, and log once.
///
/// React analogy: a small store (like a Zustand slice) the tile and the
/// Settings window both subscribe to.
final class TrashController: ObservableObject {
    enum State { case empty, full, unknown }

    static let hoverID = "portside.trash"

    /// `.unknown` until the first read, and whenever reading is denied.
    @Published private(set) var state: State = .unknown
    /// Could not determine fullness (no Full Disk Access and no Finder
    /// Automation). Settings shows a one-time hint.
    @Published private(set) var accessDenied = false
    /// Short message shown in place of the "Trash" label after a failed
    /// drop or Empty Trash. Cleared when the cursor leaves the tile.
    @Published private(set) var notice: String?

    let url: URL
    private var eventStream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.james.portside.trash", qos: .utility)
    private var reading = false
    private var readAgain = false
    private var loggedDenial = false
    private var loggedFinderFallback = false
    /// The cursor was on the tile while `notice` was set, so leaving it
    /// clears the notice.
    private var noticeSeen = false

    init() {
        url = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    deinit { stopWatching() }

    func start() {
        watch()
        refresh(reason: "launch")
    }

    func stop() {
        stopWatching()
    }

    var icon: NSImage {
        let name = state == .full ? NSImage.trashFullName : NSImage.trashEmptyName
        return NSImage(named: name) ?? NSImage()
    }

    // MARK: - State

    private enum ReadResult {
        case count(Int, source: String)
        case denied(Error)
        case failed(Error)
    }

    /// Re-reads the Trash off the main thread. Calls that arrive while a
    /// read is running fold into one more read after it.
    func refresh(reason: String) {
        if reading {
            readAgain = true
            return
        }
        reading = true
        let url = url
        queue.async { [weak self] in
            let result = Self.read(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                self.apply(result, reason: reason)
                if self.readAgain {
                    self.readAgain = false
                    self.refresh(reason: "\(reason) (again)")
                }
            }
        }
    }

    private static func read(_ url: URL) -> ReadResult {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            // Finder's own bookkeeping files do not make the Trash full.
            let count = names.filter { $0 != ".DS_Store" && $0 != ".localized" }.count
            return .count(count, source: "listing")
        } catch {
            guard isPermissionError(error) else { return .failed(error) }
            // Full Disk Access denied: Finder can still count Trash items
            // when Automation is already allowed for this process.
            if let count = finderItemCount(askUser: false) {
                return .count(count, source: "Finder")
            }
            return .denied(error)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? ns
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    /// Nil when Automation is missing, denied, or the script fails.
    private static func finderItemCount(askUser: Bool) -> Int? {
        let status = finderAutomationStatus(askUser: askUser)
        guard status == noErr else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"Finder\" to count of items of the trash")?
            .executeAndReturnError(&error)
        if let error {
            trashLogger.error("Finder Trash count failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let result else { return nil }
        return Int(result.int32Value)
    }

    private func apply(_ result: ReadResult, reason: String) {
        let newState: State
        switch result {
        case .count(let count, let source):
            newState = count > 0 ? .full : .empty
            if accessDenied {
                accessDenied = false
                trashLogger.info("Trash readable again via \(source, privacy: .public)")
            }
            if source == "Finder", !loggedFinderFallback {
                loggedFinderFallback = true
                trashLogger.info("Trash listing denied; using Finder for empty/full")
            }
        case .denied(let error):
            newState = .unknown
            if !accessDenied { accessDenied = true }
            if !loggedDenial {
                loggedDenial = true
                trashLogger.error("can't read the Trash (needs Full Disk Access or Finder Automation), showing it as empty: \(error.localizedDescription, privacy: .public)")
            }
        case .failed(let error):
            newState = .unknown
            trashLogger.error("can't read the Trash: \(error.localizedDescription, privacy: .public)")
        }
        guard newState != state else { return }
        state = newState
        trashLogger.info("Trash \(String(describing: newState), privacy: .public) (\(reason, privacy: .public))")
    }

    /// FSEvents on ~/.Trash works even without Full Disk Access (unlike
    /// DispatchSource + O_EVTONLY, which is denied). Latency coalesces
    /// bursts; `refresh` folds overlaps.
    private func watch() {
        guard eventStream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let trash = Unmanaged<TrashController>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { trash.refresh(reason: "Trash changed") }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            trashLogger.error("can't create FSEvents stream for the Trash")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            trashLogger.error("can't start FSEvents for the Trash")
            return
        }
        eventStream = stream
        trashLogger.info("watching \(self.url.path, privacy: .public) (FSEvents)")
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        eventStream = nil
    }

    // MARK: - Notice

    private func show(notice text: String) {
        notice = text
        noticeSeen = false
    }

    /// Brief failure text on the Trash hover label (dock-tile drop, etc.).
    func reportNotice(_ text: String) {
        show(notice: text)
    }

    /// From `DockHover`: the item under the cursor changed.
    func hoveredTargetChanged(_ id: String?) {
        guard notice != nil else { return }
        if id == Self.hoverID {
            noticeSeen = true
        } else if noticeSeen {
            notice = nil
            noticeSeen = false
        }
    }

    // MARK: - Actions

    /// Click: the Trash in a Finder window.
    func open() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        trashLogger.info("opening the Trash in Finder")
        NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            trashLogger.error("open Trash failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self?.show(notice: "Couldn't open the Trash") }
        }
    }

    func menu() -> NSMenu {
        // Menu may be the first time the user grants Automation; ask if needed
        // so Empty Trash can enable when the Trash is full.
        if state != .full, accessDenied || state == .unknown {
            queue.async { [weak self] in
                if let count = Self.finderItemCount(askUser: true) {
                    DispatchQueue.main.async {
                        self?.apply(.count(count, source: "Finder"), reason: "menu")
                    }
                }
            }
        }
        refresh(reason: "menu")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.open() })
        let empty = ClosureMenuItem("Empty Trash") { [weak self] in self?.emptyTrash() }
        empty.isEnabled = state == .full
        menu.addItem(empty)
        return menu
    }

    /// Finder hosts the confirmation and performs deletion. AppleScript's
    /// empty command alone does not guarantee a confirmation, so explicitly
    /// ask in Finder before sending it. Neither prompt blocks the dock thread.
    func emptyTrash() {
        guard state == .full else { return }
        trashLogger.info("Empty Trash: checking Automation permission for Finder")
        queue.async { [weak self] in
            let status = Self.finderAutomationStatus(askUser: true)
            if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
                trashLogger.error("Empty Trash: Automation permission denied (\(status))")
                DispatchQueue.main.async {
                    self?.show(notice: "Allow Finder in Privacy & Security > Automation")
                }
                return
            }
            let source = """
            tell application "Finder"
                activate
                display alert "Are you sure you want to permanently erase the items in the Trash?" message "You can't undo this action." as warning buttons {"Cancel", "Empty Trash"} default button "Cancel" cancel button "Cancel"
                empty the trash
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let number = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async {
                guard let self else { return }
                if let number, number != -128 {
                    trashLogger.error("Empty Trash script failed (\(number))")
                    self.show(notice: number == Int(errAEEventNotPermitted)
                              ? "Allow Finder in Privacy & Security > Automation"
                              : "Couldn't empty the Trash")
                } else if number == nil {
                    // Succeeded (or Cancel returned -128 above). Cancel leaves
                    // items; success clears them. Refresh decides.
                    // Optimistic empty only when Finder did not cancel.
                }
                if number == nil {
                    self.state = .empty
                }
                self.refresh(reason: "Finder finished")
            }
        }
    }

    private static func finderAutomationStatus(askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return OSStatus(errAEEventNotPermitted) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
    }

    // MARK: - Drop to Trash

    /// True if `url` looks like something the Trash can take: an existing
    /// file or folder the user may delete, not already in the Trash, not a
    /// volume, the home folder or the root.
    func canTrash(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        let trashPath = self.url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path != "/", path != home, path != trashPath, !path.hasPrefix(trashPath + "/") else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return false }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    /// Moves `urls` to the Trash off the main thread. Failures show a short
    /// notice on the tile; the rest still go.
    func moveToTrash(_ urls: [URL]) {
        trashLogger.info("moving \(urls.count) item(s) to the Trash")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: [(URL, Error)] = []
            var moved = 0
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    moved += 1
                } catch {
                    failed.append((url, error))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (url, error) in failed {
                    trashLogger.error("move to Trash failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                if let first = failed.first {
                    self.show(notice: failed.count == 1
                              ? "Couldn't move \u{201C}\(first.0.lastPathComponent)\u{201D} to the Trash"
                              : "Couldn't move \(failed.count) items to the Trash")
                } else {
                    trashLogger.info("moved \(urls.count) item(s) to the Trash")
                }
                // Optimistic full when anything landed; the watcher confirms.
                if moved > 0 { self.state = .full }
                self.refresh(reason: "drop")
            }
        }
    }

    // MARK: - Full Disk Access

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

/// The Trash tile at the far end of the dock. Same size, label,
/// magnification and menus as an app tile, but not draggable: it never
/// reorders and can't be dragged out.
struct TrashTileView: View {
    @ObservedObject var trash: TrashController
    let size: CGFloat
    /// A file drag is over this tile and every item can go to the Trash.
    var isDropTarget = false
    @State private var hold = MenuHold()
    @Environment(\.dockEdge) private var edge

    var body: some View {
        tile
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trash")
            .accessibilityAddTraits(.isButton)
            .dockHoverTarget(id: TrashController.hoverID, title: trash.notice ?? "Trash")
            .appKitContextMenu(edge: edge, hold: hold, magnifyID: TrashController.hoverID) { trash.menu() }
    }

    /// Same layout as an app tile, with an indicator slot that never shows,
    /// so the Trash lines up with the apps.
    @ViewBuilder private var tile: some View {
        switch edge {
        case .bottom: VStack(spacing: 2) { icon; indicator }
        case .left: HStack(spacing: 2) { indicator; icon }
        case .right: HStack(spacing: 2) { icon; indicator }
        }
    }

    private var icon: some View {
        Image(nsImage: trash.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size * IconMetrics.fullBleedScale, height: size * IconMetrics.fullBleedScale)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                    .padding(-3)
            )
            .contentShape(Rectangle())
            .menuHold(hold) { trash.open() }
            .magnifiedIcon(id: TrashController.hoverID)
    }

    private var indicator: some View {
        Color.clear
            .frame(width: 4, height: 4)
            .magnifiedIndicator(id: TrashController.hoverID)
    }
}
