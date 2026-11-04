import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import os.log

private let nativeMenuLogger = Logger(subsystem: "com.james.portside", category: "NativeDockMenu")

/// Copies an app's window list, recent documents and own dock actions from
/// the native Dock's menu for its tile, and presses the real items.
///
/// macOS has no public way to ask an app for its dock menu or its recents
/// (the recents store needs Full Disk Access). The Dock already has all of it
/// and exposes it over Accessibility, so its menu is opened, read, and closed
/// in about 30 to 70ms. It works with the Dock hidden, but the menu does draw
/// for those few frames.
///
/// Only items above the Dock's own Options submenu are copied. Options, Quit,
/// Hide and Remove from Dock act on the native Dock and have Portside
/// equivalents, so they are never pressed from here. Recent-document items
/// also expose no URL over Accessibility, so icons are inferred from the
/// title (file type, or a folder for extensionless project names).
enum NativeDockMenu {
    /// True while `AXShowMenu` / `AXCancel` run on the Dock. That brief
    /// native menu still posts `NSMenu.didBegin/EndTrackingNotification`,
    /// which would make Portside think its own menu closed and re-arm
    /// auto-hide before the real tile menu pops up.
    private(set) static var isCapturing = false

    struct Entry {
        /// Nil for a separator.
        let title: String?
        let isEnabled: Bool
        /// The Dock's mark: a check for the current window.
        let isMarked: Bool
        /// Position in the native menu, to find the same item again.
        let index: Int
    }

    /// Titles that are dock / app commands, not recent files or folders.
    /// Matched exactly; localized Dock strings for Options and below are
    /// never copied anyway.
    private static let commandTitles: Set<String> = [
        "New Window", "New Document", "New Viewer Window",
        "Open", "Open New Window", "Show All Windows",
        "Play", "Pause", "Next", "Previous",
        "Mute", "Unmute",
    ]

    struct Snapshot {
        fileprivate let tile: AXUIElement
        let entries: [Entry]

        /// The Dock's menu is closed by now, so this opens it again and
        /// presses the item with this title, at the same place if possible.
        func press(_ entry: Entry) {
            guard let title = entry.title, let menu = NativeDockMenu.open(tile) else {
                nativeMenuLogger.error("press: menu did not open")
                return
            }
            let items = NativeDockMenu.copyableItems(of: menu)
            let usable = items.filter { $0.title == title && $0.isEnabled }
            guard let match = usable.first(where: { $0.index == entry.index }) ?? usable.first else {
                nativeMenuLogger.info("press: \(title, privacy: .private) is gone")
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                return
            }
            AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        }

        /// App Expose for this app, the Dock's "Show All Windows".
        func showAllWindows() {
            AXUIElementPerformAction(tile, "AXShowExpose" as CFString)
        }
    }

    private struct Item {
        let element: AXUIElement
        let title: String
        let isEnabled: Bool
        let isMarked: Bool
        let hasSubmenu: Bool
        let index: Int
    }

    /// Calls block on the Dock. It answers in milliseconds, and when it does
    /// not, the menu opens without these items.
    private static let timeout: Float = 0.25
    private static let openDeadline: CFTimeInterval = 0.3
    private static let maxTitleLength = 60

