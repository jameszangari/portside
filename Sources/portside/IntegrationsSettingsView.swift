import AppKit
import SwiftUI

/// Settings > Integrations: modules, the permissions they use, and the
/// restricted work-Mac preset. Live state is re-read when the pane appears
/// and when Portside becomes active again (back from System Settings);
/// nothing polls and nothing is requested without a button press.
struct IntegrationsSettingsView: View {
    @ObservedObject var integrations: IntegrationSettings
    @ObservedObject private var accessibility = AccessibilityTrust.shared

    var body: some View {
        Form {
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
                Text("Work Mac")
            } footer: {
                Text("Portside never changes macOS security, privacy or managed settings, and never grants or resets Full Disk Access. Existing features (AI Usage, Agent Notch hooks, Weather) keep their own switches in their panes.")
                    .footerStyle()
            }

            Section {
                ForEach(integrations.modules) { row in
                    ModuleSettingsRow(row: row) { integrations.setEnabled($0, for: row.id) }
                }
            } header: {
                Text("Modules")
            } footer: {
                if !integrations.modules.contains(where: { !$0.isRequired }) {
                    Text("No optional modules are in this build yet.")
                        .footerStyle()
                }
            }

            if let router = integrations.intelligence {
                IntelligenceSettingsSection(router: router)
            }

            if let reorder = integrations.menuReorder {
                MenuBarReorderSection(service: reorder)
            }

            if let layout = integrations.menuLayout {
                MenuBarLayoutSection(service: layout)
            }

            Section("Permissions") {
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

    /// Not a gate scope: nothing in Portside requires it, so there is no
    /// status to read and no request button.
    private var fullDiskAccessRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent("Full Disk Access", value: "Not required")
            Text("Optional. It helps with protected files such as the Trash. Only you can turn it on, in System Settings (General > Permissions opens it). Portside never asks for it, grants it or resets it.")
                .helperStyle()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Local Intelligence: the provider and its live availability. The switch
/// is the module row above; this section only reports and rechecks.
private struct IntelligenceSettingsSection: View {
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
            Text("Local Intelligence")
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

/// Menu Bar Reorder: each listed item with Move Left / Move Right where it
/// is supported and the reason where it is not, plus Restore. Nothing runs
/// until a button is pressed; the list loads when the module is on.
private struct MenuBarReorderSection: View {
    @ObservedObject var service: MenuBarReorderService

    var body: some View {
        if service.isActive {
            Section {
                if service.accessDenied {
                    Text("Accessibility permission is denied or was revoked.").helperStyle()
                } else if service.rows.isEmpty {
                    Text("No menu bar items listed yet. Choose Refresh.").helperStyle()
                }
                ForEach(service.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.slot.item.displayTitle)
                            Spacer()
                            Button { Task { await service.move(row.id, .left) } } label: { Image(systemName: "arrow.left") }
                                .disabled(service.isBusy || !service.canMove(row.id, .left) || !row.support.isMovable)
                                .accessibilityLabel("Move \(row.slot.item.displayTitle) left")
                            Button { Task { await service.move(row.id, .right) } } label: { Image(systemName: "arrow.right") }
                                .disabled(service.isBusy || !service.canMove(row.id, .right) || !row.support.isMovable)
                                .accessibilityLabel("Move \(row.slot.item.displayTitle) right")
                        }
                        if case .unsupported(let reason) = row.support { Text(reason).helperStyle() }
                    }
                    .accessibilityElement(children: .contain)
                }
                HStack {
                    Button("Refresh") { Task { await service.refresh() } }.disabled(service.isBusy)
                    Button("Restore Original Order") { Task { await service.restore() } }
                        .disabled(service.isBusy || !service.hasBaseline)
                        .accessibilityHint("Drags items back to the order they had before your first move.")
                    if service.hasBaseline {
                        Button("Forget Saved Order") { service.discardBaseline() }.disabled(service.isBusy)
                    }
                }
                if let status = service.status { Text(status).helperStyle() }
            } header: {
                Text("Menu Bar Reorder")
            } footer: {
                Text("Moves are real Command-drags, one at a time, and each is checked afterwards. \(service.successes) of \(service.attempts) moves landed this session. Left is the left side of the menu bar.")
                    .footerStyle()
            }
        }
    }
}

/// Menu Bar Layout: items listed under Visible, Hidden and Always Hidden.
/// Each row has a Move to menu (works with the keyboard and VoiceOver) and can
/// also be dragged onto another section. Choosing only saves; Apply Layout
/// does the Command-drags. Nothing runs until a button is pressed.
private struct MenuBarLayoutSection: View {
    @ObservedObject var service: MenuBarLayoutService

