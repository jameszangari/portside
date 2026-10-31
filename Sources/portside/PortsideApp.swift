import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Process entry point. Runs before SwiftUI and AppKit start, so native
/// Dock crash recovery happens before anything else, and
/// `portside --restore-dock` can restore and exit without showing any UI.
@main
enum PortsideMain {
    /// Kept alive for the life of the process.
    private static var signalSources: [DispatchSourceSignal] = []

    static func main() {
        if CommandLine.arguments.contains("--restore-dock") {
            exit(restoreDockCommand())
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-icon") {
            exit(exportIconCommand(argumentIndex: index))
        }
        NativeDock.recoverIfNeeded()
        installSignalHandlers()
        PortsideApp.main()
    }

    /// `portside --restore-dock`: restore from the backup file and exit.
    private static func restoreDockCommand() -> Int32 {
        do {
            switch try NativeDock.restore() {
            case .restored:
                print("Restored the macOS Dock from \(NativeDock.backupURL.path)")
            case .nothingToRestore:
                print("No backup at \(NativeDock.backupURL.path). Portside has not changed the macOS Dock.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("portside: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// `portside --export-icon <path.png>`: writes the app icon as a 1024px
    /// PNG and exits. Hidden; scripts/build-app.sh uses it for AppIcon.icns.
    private static func exportIconCommand(argumentIndex: Int) -> Int32 {
        let arguments = CommandLine.arguments
        guard argumentIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: portside --export-icon <path.png>\n".utf8))
            return 2
        }
        let url = URL(fileURLWithPath: arguments[argumentIndex + 1])
        do {
            try AppIcon.writePNG(to: url, pixels: 1024)
            print("Wrote \(url.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("portside: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Ctrl+C, `kill`, and closing the terminal would otherwise end the
    /// process without applicationWillTerminate. SIGKILL cannot be caught;
    /// the next launch's recovery covers it.
    private static func installSignalHandlers() {
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                NativeDockController.restoreForExit(reason: name)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// SwiftUI app. There is no main window: the only scene is a tiny menu bar
/// item. All the real work happens in `AppDelegate` -> `DockEngine`.
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Text("Portside")
            Divider()
            Button("About Portside") {
                appDelegate.showAbout()
            }
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
            Button("Restore macOS Dock") {
                appDelegate.nativeDock.restoreFromMenu()
            }
            Divider()
            Button("Quit Portside") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // Temporary: icon plus text so the item is easy to spot and to
            // find in Bartender's item list. Back to icon only before release.
            HStack(spacing: 4) {
                // Template image (brand mark, black with alpha): macOS tints
                // it for light, dark, and tinted menu bars.
                Image(nsImage: BrandAssets.menuBarIcon)
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
    lazy var nativeDock = NativeDockController(dockModel: dockModel)
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
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.applicationIconImage = AppIcon.image
        }
        nativeDock.applyAtLaunch()
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
        NativeDockController.restoreForExit(reason: "applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A normal window, so Portside activates while it is open. The dock
    /// panel itself stays non-activating.
    func openSettings() {
        guard let dockEngine else { return }
        let controller = settings ?? SettingsWindowController(dockModel: dockModel, layout: dockEngine.layout, nativeDock: nativeDock, trash: dockEngine.trash)
        controller.onActivationPolicyChanged = { [weak dockEngine] in dockEngine?.activationPolicyChanged() }
        settings = controller
        controller.show()
    }

    /// The standard About panel with the brand icon, the version from
    /// BuildInfo (plus the short hash on unreleased builds), and credits.
    /// Activates Portside so the panel comes forward, like Settings.
    func showAbout() {
        let credits = NSMutableAttributedString(
            string: "by \(AppInfo.author)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: AppInfo.repoURL.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repoURL]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationIcon: AppIcon.image,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.buildSuffix ?? "",
            .credits: credits,
        ])
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
