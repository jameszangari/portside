import SwiftUI
import os.log

let importLogger = Logger(subsystem: "com.james.portside", category: "Import")

/// What the native Dock holds, read through CFPreferences. Read only: nothing
/// in `com.apple.dock` is ever written from here.
struct NativeDockSnapshot {
    /// Finder first, then `persistent-apps` in native order, paths that exist.
    var apps: [PinnedApp]
    /// Apps whose path no longer exists.
    var missingApps = 0
    /// Spacer tiles in `persistent-apps`.
    var spacers = 0
    /// Folder tiles from `persistent-others` that exist on disk.
    var folderStacks: [FolderStack] = []
    /// File tiles and missing paths in `persistent-others` (skipped).
    var othersSkipped = 0
    var edge: DockEdge
    /// Native `tilesize`, unclamped.
    var tileSize: CGFloat
    /// orientation and tilesize came from native-dock-backup.json, because
    /// the live values are not the user's while the native Dock is hidden.
    var fromBackup: Bool

    /// Native default when `tilesize` is not set.
    static let defaultTileSize: CGFloat = 48

    var edgeTitle: String { edge.title }
    var sizeTitle: String { "\(Int(tileSize.rounded())) pt" }
}

enum NativeDockImport {
    private static let domain = "com.apple.dock" as CFString

    /// Read the native Dock. If a Hide-the-Dock backup exists, orientation
    /// and tilesize come from it, otherwise from the live preferences.
    static func readSnapshot() -> NativeDockSnapshot {
        var snapshot = NativeDockSnapshot(apps: [], edge: .bottom, tileSize: NativeDockSnapshot.defaultTileSize, fromBackup: false)

        let finder = PinnedApp(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")
        snapshot.apps = [finder]
        for tile in tiles("persistent-apps") {
            switch tile["tile-type"] as? String {
            case "file-tile":
                guard let data = tile["tile-data"] as? [String: Any],
                      let fileData = data["file-data"] as? [String: Any],
                      let urlString = fileData["_CFURLString"] as? String,
                      let url = URL(string: urlString), url.isFileURL else { continue }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    snapshot.missingApps += 1
                    importLogger.info("skipped missing app \(url.path, privacy: .public)")
                    continue
                }
                let app = PinnedApp(bundleIdentifier: data["bundle-identifier"] as? String, path: url.path)
                if !snapshot.apps.contains(where: { $0.id == app.id }) {
                    snapshot.apps.append(app)
                }
            case "spacer-tile", "small-spacer-tile", "flex-spacer-tile":
                snapshot.spacers += 1
            default:
                break
            }
        }
        for tile in tiles("persistent-others") {
            let type = tile["tile-type"] as? String
            guard type == "directory-tile" || type == "file-tile" || type == nil,
                  let data = tile["tile-data"] as? [String: Any],
                  let fileData = data["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let url = URL(string: urlString), url.isFileURL else {
                snapshot.othersSkipped += 1
                continue
            }
            if let stack = FolderStack(folderURL: url),
               !snapshot.folderStacks.contains(where: { $0.path == stack.path }) {
                snapshot.folderStacks.append(stack)
            } else {
                snapshot.othersSkipped += 1
                importLogger.info("skipped non-folder other \(url.path, privacy: .public)")
            }
        }

        var orientation: String?
        var tileSize: Double?
        if let backup = try? NativeDock.loadBackup() {
            snapshot.fromBackup = true
            for entry in backup.entries {
                switch (entry.key, entry.value) {
                case ("orientation", .string(let value)?): orientation = value
                case ("tilesize", .integer(let value)?): tileSize = Double(value)
                case ("tilesize", .real(let value)?): tileSize = value
                default: break
                }
            }
        } else {
            orientation = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
            tileSize = (CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? NSNumber)?.doubleValue
        }
        // "bottom", "left", "right"; missing or anything else means bottom.
        snapshot.edge = orientation.flatMap(DockEdge.init(rawValue:)) ?? .bottom
        if let tileSize, tileSize > 0 { snapshot.tileSize = CGFloat(tileSize) }

        importLogger.info("""
            read native Dock: \(snapshot.apps.count) apps, \(snapshot.missingApps) missing, \
            \(snapshot.spacers) spacers skipped, \(snapshot.folderStacks.count) folder stacks, \
            \(snapshot.othersSkipped) other tiles skipped, \
            edge \(snapshot.edge.rawValue, privacy: .public), tilesize \(Double(snapshot.tileSize), format: .fixed(precision: 1)) \
            (\(snapshot.fromBackup ? "from backup" : "live", privacy: .public))
            """)
        return snapshot
    }

