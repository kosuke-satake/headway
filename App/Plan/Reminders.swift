import Foundation
import HeadwayCore
import UserNotifications

/// Shows reminders even while the app is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationDelegate()

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}

/// A reminder to leave in time for a journey. These are local notifications: they need no server and no paid
/// developer account. They use the times known when the reminder was set, so a bus that gets later or earlier
/// afterwards is not reflected.
enum Reminders {
  enum Outcome {
    case scheduled(fireAt: Date)
    case denied
    case tooLate
  }

  static func identifier(for journey: Journey) -> String { "headway.reminder.\(journey.id)" }

  static func isScheduled(_ journey: Journey) async -> Bool {
    await UNUserNotificationCenter.current().pendingNotificationRequests().contains { $0.identifier == identifier(for: journey) }
  }

  static func cancel(_ journey: Journey) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(for: journey)])
  }

  static func schedule(_ journey: Journey, leadMinutes: Int, body: String) async -> Outcome {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return .denied }
    } else if settings.authorizationStatus == .denied {
      return .denied
    }
    let fireAt = journey.departure.addingTimeInterval(-Double(leadMinutes) * 60)
    guard fireAt.timeIntervalSinceNow > 5 else { return .tooLate }
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Time to leave")
    content.body = body
    content.sound = .default
    content.interruptionLevel = .timeSensitive
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSinceNow, repeats: false)
    do {
      try await center.add(UNNotificationRequest(identifier: identifier(for: journey), content: content, trigger: trigger))
      return .scheduled(fireAt: fireAt)
    } catch {
      return .denied
    }
  }
}
