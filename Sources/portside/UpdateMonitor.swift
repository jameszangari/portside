import AppKit
import Combine
import SwiftUI
import UserNotifications

/// Background release discovery; installation still uses the verified updater.
final class UpdateMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateMonitor()
    @Published private(set) var offer: UpdateOffer?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var window: NSWindow?
    private var notifiedVersion = UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion")
    private var openAfterCheck = false

    func start(model: DockModel) {
        if UpdateChecker.canInstallInPlace {
            UNUserNotificationCenter.current().delegate = self
        }
        subscription = model.$automaticUpdateChecks.receive(on: DispatchQueue.main).sink { [weak self] enabled in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.generation = UUID()
            self.task?.cancel()
            self.task = nil
            guard enabled, UpdateChecker.canInstallInPlace else { return }
            self.check()
            let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
            timer.tolerance = 600
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        task?.cancel()
        task = nil
        subscription = nil
    }

    private func check() {
        guard task == nil else { return }
        let generation = self.generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.task = nil } }
            let result = await UpdateChecker.check()
            guard !Task.isCancelled else { return }
            guard case .available(let version, let releaseURL, let dmgURL) = result else {
                if self.openAfterCheck {
                    self.openAfterCheck = false
                    let alert = NSAlert()
                    alert.messageText = result.message
                    NSApp.activate()
                    alert.runModal()
                }
                return
            }
            self.offer = UpdateOffer(version: version, releaseURL: releaseURL, dmgURL: dmgURL)
            if self.openAfterCheck {
                self.openAfterCheck = false
                self.showOffer()
                return
            }
            guard self.notifiedVersion != version else { return }
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard allowed, !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = "Portside \(version) is available"
            content.body = "Open to review the update and install it. Your settings are kept."
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "portside-update", content: content, trigger: nil))
                self.notifiedVersion = version
                UserDefaults.standard.set(version, forKey: "lastNotifiedUpdateVersion")
            } catch { /* The menu bar offer remains available if notifications fail. */ }
        }
    }

    func showOffer() {
        guard let offer else { return }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let content = NSHostingController(rootView: UpdateSheet(offer: offer) { [weak self] in
            self?.window?.close()
            self?.window = nil
        })
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = "Portside Update"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.offer != nil {
                self.showOffer()
            } else {
                self.openAfterCheck = true
                self.check()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct UpdateMenuItem: View {
    @ObservedObject private var monitor = UpdateMonitor.shared
    var body: some View {
        if let offer = monitor.offer {
            Button("Update to Portside \(offer.version)…") { monitor.showOffer() }
        }
    }
}

struct PortsideMenuBarLabel: View {
    @ObservedObject private var monitor = UpdateMonitor.shared
    var body: some View {
        Image(nsImage: BrandAssets.menuBarIcon)
            .overlay(alignment: .topTrailing) {
                if monitor.offer != nil {
                    Circle().fill(.primary).frame(width: 5, height: 5)
                }
            }
            .accessibilityLabel(monitor.offer == nil ? "Portside" : "Portside, update available")
    }
}
