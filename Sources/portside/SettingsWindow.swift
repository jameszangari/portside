import SwiftUI

/// Owns the Settings window. Unlike the dock panel this is a normal window.
/// While it is open Portside is a regular app (in the native Dock, Cmd+Tab
/// and its own dock); closing it hands focus back to the app that was
/// frontmost before and returns Portside to an accessory app.
///
/// Every control writes straight to `DockModel`, which persists and
/// publishes, so the dock updates live (like a controlled input in React).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// The activation policy changed (regular while open, accessory after).
    var onActivationPolicyChanged: (() -> Void)?

    private let dockModel: DockModel
    private let layout: DockLayout
    private var window: NSWindow?
    /// The other app that was frontmost most recently while Settings was
    /// open. Focus goes back to it on close; NSApp.deactivate() alone does
    /// not reliably do that.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(dockModel: DockModel, layout: DockLayout) {
        self.dockModel = dockModel
        self.layout = layout
    }

    var isOpen: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previousApp = front
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app != .current else { return }
                self?.previousApp = app
            }
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // The Dock tile is created by the policy change and starts with
            // the generic executable icon; an icon set while accessory does
            // not carry over.
            AppIcon.applyToDockTile()
            DispatchQueue.main.async { AppIcon.applyToDockTile() }
            onActivationPolicyChanged?()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // activate() is cooperative and the system can decline it. The
        // window must still come up on top, where one click makes it key.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(dockModel: dockModel, layout: layout)
        ))
        window.title = "Portside Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        // Hand focus back first, while Portside is still a regular app that
        // owns activation. Dropping to accessory first lets macOS pick an
        // arbitrary app instead.
        if NSApp.isActive {
            if let previousApp, !previousApp.isTerminated {
                previousApp.activate(from: .current)
            } else {
                NSApp.deactivate()
            }
        }
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            guard self?.isOpen != true else { return }
            NSApp.setActivationPolicy(.accessory)
            self?.onActivationPolicyChanged?()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout

    var body: some View {
        TabView {
            GeneralSettings(dockModel: dockModel, layout: layout)
                .tabItem { Label("General", systemImage: "gearshape") }
            WidgetSettings(dockModel: dockModel)
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            GroupSettings(dockModel: dockModel)
                .tabItem { Label("Groups", systemImage: "folder") }
        }
        .frame(width: 480, height: 540)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout

    /// Same limit the separator drag clamps to. Kept one point above the
    /// minimum so the slider range is never empty.
    private var maxIconSize: CGFloat {
        max(layout.fitTileSize, DockModel.iconSizeRange.lowerBound + 1)
    }

    var body: some View {
        Form {
            Section("Dock") {
                Picker("Position on screen", selection: Binding(
                    get: { dockModel.edge },
                    set: { dockModel.setEdge($0) }
                )) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Automatically hide and show the Dock", isOn: Binding(
                    get: { dockModel.autoHide },
                    set: { dockModel.setAutoHide($0) }
                ))
                if !dockModel.autoHide {
                    Text("Windows can extend under the dock: macOS gives apps no public way to reserve screen space the way the native Dock does.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PersistingSlider(
                    title: "Icon size",
                    value: min(Double(dockModel.iconSize), Double(maxIconSize)),
                    range: Double(DockModel.iconSizeRange.lowerBound)...Double(maxIconSize),
                    step: 1,
                    format: { "\(Int($0)) pt" },
                    set: { dockModel.setIconSize(min(CGFloat($0), maxIconSize), persist: $1) }
                )
                if layout.fitTileSize < DockModel.iconSizeRange.upperBound {
                    Text("Largest size that fits on this screen: \(Int(layout.fitTileSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Animate opening applications", isOn: Binding(
                    get: { dockModel.animateOpeningApplications },
                    set: { dockModel.setAnimateOpeningApplications($0) }
                ))

                Toggle("Magnification", isOn: Binding(
                    get: { dockModel.magnificationEnabled },
                    set: { dockModel.setMagnificationEnabled($0) }
                ))
                .disabled(true)
                Text("Coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PersistingSlider(
                    title: "Reveal delay",
                    value: dockModel.revealDelay,
                    range: DockModel.revealDelayRange,
                    step: 0.05,
                    format: Self.milliseconds,
                    set: { dockModel.setRevealDelay($0, persist: $1) }
                )
                PersistingSlider(
                    title: "Hide delay",
                    value: dockModel.hideDelay,
                    range: DockModel.hideDelayRange,
                    step: 0.05,
                    format: Self.milliseconds,
                    set: { dockModel.setHideDelay($0, persist: $1) }
                )
                PersistingSlider(
                    title: "Animation duration",
                    value: dockModel.animationDuration,
                    range: DockModel.animationDurationRange,
                    step: 0.01,
                    format: { $0 == 0 ? "Instant" : Self.milliseconds($0) },
                    set: { dockModel.setAnimationDuration($0, persist: $1) }
                )
            } header: {
                Text("Timing")
            } footer: {
                HStack {
                    Text("Reduce Motion in Accessibility settings always makes the slide instant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { dockModel.resetTimingToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}

/// Slider that updates the model live while dragging and saves once when
/// the drag ends. Keyboard and accessibility changes have no drag, so they
/// save immediately.
private struct PersistingSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    /// (new value, persist)
    let set: (Double, Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(get: { value }, set: { set($0, !isDragging) }),
                    in: range,
                    step: step
                ) {
                    EmptyView()
                } onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { set(value, true) }
                }
                .labelsHidden()
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: - Widgets

private struct WidgetSettings: View {
    @ObservedObject var dockModel: DockModel

    private var available: [String] {
        WidgetCatalog.defaultKinds.filter { !dockModel.widgetKinds.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                if dockModel.widgetKinds.isEmpty {
                    Text("No widgets in the dock.").foregroundStyle(.secondary)
                }
                // A grouped Form's own rows cannot be dragged, so the
                // enabled widgets get a real List for .onMove.
                List {
                    ForEach(Array(dockModel.widgetKinds.enumerated()), id: \.element) { index, kind in
                        row(kind, enabled: true) {
                            Button { dockModel.moveWidget(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .accessibilityLabel("Move \(WidgetCatalog.info(kind)?.name ?? kind) up")
                            Button { dockModel.moveWidget(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == dockModel.widgetKinds.count - 1)
                                .accessibilityLabel("Move \(WidgetCatalog.info(kind)?.name ?? kind) down")
                        }
                        .frame(height: Self.rowHeight)
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                    }
                    .onMove { dockModel.moveWidgets(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(dockModel.widgetKinds.count) * (Self.rowHeight + 4))
            } header: {
                Text("In the Dock")
            } footer: {
                Text("Drag a row or use the arrows to reorder. Order runs left to right, or top to bottom on a side dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !available.isEmpty {
                Section("Available") {
                    ForEach(available, id: \.self) { kind in
                        row(kind, enabled: false) { EmptyView() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let rowHeight: CGFloat = 26

    @ViewBuilder
    private func row(_ kind: String, enabled: Bool, @ViewBuilder accessories: () -> some View) -> some View {
        if let info = WidgetCatalog.info(kind) {
            HStack {
                Label { Text(info.name) } icon: { info.icon }
                Spacer()
                accessories()
                    .buttonStyle(.borderless)
                Toggle(info.name, isOn: Binding(
                    get: { enabled },
                    set: { dockModel.setWidget(kind, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Groups

private struct GroupSettings: View {
    @ObservedObject var dockModel: DockModel

    var body: some View {
        Form {
            Section {
                Toggle("Open groups on hover", isOn: Binding(
                    get: { dockModel.openGroupsOnHover },
                    set: { dockModel.setOpenGroupsOnHover($0) }
                ))
                PersistingSlider(
                    title: "Open delay",
                    value: dockModel.groupHoverDelay,
                    range: DockModel.groupHoverDelayRange,
                    step: 0.05,
                    format: { "\(Int(($0 * 1000).rounded())) ms" },
                    set: { dockModel.setGroupHoverDelay($0, persist: $1) }
                )
                .disabled(!dockModel.openGroupsOnHover)
                PersistingSlider(
                    title: "Close grace",
                    value: dockModel.groupHoverCloseGrace,
                    range: DockModel.groupHoverCloseGraceRange,
                    step: 0.05,
                    format: { "\(Int(($0 * 1000).rounded())) ms" },
                    set: { dockModel.setGroupHoverCloseGrace($0, persist: $1) }
                )
                .disabled(!dockModel.openGroupsOnHover)
            } footer: {
                Text("Open delay: rest on a tile this long before the grid appears. Close grace: brief pause when leaving the tile or grid so moving across the gap does not flicker. Clicking still works either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if dockModel.groups.isEmpty {
                    Text("No groups yet. Right-click an app in the dock and choose Add to Group, then New Group.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dockModel.groups) { group in
                    GroupSettingsRow(group: group, dockModel: dockModel)
                }
            } header: {
                Text("Groups")
            } footer: {
                Text("Ungroup puts the apps back in the dock. Delete removes the group and its apps from the dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GroupSettingsRow: View {
    let group: FolderGroup
    @ObservedObject var dockModel: DockModel

    @State private var draft = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -6) {
                ForEach(group.apps.prefix(4)) { app in
                    Image(nsImage: IconCache.shared.icon(for: app.url))
                        .resizable()
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commit)
                Text(group.apps.count == 1 ? "1 app" : "\(group.apps.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Ungroup") { dockModel.ungroup(groupID: group.id) }
            Button("Delete...") { confirmingDelete = true }
        }
        .onAppear { draft = group.name }
        .onChange(of: group.name) { _, name in draft = name }
        .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
        .confirmationDialog(
            "Delete \"\(group.name)\" and remove its \(group.apps.count) apps from the dock?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) { dockModel.removeGroup(groupID: group.id) }
        }
    }

    /// Blank names revert to the current name.
    private func commit() {
        dockModel.renameGroup(groupID: group.id, to: draft)
        draft = dockModel.groups.first { $0.id == group.id }?.name ?? group.name
    }
}
