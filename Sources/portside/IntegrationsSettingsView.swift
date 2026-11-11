import AppKit
import SwiftUI

/// Module switches and permissions, shown where each feature lives instead of
/// on one pane: a tool's pane lists its own modules, General lists the
/// permissions and Restricted mode. Live state is re-read when a pane appears
/// and when Portside becomes active again (back from System Settings);
/// nothing polls and nothing is requested without a button press.
struct IntegrationsLiveModifier: ViewModifier {
    @ObservedObject var integrations: IntegrationSettings
    @ObservedObject private var accessibility = AccessibilityTrust.shared

    func body(content: Content) -> some View {
        content
            .onAppear { reloadAll() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                reloadAll()
            }
            // The OS posts an Accessibility change; AccessibilityTrust relays it.
            .onChange(of: accessibility.isTrusted) { integrations.reload() }
    }

    /// Module rows, permissions, and the local model's availability (read
    /// only while Local Intelligence is on).
    private func reloadAll() {
        integrations.reload()
        if let router = integrations.intelligence {
            Task { await router.refreshAvailability() }
        }
    }
}

extension View {
    func keepsIntegrationsCurrent(_ integrations: IntegrationSettings) -> some View {
        modifier(IntegrationsLiveModifier(integrations: integrations))
    }
}

/// The switches for a set of modules, each with its state, the permissions it
/// needs and what happens without them.
struct ModuleRowsSection: View {
    @ObservedObject var integrations: IntegrationSettings
    let ids: [ModuleID]
    var title: String?
    var footer: String?

    private var rows: [IntegrationSettings.ModuleRow] {
        integrations.modules.filter { ids.contains($0.id) }
    }

    var body: some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    ModuleSettingsRow(row: row) { integrations.setEnabled($0, for: row.id) }
                }
            } header: {
                if let title { Text(title) }
            } footer: {
                if let footer { Text(footer).footerStyle() }
            }
        }
    }
}

/// Optional modules no pane claims, so a new module is never unreachable.
struct OtherModulesSection: View {
    @ObservedObject var integrations: IntegrationSettings

    static let claimed: Set<ModuleID> = [
        CommandCenterModule.moduleID, FilesModule.moduleID, ClipboardModule.moduleID,
        ShortcutsModule.moduleID, MenuBarModule.moduleID, LocalServersModule.moduleID,
        IntelligenceModule.moduleID, SwitcherModule.moduleID,
        MenuBarShelfModule.moduleID, MenuBarLayoutModule.moduleID, MenuBarReorderModule.moduleID,
    ]

    var body: some View {
        ModuleRowsSection(
            integrations: integrations,
            ids: integrations.modules.filter { !$0.isRequired && !Self.claimed.contains($0.id) }.map(\.id),
            title: "Other modules"
        )
    }
}

/// General > Work Mac: the restricted-mode switch.
struct WorkMacSection: View {
    @ObservedObject var integrations: IntegrationSettings

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { integrations.restricted },
                set: { integrations.setRestricted($0) }
            )) {
                Text("Restricted mode for work Macs")
                Text("Turns off, and keeps off, optional modules that run scripts, capture the screen, install hooks, use external runtimes, index files or intercept keys. The dock, launching apps and Settings keep working. Turning it off turns nothing back on.")
                    .helperStyle()
            }
        } header: {
            Text("Work Mac").settingsAnchor("Work Mac")
        } footer: {
            Text("Portside never changes macOS security, privacy or managed settings, and never grants or resets Full Disk Access. Existing features (AI Usage, Agent Notch hooks, Weather) keep their own switches in their panes.")
                .footerStyle()
        }
    }
}

/// General > Permissions: every permission Portside can use, live, with one
/// button to set up the next missing one.
struct PermissionsSection: View {
    @ObservedObject var integrations: IntegrationSettings

    var body: some View {
        Section(header: Text("Permissions").settingsAnchor("Permissions")) {
            PermissionSetupRow(
                next: integrations.missingPermissions.first,
                missing: integrations.missingPermissions.count,
                total: integrations.permissions.count,
                request: { integrations.request($0) }
            )
            ForEach(integrations.permissions) { row in
                PermissionSettingsRow(row: row, request: { integrations.request(row.scope) })
            }
            fullDiskAccessRow
        }
    }