    private static func tiles(_ key: String) -> [[String: Any]] {
        CFPreferencesCopyAppValue(key as CFString, domain) as? [[String: Any]] ?? []
    }

    /// Clamp to Portside's range and to the largest tile that fits `itemCount`
    /// entries plus widgets on `edge`. `fit` is the live strip limit when known
    /// (Settings); first launch has no strip yet, so it is estimated with the
    /// strip's own spacing and padding. The strip clamps again at render time.
    static func clampedIconSize(_ size: CGFloat, edge: DockEdge, itemCount: Int, widgetKinds: Int, fit: CGFloat? = nil) -> CGFloat {
        var limit = DockModel.iconSizeRange.upperBound
        if let fit {
            limit = fit
        } else {
            let screen = DockScreen.visibleFrame.size
            let length = (edge.isVertical ? screen.height : screen.width) - 40
            // Horizontal widgets can be up to 2 tiles wide; assume 2.
            let units = CGFloat(itemCount + widgetKinds * (edge.isVertical ? 1 : 2) + 1)
            let gaps = DockMetrics.spacing * (CGFloat(itemCount + widgetKinds) + 2) + 16 + 18
            limit = ((length - gaps) / max(units, 1)).rounded(.down)
        }
        let upper = min(limit, DockModel.iconSizeRange.upperBound)
        return min(max(size.rounded(), DockModel.iconSizeRange.lowerBound), max(upper, DockModel.iconSizeRange.lowerBound))
    }
}

// MARK: - Sheet

enum ImportAppsMode: Hashable {
    case addMissing, replace
}

/// Confirmation sheet for Settings > General > Import.
struct ImportSheet: View {
    let snapshot: NativeDockSnapshot
    let hasExistingFile: Bool
    let onCancel: () -> Void
    let onImport: (ImportAppsMode, Bool) -> Void

    @State private var mode: ImportAppsMode = .addMissing
    @State private var applyLook = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from macOS Dock").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Found \(snapshot.apps.count) \(snapshot.apps.count == 1 ? "app" : "apps")\(snapshot.folderStacks.isEmpty ? "" : ", \(snapshot.folderStacks.count) folder \(snapshot.folderStacks.count == 1 ? "stack" : "stacks")"), native position \(snapshot.edgeTitle), native icon size \(snapshot.sizeTitle).")
                if snapshot.fromBackup {
                    Text("Position and size come from the saved settings of the hidden macOS Dock.").helperStyle()
                }
                if skippedTotal > 0 || !snapshot.folderStacks.isEmpty {
                    Text(skippedLine).helperStyle()
                }
            }

            Picker("Apps", selection: $mode) {
                Text("Add missing apps to my dock").tag(ImportAppsMode.addMissing)
                Text("Replace my dock's apps and keep widgets and groups").tag(ImportAppsMode.replace)
            }
            .pickerStyle(.radioGroup)

            Toggle(isOn: $applyLook) {
                Text("Also use the native position and icon size")
                Text(hasExistingFile ? "Off by default so your current layout stays." : "Sets Portside's position and icon size.").helperStyle()
            }

            Text("Your current dock is copied to dock.json.before-import first. Use Undo last import to bring it back.")
                .helperStyle()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Import") { onImport(mode, applyLook) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var skippedTotal: Int { snapshot.othersSkipped + snapshot.missingApps }

    private var skippedLine: String {
        var parts: [String] = []
        if snapshot.folderStacks.count > 0 {
            parts.append("\(snapshot.folderStacks.count) folder \(snapshot.folderStacks.count == 1 ? "stack" : "stacks") will be imported")
        }
        if snapshot.othersSkipped > 0 {
            parts.append("\(snapshot.othersSkipped) file or missing \(snapshot.othersSkipped == 1 ? "tile" : "tiles") will be skipped")
        }
        if snapshot.missingApps > 0 {
            parts.append("\(snapshot.missingApps) \(snapshot.missingApps == 1 ? "app" : "apps") no longer on disk will be skipped")
        }
        return parts.joined(separator: "; ") + "."
    }
}
