import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI entry point. There is no main window: the only scene is a tiny
/// menu bar item. All the real work happens in `AppDelegate` -> `DockEngine`.
@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Text("Portside")
            Divider()
            Button("Settings...") {
                appDelegate.openSettings()
            }
            .keyboardShortcut(",")
            Button("Add App to Dock...") {
                appDelegate.addApps()
            }
            HidingMenuItem(dockModel: appDelegate.dockModel)
            WidgetsMenu(dockModel: appDelegate.dockModel)
            PositionMenu(dockModel: appDelegate.dockModel)
            Divider()
            Button("Quit Portside") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // Temporary: icon plus text so the item is easy to spot and to
            // find in Bartender's item list. Back to icon only before release.
            HStack(spacing: 4) {
                Image(systemName: "sailboat.fill")
                Text("Portside")
            }
            .accessibilityLabel("Portside")
        }
    }
}

// MARK: - App Delegate

/// Checkbox per catalog widget.
private struct WidgetsMenu: View {
    @ObservedObject var dockModel: DockModel

    var body: some View {
        Menu("Widgets") {
            ForEach(WidgetCatalog.defaultKinds, id: \.self) { kind in
                if let info = WidgetCatalog.info(kind) {
                    Toggle(isOn: Binding(
                        get: { dockModel.widgetKinds.contains(kind) },
                        set: { dockModel.setWidget(kind, enabled: $0) }
                    )) {
                        Label { Text(info.name) } icon: { info.icon }
                    }
                }
            }
        }
    }
}

/// Same wording as the native Dock's divider menu. The shortcut shown here
/// is the global Cmd+Option+D hotkey.
private struct HidingMenuItem: View {
    @ObservedObject var dockModel: DockModel

    var body: some View {
        Button(dockModel.autoHide ? "Turn Hiding Off" : "Turn Hiding On") {
            dockModel.setAutoHide(!dockModel.autoHide)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
    }
}

/// Quick position switch. Same model setter as the Settings picker.
private struct PositionMenu: View {
    @ObservedObject var dockModel: DockModel

    var body: some View {
        Picker("Position on Screen", selection: Binding(
            get: { dockModel.edge },
            set: { dockModel.setEdge($0) }
        )) {
            ForEach(DockEdge.allCases) { edge in
                Text(edge.title).tag(edge)
            }
        }
        .pickerStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created with the delegate so the menu bar scene can observe it.
    let dockModel = DockModel.load()
    private var dockEngine: DockEngine?
    private var settings: SettingsWindowController?
    private var hideHotKey: HotKey?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // An SPM executable has no bundle, so LSUIElement in Info.plist is
        // ignored. Accessory policy = no Dock icon, no menu bar takeover,
        // and we never become the active app on launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image
        BackgroundCursor.enable()
        let engine = DockEngine(dockModel: dockModel)
        dockEngine = engine
        engine.onOpenSettings = { [weak self] in self?.openSettings() }
        engine.start()
        // The native Dock's own shortcut. If macOS's "Turn Dock hiding
        // on/off" shortcut is enabled it may take the keypress first.
        hideHotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: cmdKey | optionKey, name: "Cmd+Option+D") { [weak self] in
            self?.toggleAutoHide()
        }
    }

    func toggleAutoHide() {
        dockModel.setAutoHide(!dockModel.autoHide)
    }

    /// Clicking Portside's icon in the native Dock (it is there while
    /// Settings is open) brings Settings forward, like any app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockEngine?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A normal window, so Portside activates while it is open. The dock
    /// panel itself stays non-activating.
    func openSettings() {
        guard let dockEngine else { return }
        let controller = settings ?? SettingsWindowController(dockModel: dockModel, layout: dockEngine.layout)
        controller.onActivationPolicyChanged = { [weak dockEngine] in dockEngine?.activationPolicyChanged() }
        settings = controller
        controller.show()
    }

    /// Pick one or more apps to pin. This is an explicit user action, so it
    /// is fine (and required) for Portside to activate to show the open panel.
    func addApps() {
        let model = dockModel
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.application]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.prompt = "Add to Dock"
        NSApp.activate()
        guard picker.runModal() == .OK else { return }
        for url in picker.urls {
            if let app = PinnedApp(appURL: url) {
                model.pin(app)
            }
        }
    }
}
