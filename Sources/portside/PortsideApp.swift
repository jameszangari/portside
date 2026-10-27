import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI entry point. There is no main window: the only scene is a tiny
/// menu bar item. All the real work happens in `AppDelegate` -> `DockEngine`.
@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Portside", systemImage: "bird") {
            Text("Portside (Milestone C)")
            Divider()
            Button("Add App to Dock...") {
                appDelegate.addApps()
            }
            WidgetsMenu(dockModel: appDelegate.dockModel)
            Divider()
            Button("Quit Portside") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created with the delegate so the menu bar scene can observe it.
    let dockModel = DockModel.load()
    private var dockEngine: DockEngine?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // An SPM executable has no bundle, so LSUIElement in Info.plist is
        // ignored. Accessory policy = no Dock icon, no menu bar takeover,
        // and we never become the active app on launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = DockEngine(dockModel: dockModel)
        dockEngine = engine
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockEngine?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
