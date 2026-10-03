import SwiftUI

@main
struct HeadwayApp: App {
  @State private var model = AppModel(settings: AppSettings())

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .task { await model.start() }
    }
  }
}
