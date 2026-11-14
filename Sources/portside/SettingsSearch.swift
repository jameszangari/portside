import SwiftUI

/// One row of Settings search: a control or section, the pane it lives in,
/// and the section header to scroll to (a `.settingsAnchor`), if any.
struct SettingsSearchEntry: Identifiable, Equatable {
    let tab: SettingsTab
    let section: String?
    let title: String
    let keywords: String

    init(_ tab: SettingsTab, _ section: String?, _ title: String, _ keywords: String) {
        self.tab = tab
        self.section = section
        self.title = title
        self.keywords = keywords
    }

    var id: String { "\(tab.rawValue)|\(section ?? "")|\(title)" }

    /// Where it is, for the result's second line.
    var path: String {
        guard let section, section != title else { return tab.title }
        return "\(tab.title) > \(section)"
    }
}

/// The Settings search index. Hand-kept so results use the words people look
/// for; `SettingsSearchTests` checks every section still has its anchor.
enum SettingsSearch {
    static let limit = 40

    /// Every word must match somewhere. Title hits outrank the rest, and
    /// matches at the start of a word outrank matches inside one.
    static func results(_ query: String, in entries: [SettingsSearchEntry] = SettingsSearch.entries) -> [SettingsSearchEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let scored: [(score: Int, entry: SettingsSearchEntry)] = entries.compactMap { entry in
            let title = entry.title.lowercased()
            let rest = "\(entry.section ?? "") \(entry.tab.title) \(entry.keywords)".lowercased()
            var total = 0
            for word in words {
                if title.hasPrefix(word) {
                    total += 0
                } else if title.split(separator: " ").contains(where: { $0.hasPrefix(word) }) {
                    total += 1
                } else if title.contains(word) {
                    total += 2
                } else if rest.contains(word) {
                    total += 4
                } else {
                    return nil
                }
            }
            return (total, entry)
        }
        return scored.sorted { ($0.score, $0.entry.title) < ($1.score, $1.entry.title) }.prefix(limit).map(\.entry)
    }

