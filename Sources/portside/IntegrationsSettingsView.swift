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

            Section("Permissions") {
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
                    if row.scope == .accessibility {
                        Button("Open Accessibility Settings") { AccessibilityTrust.shared.openSettings() }
                    }
                }
            }
        }
    }
}