    var body: some View {
        if service.isActive {
            Section {
                Toggle("Always Hidden section (this session only)", isOn: Binding(get: { service.alwaysHiddenOn }, set: { service.setAlwaysHidden($0) }))
                    .disabled(service.isBusy)
                    .accessibilityHint("Adds a second separator that hides its left side until you turn this off. Starts off every launch.")
                if !service.barsReady {
                    Text("The shelf separators are not visible. Show the menu bar items (click the shelf control), then Refresh.").helperStyle()
                }
                if service.rows.isEmpty {
                    Text("No menu bar items listed yet. Choose Refresh.").helperStyle()
                }
            } header: {
                Text("Menu Bar Layout")
            }
            ForEach(sections, id: \.self) { section in
                Section {
                    let rows = service.rows.filter { $0.section == section }
                    VStack(alignment: .leading, spacing: 6) {
                        if rows.isEmpty { Text("Drop items here.").helperStyle() }
                        ForEach(rows) { row in LayoutRow(row: row, service: service) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { ids, _ in
                        for id in ids { service.assign(id, to: section) }
                        return !ids.isEmpty
                    }
                } header: {
                    Text(section.title)
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
                    Button("Refresh") { Task { await service.refresh() } }.disabled(service.isBusy)
                    Button(service.pendingCount > 0 ? "Apply Layout (\(service.pendingCount))" : "Apply Layout") { Task { await service.apply() } }
                        .disabled(service.isBusy)
                        .accessibilityHint("Drags items into their sections one at a time. The pointer moves while it runs.")
                    Button("Reset to Native") { Task { await service.resetToNative() } }
                        .disabled(service.isBusy)
                        .accessibilityHint("Clears every choice, moves items back right of the separator and restores the saved original order.")
                    Button("Copy Layout") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(service.exportedLayout, forType: .string)
                    }
                }
                if let status = service.status { Text(status).helperStyle() }
            } header: {
                if !service.missing.isEmpty { Text("Saved, not in the menu bar now") }
            } footer: {
                Text("Choosing a section only saves it. Apply Layout shows every item, then moves each one with a real Command-drag and checks the result. Left of the separator is Hidden. Copy Layout puts the saved choices on the clipboard as JSON.")
                    .footerStyle()
            }
        }
    }

    private var sections: [MenuBarSection] {
        service.alwaysHiddenOn ? MenuBarSection.allCases : [.visible, .hidden]
    }
}

private struct LayoutRow: View {
    let row: MenuBarLayoutService.Row
    @ObservedObject var service: MenuBarLayoutService

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.slot.item.displayTitle)
                if row.saved != nil, row.saved != row.current { Text("not applied").helperStyle() }
                Spacer()
                Menu("Move to") {
                    ForEach(MenuBarSection.allCases.filter { $0 != .alwaysHidden || service.alwaysHiddenOn }) { target in
                        Button(target.title) { service.assign(row.id, to: target) }
                    }
                }
                .fixedSize()
                .disabled(service.isBusy || !row.canAssign)
                .accessibilityLabel("Move \(row.slot.item.displayTitle) to another section")
            }
            if let reason = row.structural {
                Text(reason).helperStyle()
            } else if case .unsupported(let reason) = row.support {
                Text(reason).helperStyle()
            }
        }
        .draggable(row.canAssign ? row.id : "")
        .accessibilityElement(children: .contain)
    }
}

/// One module: switch (or "Always on"), status, what it needs and what
/// still works while it is off.
private struct ModuleSettingsRow: View {
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
