import Foundation
import HeadwayCore
import Testing

@testable import Headway

@Suite struct WatchNotifierTests {
  private func event(_ kind: WatchKind, seconds: Int = 0, buses: Int = 0, headline: String = "", detail: String = "") -> WatchEvent {
    WatchEvent(kind: kind, routeID: "A", buses: buses, seconds: seconds, alertID: "x", headline: headline, detail: detail)
  }

  @Test func lateAndEarlyMessagesMentionTheRouteAndMinutes() {
    let late = WatchNotifier.text(for: event(.late, seconds: 600, buses: 2), routeName: "B")
    #expect(late.title.contains("B"))
    #expect(late.body.contains("10"))
    let early = WatchNotifier.text(for: event(.early, seconds: 200, buses: 1), routeName: "B")
    #expect(early.title.contains("B"))
    #expect(early.body.contains("3"))
  }

  @Test func alertsUseTheirOwnHeadlineAndAShortenedText() {
    let long = String(repeating: "detour ", count: 60)
    let text = WatchNotifier.text(for: event(.alert, headline: "A - State detour", detail: long), routeName: "A")
    #expect(text.title == "A - State detour")
    #expect(text.body.count <= 160)
  }

  @Test func anAlertWithoutTextStillSaysWhichRoute() {
    let text = WatchNotifier.text(for: event(.alert), routeName: "J")
    #expect(text.title.contains("J"))
    #expect(text.body.contains("J"))
  }

  @MainActor @Test func watchedRoutesSurviveResettingSettings() {
    let defaults = UserDefaults(suiteName: "watch-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.values.watchedRoutes = ["A", "J"]
    settings.values.watchEnabled = true
    settings.reset()
    #expect(settings.values.watchedRoutes == ["A", "J"])
    #expect(!settings.values.watchEnabled)
  }
}
