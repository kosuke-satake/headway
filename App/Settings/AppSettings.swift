import Foundation
import Observation

/// Observable, persistent user preferences.
@MainActor @Observable
final class AppSettings {
  var values: Preferences {
    didSet { if values != oldValue { save() } }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key = "preferences.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
      values = decoded
    } else {
      values = Preferences()
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
  }

  func reset() {
    // Favourites and recents are the user's own data, not settings: keep them.
    var fresh = Preferences()
    fresh.favoriteStops = values.favoriteStops
    fresh.favoriteRoutes = values.favoriteRoutes
    fresh.recentStops = values.recentStops
    values = fresh
  }

  // MARK: Favourites and recents

  func isFavorite(stop id: String) -> Bool { values.favoriteStops.contains(id) }
  func isFavorite(route id: String) -> Bool { values.favoriteRoutes.contains(id) }

  func toggleFavorite(stop id: String) {
    if let index = values.favoriteStops.firstIndex(of: id) {
      values.favoriteStops.remove(at: index)
    } else {
      values.favoriteStops.append(id)
    }
  }

  func toggleFavorite(route id: String) {
    if let index = values.favoriteRoutes.firstIndex(of: id) {
      values.favoriteRoutes.remove(at: index)
    } else {
      values.favoriteRoutes.append(id)
    }
  }

  func noteRecent(stop id: String) {
    var recents = values.recentStops.filter { $0 != id }
    recents.insert(id, at: 0)
    values.recentStops = Array(recents.prefix(8))
  }

  func setRoute(_ id: String, hidden: Bool) {
    if hidden { values.hiddenRoutes.insert(id) } else { values.hiddenRoutes.remove(id) }
  }
}