    static let entries: [SettingsSearchEntry] = [
        .init(.dock, "Layout", "Layout", ""),
        .init(.dock, "Layout", "Position", "left right bottom edge"),
        .init(.dock, "Layout", "Show Trash", "bin dock"),
        .init(.dock, "Auto-hide", "Hide dock automatically", "autohide auto-hide"),
        .init(.dock, "Motion", "Reveal delay", "timing speed auto-hide"),
        .init(.dock, "Motion", "Hide delay", "timing speed auto-hide"),
        .init(.dock, "Auto-hide", "Auto-hide", ""),
        .init(.dock, "Motion", "Motion", "timing reset"),
        .init(.dock, "Motion", "Animation duration", ""),
        .init(.dock, "Motion", "Animate opening applications", ""),
        .init(.dock, "Apps", "Apps", ""),
        .init(.dock, "Apps", "Show indicators for open applications", ""),
        .init(.dock, "Apps", "Show suggested and recent apps", "dock"),
        .init(.dock, "Apps", "Make hidden apps translucent", ""),
        .init(.dock, "Activity Icons", "Activity Icons", "camera microphone audio working"),
        .init(.dock, "Layout", "Dock preview", "simulation"),
        .init(.appearance, "Size", "Size", ""),
        .init(.appearance, "Size", "Icon size", ""),
        .init(.appearance, "More sizes", "Icon gap", "spacing padding"),
        .init(.appearance, "Size", "Magnification", "zoom enlarge"),
        .init(.appearance, "More sizes", "Magnified size", "zoom enlarge"),
        .init(.appearance, "Icons", "Icon style", ""),
        .init(.appearance, "Icons", "Icons", ""),
        .init(.appearance, "Background", "Corner radius", "round rounded"),
        .init(.appearance, "Background", "Background", "glass frosted solid color gradient blur"),
        .init(.appearance, "Badges", "Show notification badges", "notification count red"),
        .init(.appearance, "Badges", "Badge color", "notification count red"),
        .init(.appearance, "Badges", "Badges", "notification count red"),
        .init(.appearance, "Background", "Dock background", "liquid glass frosted color"),
        .init(.widgets, "AI Usage Providers", "Allow Copilot CLI quota checks", ""),
        .init(.widgets, "AI Usage Providers", "AI Usage Providers", ""),
        .init(.widgets, "Agent Hooks", "Agent Hooks", ""),
        .init(.widgets, nil, "Widgets", "calendar weather system stats cpu ram usage"),
        .init(.groups, "Groups", "Groups", ""),
        .init(.groups, "Groups", "App groups", "folders stacks"),
        .init(.commandCenter, "Launcher", "Shortcut", "hotkey keyboard keybinding"),
        .init(.commandCenter, "Launcher", "Launcher", ""),
        .init(.commandCenter, "Quicklinks, snippets and history", "Add Quicklink", ""),
        .init(.commandCenter, "Quicklinks, snippets and history", "Add Searchable Folder…", ""),
        .init(.commandCenter, "Quicklinks, snippets and history", "Refresh File Index", ""),
        .init(.commandCenter, "Quicklinks, snippets and history", "Add Snippet", ""),
        .init(.commandCenter, "Quicklinks, snippets and history", "Clear History", ""),
        .init(.commandCenter, "Quicklinks, snippets and history", "Command Center", ""),
        .init(.commandCenter, "Clipboard History", "Pause clipboard history", "privacy copy paste history"),
        .init(.commandCenter, "Clipboard History", "Keep copied text for", ""),
        .init(.commandCenter, "Clipboard History", "Exclude an App…", ""),
        .init(.commandCenter, "Clipboard History", "Clear History…", ""),
        .init(.commandCenter, "Clipboard History", "Clipboard History", "copy paste history"),
        .init(.commandCenter, "Quicklinks, snippets and history", "Quicklinks", "url links"),
        .init(.commandCenter, "Quicklinks, snippets and history", "Snippets", "text"),
        .init(.commandCenter, "Search sources", "Search sources", "files shortcuts menu bar items local servers ports"),
        .init(.switcher, "Switcher", "Shows", ""),
        .init(.switcher, "More", "Show window previews", "screenshot"),
        .init(.switcher, "More", "Search window titles with /", ""),
        .init(.switcher, "Switcher", "Switcher", ""),
        .init(.switcher, "Switcher", "Shortcut", "hotkey keyboard keybinding"),
                .init(.switcher, nil, "App Switcher", "cmd tab option tab windows"),
        .init(.menuBar, "Visible", "Visible items", "always show pinned menu bar arrange drag order move"),
        .init(.menuBar, "Hidden", "Hidden items", "shelf arrange drag sections"),
        .init(.menuBar, "Always Hidden", "Always Hidden items", "double-click option-click secret stats"),
        .init(.menuBar, "Visible", "Time Machine", "cannot hide apple system siri"),
        .init(.menuBar, "Show hidden items", "In the Portside Bar", "panel custom bar overflow bartender thaw"),
        .init(.menuBar, "Show hidden items", "Portside Bar position", "left right pointer under icon where opens"),
        .init(.menuBar, "Open with", "Click anywhere on the menu bar", "empty notch reveal"),
        .init(.menuBar, "Open with", "Scroll on the menu bar", "swipe wheel"),
        .init(.menuBar, "Open with", "Hover over the menu bar", "pointer rest"),
        .init(.menuBar, "Hide again", "Smart hide again", "rehide auto timer switch apps delay"),
        .init(.menuBar, "Icons", "Menu bar icon", "eye symbol upload image custom remove grid"),
        .init(.menuBar, "Portside Bar style", "Portside Bar look", "match dock custom system theme"),
        .init(.menuBar, "Portside Bar style", "Portside Bar icon size", "bigger smaller"),
        .init(.menuBar, "Menu bar shape", "Pills around items", "shape full notch split rounded theme color"),
        .init(.menuBar, "Menu bar background", "Menu bar color", "tint gradient glass frosted border shadow corner radius opacity"),
        .init(.menuBar, "Live Activities", "Live Activities", "iphone mac dynamic island widgets continuity"),
        .init(.menuBar, "Live Activities", "Live Activities from iPhone", "continuity mirroring phone"),
        .init(.menuBar, "Live Activities", "Keep Live Activities showing", "native standard hiding method sports"),
        .init(.menuBar, "Profiles", "Menu bar profiles", "display monitor save switch"),
        .init(.menuBar, "Groups", "Menu bar groups", "folder named"),
        .init(.menuBar, "Advanced", "Native hiding", "control center method standard"),
        .init(.menuBar, "Advanced", "Restore order without moving the pointer", "grant file access position"),
        .init(.notch, "Top Notch", "Top Notch", "island agents agent notch enable"),
        .init(.notch, "Top Notch", "Position", "attached below left right"),
        .init(.notch, "Notch Shelf", "Notch Shelf", "top shelf dynamic island hover card"),
        .init(.notch, "Notch Shelf", "Show music", "now playing media album art"),
        .init(.notch, "Appearance", "Appearance", "compact style size width height corner radius opacity border accent provider colors quick styles"),
        .init(.notch, "Shelf", "Shelf", "widgets page left right slots opens on first tab last used tabs order agent card haptics"),
        .init(.notch, "Strip and alerts", "Strip and alerts", "priority order meeting soon battery low charging rain snow weather agent finished"),
        .init(.notch, "Music", "Music", "vinyl seek tint album colors paused song banner"),
        .init(.notch, "Agents", "Hide finished after", "dismiss done completed sessions minutes"),
        .init(.notch, "Agents", "Agents", "claude codex opencode cursor copilot filter finished sessions project provider terminal time plan usage text size"),
        .init(.notch, "Behavior", "Behavior", "hover delay collapse delay click action expand animate hide when empty"),
        .init(.notch, "Displays", "Displays", "primary all displays offset distance from top"),
        .init(.general, "Updates", "Updates", "upgrade version"),
        .init(.general, "Startup", "Open at login", "startup launch"),
        .init(.general, "More", "Open Settings when Portside launches", "startup"),
        .init(.general, "Keyboard", "Keyboard", ""),
        .init(.general, "Automatic updates", "Automatic updates", "upgrade version"),
        .init(.general, "Automatic updates", "Check for updates automatically", "upgrade version"),
        .init(.general, "macOS Dock", "macOS Dock", ""),
        .init(.general, "Import", "Import", "migrate native"),
        .init(.general, "Import", "Import from macOS Dock...", "migrate native"),
        .init(.general, "Import", "Undo last import", "migrate native"),
        .init(.general, "Work Mac", "Restricted mode for work Macs", "work company"),
        .init(.general, "Work Mac", "Work Mac", ""),
        .init(.general, "Permissions", "Permissions", "accessibility privacy"),
        .init(.general, "Local Intelligence", "Local Intelligence", "ai model on-device"),
        .init(.general, "Permissions", "Accessibility permission", "privacy grant"),
        .init(.general, "Permissions", "Full Disk Access", "privacy grant"),
    ]
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The section header a search just landed on.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

private struct SettingsAnchor: ViewModifier {
    let name: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .id(name)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(highlight == name ? 0.35 : 0)))
            .padding(.horizontal, -6).padding(.vertical, -2)
            .animation(.easeOut(duration: 0.25), value: highlight)
    }
}

extension View {
    /// Marks a section header as a place Settings search can scroll to.
    func settingsAnchor(_ name: String) -> some View { modifier(SettingsAnchor(name: name)) }
}