    /// Nil without Accessibility, or when the app has no tile in the native
    /// Dock (not running and not kept there).
    static func snapshot(of app: PinnedApp) -> Snapshot? {
        guard let tile = tile(for: app) else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        let started = CACurrentMediaTime()
        guard let menu = open(tile) else {
            nativeMenuLogger.error("\(app.displayName, privacy: .public): menu did not open")
            return nil
        }
        let items = copyableItems(of: menu)
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        // Let the Dock finish dismissing before Portside's NSMenu pops up in
        // the same screen region (especially with Hide the macOS Dock on).
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))

        var entries: [Entry] = []
        for item in items {
            if item.title.isEmpty {
                // No doubled or leading separators.
                if let last = entries.last, last.title != nil {
                    entries.append(Entry(title: nil, isEnabled: false, isMarked: false, index: item.index))
                }
            } else if !item.hasSubmenu {
                entries.append(Entry(title: item.title, isEnabled: item.isEnabled, isMarked: item.isMarked, index: item.index))
            }
        }
        if entries.last?.title == nil { entries.removeLast(entries.isEmpty ? 0 : 1) }
        let ms = (CACurrentMediaTime() - started) * 1000
        nativeMenuLogger.info("\(app.displayName, privacy: .public): \(entries.count) items in \(ms, format: .fixed(precision: 0))ms")
        return Snapshot(tile: tile, entries: entries)
    }

    /// Long window titles fit the menu; the full title still finds the item.
    static func displayTitle(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        return title.prefix(maxTitleLength / 2) + "..." + title.suffix(maxTitleLength / 2 - 3)
    }

    /// Icon beside a copied recent item, matching the native Dock menu.
    /// Window rows (marked) and known commands stay text-only.
    static func icon(for entry: Entry) -> NSImage? {
        guard let title = entry.title, !entry.isMarked, !commandTitles.contains(title) else { return nil }
        let image: NSImage
        let ext = (title as NSString).pathExtension
        if !ext.isEmpty {
            image = Self.icon(forExtension: ext)
        } else if title == "Downloads",
                  let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            image = NSWorkspace.shared.icon(forFile: downloads.path)
        } else if let folder = NSImage(named: NSImage.folderName) {
            image = folder
        } else {
            image = NSWorkspace.shared.icon(for: .folder)
        }
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    private static func icon(forExtension ext: String) -> NSImage {
        if let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    // MARK: - Dock tree

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Dock tile for App Expose when the full menu snapshot was skipped
    /// (Portside active) or failed, but Accessibility is still granted.
    static func tileIfTrusted(for app: PinnedApp) -> AXUIElement? { tile(for: app) }

    private static func tile(for app: PinnedApp) -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, timeout)
        let tiles = children(root).flatMap(children).filter {
            value($0, kAXSubroleAttribute) as? String == "AXApplicationDockItem"
        }
        let path = app.url.standardizedFileURL.path
        return tiles.first { (value($0, kAXURLAttribute) as? URL)?.standardizedFileURL.path == path }
            ?? tiles.first { value($0, kAXTitleAttribute) as? String == app.displayName }
    }

    /// Asks the Dock for its menu and waits for it. A bounded wait on a
    /// right-click, not on the reveal path.
    private static func open(_ tile: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(tile, timeout)
        guard AXUIElementPerformAction(tile, "AXShowMenu" as CFString) == .success else { return nil }
        let started = CACurrentMediaTime()
        while CACurrentMediaTime() - started < openDeadline {
            if let menu = children(tile).first { return menu }
            usleep(2000)
        }
        // Too slow for this click. Do not leave it up if it arrives late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let menu = children(tile).first { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        }
        return nil
    }

    /// The items above Options, the last item with a submenu (found by shape,
    /// since its title is localized). No submenu: nothing is safe to copy.
    private static func copyableItems(of menu: AXUIElement) -> [Item] {
        let keys = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXChildrenAttribute] as CFArray
        let items: [Item] = children(menu).enumerated().map { index, element in
            var result: CFArray?
            AXUIElementCopyMultipleAttributeValues(element, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
            let values = (result as? [Any]) ?? []
            func read<T>(_ position: Int) -> T? { position < values.count ? values[position] as? T : nil }
            let mark: String? = read(2)
            let submenu: [AXUIElement]? = read(3)
            return Item(element: element, title: read(0) ?? "", isEnabled: read(1) ?? false,
                        isMarked: !(mark ?? "").isEmpty, hasSubmenu: !(submenu ?? []).isEmpty, index: index)
        }
        guard let options = items.lastIndex(where: \.hasSubmenu) else { return [] }
        return Array(items[..<options])
    }
}