    /// Not a gate scope: nothing in Portside requires it, so there is no
    /// status to read. The button only opens System Settings.
    private var fullDiskAccessRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent("Full Disk Access", value: "Not required")
            Text("Optional. It helps with protected files such as the Trash. Only you can turn it on, in System Settings. Portside never asks for it, grants it or resets it, and it does not override Gatekeeper or your employer's security policy.")
                .helperStyle()
            Button("Open Full Disk Access") { TrashController.openFullDiskAccessSettings() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Local Intelligence: the provider and its live availability. The switch
/// is the module row above; this section only reports and rechecks.
struct IntelligenceSettingsSection: View {
    @ObservedObject var router: ModelRouter

    var body: some View {
        Section {
            LabeledContent("Provider", value: router.provider.displayName)
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent("Status") {
                    Label(router.state.label, systemImage: router.state.symbol)
                        .foregroundStyle(router.state == .ready ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                Text(router.state.detail).helperStyle()
            }
            .accessibilityElement(children: .combine)
            Button("Check Again") {
                Task { await router.refreshAvailability() }
            }
            .disabled(!canCheck)
            .accessibilityHint("Asks the local provider whether it can run. Nothing is downloaded or sent.")
        } header: {
            Text("Local Intelligence").settingsAnchor("Local Intelligence")
        } footer: {
            Text("Runs only on this Mac. Portside sends no requests to hosted AI services, never falls back to the cloud, never downloads a model or starts a runtime, and runs nothing in the background. Nothing uses it yet; search and commands work the same with it off.")
                .footerStyle()
        }
    }

    private var canCheck: Bool {
        switch router.state {
        case .disabled, .checking, .busy: return false
        default: return true
        }
    }
}

/// Menu Bar Layout: one strip per section, drawn like the menu bar itself,
/// with items in their real left-to-right order. Drag an icon to another strip
/// or onto another icon and it moves right away, with one verified Command-drag.
struct MenuBarLayoutSection: View {
    @ObservedObject var service: MenuBarLayoutService
    /// Under the pointer, so its name and any reason show without a tooltip wait.
    @State private var hovered: MenuBarLayoutService.Row?

    private var hint: String {
        if let title = service.movingTitle { return "Moving \(title). The pointer moves for a moment." }
        if let hovered {
            if let note = service.menuBarOnlyNote(for: hovered) { return note }
            return hovered.blockedReason.map { "\(hovered.slot.item.displayTitle): \($0)" } ?? hovered.slot.item.displayTitle
        }
        return "Drag icons to arrange your menu bar. Changes apply right away."
    }

    var body: some View {
        if service.isActive {
            Section {
                HStack(spacing: 8) {
                    // Two lines tall always, so a long hint never moves the strips.
                    Text(hint).helperStyle().lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
                    Spacer()
                    if service.isBusy { ProgressView().controlSize(.small) }
                    Button { Task { await service.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(service.isBusy)
                        .help("Read the menu bar again")
                        .accessibilityLabel("Refresh")
                }
                if let status = service.status { Text(status).helperStyle() }
                if service.accessDenied {
                    Text("Portside needs Accessibility to see your menu bar items. Allow it in General > Permissions.").helperStyle()
                } else if service.rows.isEmpty {
                    Text("Looking for menu bar items.").helperStyle()
                } else if let blocked = service.hidingBlockedReason {
                    Text("\(blocked) Until then every item stays in the menu bar, whatever its section here.").helperStyle().foregroundStyle(.orange)
                } else if !service.barsReady, !service.hidesByMembership {
                    Text("Portside cannot find its separators in the menu bar. Turn the shelf off from its menu bar control (right-click) and on again here.").helperStyle()
                }
                if service.driftCount > 0 {
                    HStack {
                        Text("\(service.driftCount) item\(service.driftCount == 1 ? " is" : "s are") not where you put \(service.driftCount == 1 ? "it" : "them").").helperStyle()
                        Spacer()
                        Button("Put Back") { Task { await service.apply(onlySaved: true) } }.disabled(service.isBusy)
                    }
                }
            }
            .task { await service.beginEditing() }
            .onDisappear { service.endEditing() }
            ForEach(MenuBarSection.allCases) { section in
                LayoutStrip(section: section, rows: service.rows.filter { $0.isListed && $0.section == section }, service: service, hovered: $hovered)
            }
            let offScreen = service.rows.filter(\.isOffScreen)
            if !offScreen.isEmpty {
                Section {
                    TrailingFlow {
                        ForEach(offScreen) { LayoutTile(row: $0, section: nil, service: service, hovered: $hovered) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    Text("Off screen").settingsAnchor("Off screen")
                } footer: {
                    Text("macOS has no room to draw these, usually because of the notch. Portside can only move what is on screen, so quit a menu bar app to make room, then refresh.").footerStyle()
                }
            }
            Section {
                ForEach(service.missing, id: \.self) { id in
                    HStack {
                        Text(id).helperStyle().lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Forget") { service.forget(id) }.disabled(service.isBusy)
                    }
                }
                HStack {
                    Button("Reset to Native") { Task { await service.resetToNative() } }
                        .disabled(service.isBusy)
                        .accessibilityHint("Clears every choice, moves items back right of the separator and restores the saved original order.")
                    Button("Copy Layout") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(service.exportedLayout, forType: .string)
                    }
                }
            } header: {
                if !service.missing.isEmpty { Text("Saved, not in the menu bar now") }
            }
        }
    }
}

/// One section as a bar. Dropping on the bar itself lands at its separator
/// edge; dropping on an icon lands just left of that icon.
private struct LayoutStrip: View {
    let section: MenuBarSection
    let rows: [MenuBarLayoutService.Row]
    @ObservedObject var service: MenuBarLayoutService
    @Binding var hovered: MenuBarLayoutService.Row?
    @State private var targeted = false

    private var subtitle: String {
        switch section {
        case .visible: return "Always in the menu bar."
        case .hidden: return "Shown when you open the shelf."
        case .alwaysHidden:
            return service.hidesByMembership
                ? "Only shown when you double-click the menu bar or Option-click its icon."
                : "Option-click the shelf icon to show these temporarily. This section resets when Portside quits."
        }
    }

    var body: some View {
        Section {
            TrailingFlow {
                ForEach(rows) { LayoutTile(row: $0, section: section, service: service, hovered: $hovered) }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .trailing)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(targeted ? 0.14 : 0.06)))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .overlay {
                if rows.isEmpty { Text("Drag icons here").helperStyle() }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                Task { await service.drop(id, into: section) }
                return true
            } isTargeted: { targeted = $0 }
            if section == .visible, !service.cannotHideNames.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(MenuBarSystemExtra.cannotHide(service.cannotHideNames)).helperStyle()
                    Spacer()
                    Button("Open Menu Bar Settings") { NSWorkspace.shared.open(MenuBarSystemExtra.settingsURL) }
                        .help("Turn these off in System Settings")
                }
            }
        } header: {
            HStack(spacing: 8) {
                Label(section.title, systemImage: section.symbolName)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if section == .alwaysHidden, !service.hidesByMembership {
                    Toggle("Always Hidden", isOn: Binding(get: { service.alwaysHiddenOn }, set: { service.setAlwaysHidden($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(service.isBusy)
                        .accessibilityLabel("Always Hidden section")
                }
            }
            .settingsAnchor(section.title)
        }
    }
}

/// One item at menu bar size, its owner's icon. The name shows above the strips
/// while hovering. `section` is nil for an item off screen, which is no target.
private struct LayoutTile: View {
    let row: MenuBarLayoutService.Row
    let section: MenuBarSection?
    @ObservedObject var service: MenuBarLayoutService
    @Binding var hovered: MenuBarLayoutService.Row?
    @State private var targeted = false

    private var title: String { row.slot.item.displayTitle }

    private var icon: some View {
        Group {
            if !MenuBarSystemExtra.isTimeMachine(row.slot.item), let image = NSRunningApplication(processIdentifier: row.slot.item.pid)?.icon {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: MenuBarSystemExtra.isTimeMachine(row.slot.item)
                    ? MenuBarSystemExtra.timeMachineSymbol
                    : MenuBarAssertionPlan.appleItems.first { $0.bundle == row.slot.item.ownerBundleID }?.symbol ?? "square.dashed")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var tile: some View {
        icon
            .frame(width: 34, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered?.id == row.id ? 0.12 : 0)))
            .overlay(alignment: .bottomTrailing) {
                if !row.canDrag, !row.isOffScreen {
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .leading) {
                if targeted { Capsule().fill(Color.accentColor).frame(width: 2.5).padding(.vertical, 2).offset(x: -2) }
            }
            .opacity(row.canDrag ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = row } else if hovered?.id == row.id { hovered = nil }
            }
            .help(row.blockedReason ?? title)
            .contextMenu {
                ForEach(MenuBarSection.allCases) { target in
                    Button("Move to \(target.title)") { Task { await service.drop(row.id, into: target) } }
                        .disabled(service.isBusy || !row.canDrag || target == section)
                }
                if service.hidesByMembership, !service.groups.isEmpty {
                    Menu("Group") {
                        Button("None") { service.setGroup(nil, forItem: row.id) }
                        ForEach(service.groups) { group in
                            Button(service.groupID(forItem: row.id) == group.id ? "\u{2713} \(group.name)" : group.name) { service.setGroup(group.id, forItem: row.id) }
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + (row.blockedReason.map { ". \($0)" } ?? ""))
            .accessibilityAction(named: "Move to Visible") { Task { await service.drop(row.id, into: .visible) } }
            .accessibilityAction(named: "Move to Hidden") { Task { await service.drop(row.id, into: .hidden) } }
            .accessibilityAction(named: "Move to Always Hidden") { Task { await service.drop(row.id, into: .alwaysHidden) } }
    }

    var body: some View {
        if let section {
            draggableTile.dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, id != row.id else { return false }
                Task { await service.drop(id, into: section, before: row.id) }
                return true
            } isTargeted: { targeted = $0 }
        } else {
            tile
        }
    }

    @ViewBuilder private var draggableTile: some View {
        if row.canDrag {
            tile.draggable(row.id) { icon }
        } else {
            tile
        }
    }
}

/// Wraps its children into right-aligned rows, like items in a menu bar.
private struct TrailingFlow: Layout {
    var spacing: CGFloat = 2

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(view: LayoutSubview, size: CGSize)]] {
        var result: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if used + size.width > width, !result[result.count - 1].isEmpty {
                result.append([])
                used = 0
            }
            result[result.count - 1].append((view, size))
            used += size.width + spacing
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        let rows = lines(subviews, width: width)
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews, width: bounds.width) {
            var x = bounds.maxX - row.reduce(0) { $0 + $1.size.width } - spacing * CGFloat(max(row.count - 1, 0))
            for (view, size) in row {
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += (row.map(\.size.height).max() ?? 0) + spacing
        }
    }
}

/// One module: switch (or "Always on"), status, what it needs and what
/// still works while it is off.
struct ModuleSettingsRow: View {
    let row: IntegrationSettings.ModuleRow
    let setEnabled: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if row.isRequired {
                LabeledContent {
                    Text("Always on")
                } label: {
                    Text(row.title)
                    if !row.summary.isEmpty { Text(row.summary).helperStyle() }
                }
                .accessibilityElement(children: .combine)
            } else {
                Toggle(isOn: Binding(get: { row.isEnabled }, set: setEnabled)) {
                    Text(row.title)
                    if !row.summary.isEmpty { Text(row.summary).helperStyle() }
                }
                .disabled(!row.canToggle)
                .accessibilityValue(status)
                .accessibilityHint(row.isRestricted ? "Held off by restricted mode." : "")
            }
            if !row.isRequired {
                statusLine
            }
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(status, systemImage: symbol)
                .font(.system(size: 12))
                .foregroundStyle(row.state == .running ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if !row.permissions.isEmpty {
                Text("Needs: \(row.permissions.map(\.description).joined(separator: ", "))").helperStyle()
            }
            if row.state != .running, !row.fallback.isEmpty {
                Text(row.fallback).helperStyle()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if row.isRestricted { return "Off: restricted mode" }
        switch row.state {
        case .running: return "On"
        case .disabled: return "Off"
        case .waiting(let reason): return "Waiting: \(reason)"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private var symbol: String {
        if row.isRestricted { return "lock" }
        switch row.state {
        case .running: return "checkmark.circle"
        case .disabled: return "circle"
        case .waiting: return "clock"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// Asks for the next missing permission, one at a time. macOS lets only you
/// turn these on, so this cannot grant anything. Coming back from System
/// Settings reloads the pane, which moves it to the next one; nothing polls.
private struct PermissionSetupRow: View {
    let next: IntegrationSettings.PermissionRow?
    let missing: Int
    let total: Int
    let request: (PermissionScope) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Set Up Permissions", value: "\(total - missing) of \(total) allowed")
            if let next {
                Text("macOS lets only you turn these on. Portside asks for one at a time. If one still says Not allowed after you turn it on, quit and reopen Portside.")
                    .helperStyle()
                HStack {
                    Button("Allow \(next.scope.description)…") { request(next.scope) }
                        .accessibilityHint("Asks macOS for \(next.scope.description). \(missing) still to allow.")
                    if next.scope.hasPrivacyPane {
                        Button("Open Settings") { next.scope.openPrivacyPane() }
                    }
                }
            }
        }
    }
}

/// One permission scope: live status, what it is for, what still works
/// without it, and explicit actions.
private struct PermissionSettingsRow: View {
    let row: IntegrationSettings.PermissionRow
    let request: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent(row.scope.description) {
                    Label(row.state.label, systemImage: row.state == .granted ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(row.state == .granted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                Text(row.state.detail).helperStyle()
                Text(row.scope.purpose).helperStyle()
                if row.state != .granted {
                    Text(row.scope.fallback).helperStyle()
                }
                if !row.usedBy.isEmpty {
                    Text("Used by: \(row.usedBy.joined(separator: ", "))").helperStyle()
                }
            }
            .accessibilityElement(children: .combine)
            if row.state != .granted {
                HStack {
                    if row.canRequest {
                        Button("Request Access…", action: request)
                            .accessibilityHint("Asks macOS for \(row.scope.description). Nothing changes until you allow it.")
                    }
                    if row.scope.hasPrivacyPane {
                        Button("Open \(row.scope.description) Settings") { row.scope.openPrivacyPane() }
                    }
                }
            }
        }
    }
}
