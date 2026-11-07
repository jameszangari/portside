import Carbon.HIToolbox
import Combine
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
        if let index = CommandLine.arguments.firstIndex(of: "--install-update") {
            exit(UpdateChecker.installFromCommandLine(arguments: CommandLine.arguments, flagIndex: index))
        }
        if CommandLine.arguments.contains("--resave-settings") {
            exit(resaveSettingsCommand())
        }
        if CommandLine.arguments.contains("--check-updates") {
            exit(checkUpdatesCommand())
        }
        #if DEBUG
        if CommandLine.arguments.contains("--check-notch") {
            exit(MainActor.assumeIsolated { AgentNotchProbe.run() })
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-notch-previews"), index + 1 < CommandLine.arguments.count {
            exit(MainActor.assumeIsolated { AgentNotchProbe.render(to: CommandLine.arguments[index + 1]) })
        }
        if CommandLine.arguments.contains("--check-audio-levels") {
            exit(MainActor.assumeIsolated { AudioPlaybackProbe.run(capture: CommandLine.arguments.contains("--capture")) })
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-label-previews"), index + 1 < CommandLine.arguments.count {
            exit(MainActor.assumeIsolated { WidgetPreviews.renderLabels(to: CommandLine.arguments[index + 1]) })
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-widget-previews"), index + 1 < CommandLine.arguments.count {
            exit(MainActor.assumeIsolated { WidgetPreviews.render(to: CommandLine.arguments[index + 1]) })
        }
        #endif
        if let flag = CommandLine.arguments.firstIndex(of: "--print-usage") {
            exit(UsageFetcher.printAll(only: CommandLine.arguments.dropFirst(flag + 1).first))
        }
        // Same as Settings > Widgets > Agent Hooks.
        for (flag, action) in [("--install-agent-hooks", AgentHooks.install), ("--remove-agent-hooks", AgentHooks.uninstall)]
        where CommandLine.arguments.contains(flag) {
            do {
                try action()
                for target in AgentHooks.targets {
                    print("\(target.name): \(AgentHooks.status(target))")
                }
                exit(0)
            } catch {
                print("portside: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--watch-native-dock"), flag + 1 < CommandLine.arguments.count,
           let pid = pid_t(CommandLine.arguments[flag + 1]) {
            NativeDock.runWatchdog(watching: pid)
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

    /// `portside --resave-settings`: load dock.json and write it back through
    /// the normal save path (unknown keys kept, version stamped), then exit.
    /// Hidden; used to check preference retention without the UI.
    private static func resaveSettingsCommand() -> Int32 {
        do {
            try DockModel.load().save()
            print("Saved dock.json as \(AppInfo.version)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("portside: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// `portside --check-updates`: run the same check as the Settings button
    /// and print the result. Hidden; no UI, no install.
    private static func checkUpdatesCommand() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        var result = UpdateCheckResult.notConfigured
        Task.detached {
            result = await UpdateChecker.check()
            done.signal()
        }
        done.wait()
        print(result.message)
        if case .failed = result { return 1 }
        return 0
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
                WindowFitter.releaseForExit(reason: name)
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
            UpdateMenuItem()
            Button("About Portside") {
                appDelegate.showAbout()
            }
            Button("Settings...") {
                appDelegate.runOpenSettingsCommand()
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
            // Template image (brand mark, black with alpha): macOS tints it
            // for light, dark, and tinted menu bars. Icon only, so menu bar
            // managers like Bartender see a standard-width item.
            PortsideMenuBarLabel()
        }
    }
}

// MARK: - App Delegate

/// Checkbox per catalog widget.
private struct WidgetsMenu: View {
    @ObservedObject var dockModel: DockModel

    var body: some View {
        Menu("Widgets") {
            ForEach(WidgetCatalog.allKinds, id: \.self) { kind in
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
    private var agentNotch: AgentNotch?
    private var dockEngine: DockEngine?
    private var settings: SettingsWindowController?
    private var hideHotKey: HotKey?
    private var settingsHotKey: HotKey?
    private var settingsHotKeyObserver: AnyCancellable?
    private let permissions = PermissionGate()
    private lazy var commands = CommandRegistry(permissions: permissions)
    private lazy var modules = ModuleRegistry(commands: commands, permissions: permissions)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // An SPM executable has no bundle, so LSUIElement in Info.plist is
        // ignored. Accessory policy = no Dock icon, no menu bar takeover,
        // and we never become the active app on launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar / edge-only: keep running when no titled windows are open
        // (otherwise AppKit may terminate a background `swift run` launch).
        ProcessInfo.processInfo.disableAutomaticTermination("portside dock")
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.applicationIconImage = AppIcon.image
        }
        registerCommands()
        nativeDock.applyAtLaunch()
        BackgroundCursor.enable()
        let engine = DockEngine(dockModel: dockModel)
        dockEngine = engine
        engine.onOpenSettings = { [weak self] in self?.runOpenSettingsCommand() }
        engine.start()
        agentNotch = AgentNotch(model: dockModel, widgets: engine.widgets)
        UpdateMonitor.shared.start(model: dockModel)
        if dockModel.openSettingsOnLaunch { runOpenSettingsCommand() }
        // The native Dock's own shortcut. If macOS's "Turn Dock hiding
        // on/off" shortcut is enabled it may take the keypress first.
        hideHotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: cmdKey | optionKey, name: "Cmd+Option+D") { [weak self] in
            self?.toggleAutoHide()
        }
        // Re-register whenever Settings changes the chord (including Clear).
        settingsHotKeyObserver = dockModel.$settingsHotkey
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chord in
                self?.registerSettingsHotKey(chord)
            }
    }

    private func registerSettingsHotKey(_ chord: HotkeyChord?) {
        settingsHotKey = nil
        guard let chord else { return }
        settingsHotKey = HotKey(chord: chord, name: "Open Settings \(chord.displayString)") { [weak self] in
            self?.runOpenSettingsCommand()
        }
    }

    private func registerCommands() {
        MainActor.assumeIsolated {
            permissions.register(AccessibilityPermissionAdapter())
            let core = PortsideCoreModule(
                isStarting: { [weak self] in self?.dockEngine == nil },
                openSettings: { [weak self] in self?.openSettings() }
            )
            do {
                try modules.register(core)
                modules.enableSaved(dockModel.modules)
            } catch {
                NSLog("portside: command registration failed: \(error)")
            }
        }
    }

    func runOpenSettingsCommand() {
        Task { @MainActor [commands] in
            _ = await commands.execute(PortsideCoreModule.openSettingsCommand)
        }
    }

    func toggleAutoHide() {
        dockModel.setAutoHide(!dockModel.autoHide)
    }

    /// Clicking Portside's icon in the native Dock (it is there while
    /// Settings is open) brings Settings forward, like any app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runOpenSettingsCommand()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowFitter.releaseForExit(reason: "applicationWillTerminate")
        agentNotch?.stop()
        MainActor.assumeIsolated { modules.stopAll() }
        UpdateMonitor.shared.stop()
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
        let controller = settings ?? SettingsWindowController(dockModel: dockModel, layout: dockEngine.layout, nativeDock: nativeDock, trash: dockEngine.trash, badges: dockEngine.badges, widgets: dockEngine.widgets)
        controller.onActivationPolicyChanged = { [weak dockEngine] in dockEngine?.activationPolicyChanged() }
        controller.onKeyFocusChanged = { [weak dockEngine] focused in
            dockEngine?.settingsKeyFocusChanged(focused)
        }
        controller.usableFrame = { [weak dockEngine] screen in
            dockEngine?.reservation.usableFrame(of: screen) ?? screen.visibleFrame
        }
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
