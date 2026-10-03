import Foundation
import Testing

@testable import Headway

@Suite struct PreferencesTests {
  private func decode(_ json: String) throws -> Preferences {
    try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
  }

  @Test func missingKeysFallBackToDefaults() throws {
    let prefs = try decode(#"{"routePalette":"distinct","markerSize":"large"}"#)
    #expect(prefs.routePalette == .distinct)
    #expect(prefs.markerSize == .large)
    #expect(prefs.updateInterval == 10)
    #expect(prefs.showRouteNameOnBuses)
    #expect(prefs.favoriteStops.isEmpty)
  }

  @Test func unknownValuesFallBackInsteadOfFailing() throws {
    let prefs = try decode(#"{"appearance":"sepia","updateInterval":7,"stopVisibility":42}"#)
    #expect(prefs.appearance == .system)
    #expect(prefs.updateInterval == 10)
    #expect(prefs.stopVisibility == .zoomed)
  }

  @Test func lineWidthIsClamped() throws {
    #expect(try decode(#"{"routeLineWidth":9}"#).routeLineWidth == 1.6)
    #expect(try decode(#"{"routeLineWidth":0.1}"#).routeLineWidth == 0.6)
  }

  @Test func roundTrips() throws {
    var prefs = Preferences()
    prefs.hiddenRoutes = ["A", "80"]
    prefs.favoriteStops = ["10081", "1"]
    prefs.lastLatitude = 43.07
    prefs.clockFormat = .twentyFourHour
    let data = try JSONEncoder().encode(prefs)
    #expect(try JSONDecoder().decode(Preferences.self, from: data) == prefs)
  }

  @Test func mapPreferencesIgnoreTheCameraPosition() {
    var a = Preferences()
    var b = a
    b.lastLatitude = 43.1
    b.lastZoom = 15
    #expect(MapPreferences(a) == MapPreferences(b))
    a.markerSize = .large
    #expect(MapPreferences(a) != MapPreferences(b))
  }
}

@MainActor @Suite struct AppSettingsTests {
  private func makeSettings() -> AppSettings {
    let suite = "headway-tests-\(UUID().uuidString)"
    return AppSettings(defaults: UserDefaults(suiteName: suite)!)
  }

  @Test func persistsChanges() {
    let suite = "headway-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let first = AppSettings(defaults: defaults)
    first.values.routePalette = .quiet
    first.toggleFavorite(stop: "7")
    let second = AppSettings(defaults: defaults)
    #expect(second.values.routePalette == .quiet)
    #expect(second.values.favoriteStops == ["7"])
  }

  @Test func resetKeepsUserData() {
    let settings = makeSettings()
    settings.values.markerSize = .small
    settings.toggleFavorite(stop: "7")
    settings.toggleFavorite(route: "A")
    settings.noteRecent(stop: "9")
    settings.reset()
    #expect(settings.values.markerSize == .medium)
    #expect(settings.values.favoriteStops == ["7"])
    #expect(settings.values.favoriteRoutes == ["A"])
    #expect(settings.values.recentStops == ["9"])
  }

  @Test func recentsAreUniqueAndCapped() {
    let settings = makeSettings()
    for id in 1...12 { settings.noteRecent(stop: "\(id)") }
    settings.noteRecent(stop: "5")
    #expect(settings.values.recentStops.count == 8)
    #expect(settings.values.recentStops.first == "5")
    #expect(Set(settings.values.recentStops).count == 8)
  }
}
