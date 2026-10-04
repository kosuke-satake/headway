import SwiftUI
import UserNotifications

@main
struct HeadwayApp: App {
  @State private var model: AppModel

  init() {
    let model = AppModel(settings: AppSettings())
    _model = State(initialValue: model)
    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    WatchBackground.register(model)
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .task { await model.start() }
    }
  }
}
