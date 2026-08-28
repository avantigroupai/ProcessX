import Foundation
import UserNotifications

/// Bridges "this is slowing your Mac down" to macOS Notification Center.
///
/// This app spends nearly all its life in the menu bar with no window or
/// popover open — the two surfaces every other confirmation in this codebase
/// (`.confirmationDialog`) depends on. A system notification is the one UI
/// that reaches the user regardless, and its action buttons let Cap or Slow
/// down fire straight from the banner with the app still in the background.
@MainActor
final class SlowProcessAlerter: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "SLOW_OR_CAP"
    private static let actionSlow = "SLOW_DOWN"
    private static let actionCap = "CAP"

    private unowned let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let slow = UNNotificationAction(identifier: Self.actionSlow, title: "Slow Down", options: [])
        let cap = UNNotificationAction(identifier: Self.actionCap, title: "Cap", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.category, actions: [slow, cap],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// One notification per hot group, offering both mechanisms with the
    /// tradeoff spelled out in the body — this is the only surface the user
    /// sees before choosing, since an action button fires with no app window
    /// open to show anything else.
    func alert(key: String, name: String, cpuPercent: Double, offerCap: Bool) {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            switch status {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { denied(name: name, cpuPercent: cpuPercent); return }
            case .denied:
                denied(name: name, cpuPercent: cpuPercent)
                return
            default:
                break
            }

            let intro = "It's used \(Int(cpuPercent.rounded()))% of a core for a while."
            let slowDoes = "Slow Down lowers its scheduling priority — gentle, instant to undo, "
                + "but it only helps when something else is competing for the CPU."
            let capDoes: String
            if offerCap {
                capDoes = "Cap holds it to a hard \(Int(Monitor.alertCapPercent))% ceiling by pausing "
                    + "and resuming it — stronger, but it can't respond while paused, so a live "
                    + "connection or a call can stutter or drop."
            } else {
                capDoes = "It can't be capped right now — nothing in it may be suspended."
            }

            let content = UNMutableNotificationContent()
            content.title = "\(name) is slowing down your Mac"
            content.body = [intro, slowDoes, capDoes].joined(separator: " ")
            content.categoryIdentifier = Self.category
            content.userInfo = ["key": key]
            content.sound = .default

            let request = UNNotificationRequest(identifier: "slow-\(key)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// No permission to show the real thing — say it in-app instead of going
    /// silent, for whoever still has the window or popover open to see it.
    private func denied(name: String, cpuPercent: Double) {
        monitor.lastMessage = "\(name) is using \(Int(cpuPercent.rounded()))% of a core — "
            + "enable notifications for ProcessX to get Cap/Slow Down prompts"
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionID = response.actionIdentifier
        guard let key = response.notification.request.content.userInfo["key"] as? String else {
            completionHandler()
            return
        }
        Task { @MainActor in
            switch actionID {
            case Self.actionSlow: monitor.slowDownFromAlert(key: key)
            case Self.actionCap: monitor.capFromAlert(key: key)
            default: break   // opened the app by clicking the body — nothing further to do
            }
            completionHandler()
        }
    }
}
