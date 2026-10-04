import BackgroundTasks
import Foundation
import HeadwayCore
import SwiftUI
import UserNotifications

/// Tells the rider when a route they watch is late, early or has an alert.
///
/// These are local notifications: no server and no paid developer account are involved, so they are only as timely as
/// the app's own checks. Headway checks every time the live feed updates while it is open, and now and then in the
/// background when iOS allows it (see `WatchBackground`).
@MainActor
final class WatchNotifier {
  private let defaults: UserDefaults
  private let key = "watch.ledger.v1"
  private var ledger: WatchLedger

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    ledger = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WatchLedger.self, from: $0) }) ?? WatchLedger()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: key) }
  }

  /// Asks for permission the first time; true when notifications may be shown.
  static func authorize() async -> Bool {
    let center = UNUserNotificationCenter.current()
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: return true
    case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    default: return false
    }
  }

  /// Announces the events that the rider has not been told about recently.
  func deliver(_ events: [WatchEvent], now: Date, routeName: (String) -> String) async {
    let fresh = ledger.fresh(events, now: now)
    save()
    guard !fresh.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .authorized else { return }
    for event in fresh {
      let text = Self.text(for: event, routeName: routeName(event.routeID))
      let content = UNMutableNotificationContent()
      content.title = text.title
      content.body = text.body
      content.sound = .default
      content.threadIdentifier = "headway.watch.\(event.routeID)"
      try? await center.add(UNNotificationRequest(identifier: "headway.watch.\(event.id)", content: content, trigger: nil))
    }
  }

  func forget() {
    ledger = WatchLedger()
    save()
  }

  /// The words of a notification.
  nonisolated static func text(for event: WatchEvent, routeName: String) -> (title: String, body: String) {
    let minutes = max(1, Int((Double(event.seconds) / 60).rounded()))
    switch event.kind {
    case .late:
      return (
        String(localized: "Route \(routeName) is running late"),
        String(localized: "Up to \(minutes) min behind the timetable · \(event.buses) buses")
      )
    case .early:
      return (
        String(localized: "Route \(routeName) is running early"),
        String(localized: "Up to \(minutes) min ahead of the timetable · \(event.buses) buses. Be at your stop a little early.")
      )
    case .alert:
      let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      let body = detail.isEmpty ? String(localized: "Route \(routeName)") : String(detail.prefix(160))
      return (event.headline.isEmpty ? String(localized: "Route \(routeName)") : event.headline, body)
    }
  }
}

/// Checks the routes the rider watches now and then while the app is in the background.
///
/// iOS decides when (and whether) this runs: typically no more often than every 15 minutes, less often when the phone
/// is idle or the battery is low, and rarely for an app that is not opened regularly. It is a best effort, not an alarm.
enum WatchBackground {
  static let identifier = "dev.kosuke.headway.watch"

  /// Must be called before the app finishes launching.
  @MainActor static func register(_ model: AppModel) {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let task = task as? BGAppRefreshTask else { return }
      let work = Task { @MainActor in
        await model.runBackgroundWatch()
        schedule(enabled: model.settings.values.watchEnabled)
        task.setTaskCompleted(success: true)
      }
      task.expirationHandler = { work.cancel() }
    }
  }

  /// Asks iOS for the next check (or cancels it when nothing is watched).
  static func schedule(enabled: Bool) {
    guard enabled else {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
      return
    }
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}

extension View {
  /// Explains how to allow notifications after the rider asked for one while they are off.
  func notificationsDeniedAlert() -> some View { modifier(NotificationsDeniedAlert()) }
}

private struct NotificationsDeniedAlert: ViewModifier {
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    content.alert(
      "Notifications are turned off", isPresented: Binding(get: { model.notificationsDenied }, set: { model.notificationsDenied = $0 })
    ) {
      if let url = URL(string: UIApplication.openSettingsURLString) {
        Button("Open Settings") { UIApplication.shared.open(url) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Allow notifications for Headway in the iPhone's Settings to get these messages.")
    }
  }
}
