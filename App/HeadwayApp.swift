import SwiftUI
import UserNotifications

@main
struct HeadwayApp: App {
  @State private var model = AppModel(settings: AppSettings())

  init() {
    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .task { await model.start() }
    }
  }
}
