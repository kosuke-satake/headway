import Foundation
import HeadwayCore
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
    // Favourites, saved places and trips, and recents are the user's own data, not settings: keep them.
    var fresh = Preferences()
    fresh.favoriteStops = values.favoriteStops
    fresh.favoriteRoutes = values.favoriteRoutes
    fresh.recentStops = values.recentStops
    fresh.savedPlaces = values.savedPlaces
    fresh.savedTrips = values.savedTrips
    fresh.recentTrips = values.recentTrips
    fresh.watchedRoutes = values.watchedRoutes
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

  // MARK: Saved places and trips

  func save(place point: PlanPoint, as kind: PlaceKind, name: String? = nil) {
    // Home and work exist once: saving a new one replaces the old.
    if kind != .other { values.savedPlaces.removeAll { $0.kind == kind } }
    values.savedPlaces.removeAll { $0.kind == .other && StoredEnd(.point(point)).matches(StoredEnd(.point($0.point))) }
    let label = name ?? (kind == .home ? String(localized: "Home") : kind == .work ? String(localized: "Work") : point.name)
    var place = StoredPlace(name: label, kind: kind, point: point)
    place.name = label
    values.savedPlaces.append(place)
  }

  func place(of kind: PlaceKind) -> StoredPlace? { values.savedPlaces.first { $0.kind == kind } }

  func savedPlace(matching point: PlanPoint) -> StoredPlace? {
    values.savedPlaces.first { StoredEnd(.point($0.point)).matches(StoredEnd(.point(point))) }
  }

  func removePlace(_ id: String) { values.savedPlaces.removeAll { $0.id == id } }

  /// Changes a saved place: its name, what it is (Home and Work exist once, so taking the role from another place
  /// turns that one into an ordinary place) or where it is.
  func update(place id: String, name: String? = nil, kind: PlaceKind? = nil, point: PlanPoint? = nil) {
    guard let index = values.savedPlaces.firstIndex(where: { $0.id == id }) else { return }
    if let name { values.savedPlaces[index].name = name }
    if let kind, kind != values.savedPlaces[index].kind {
      if kind != .other {
        for other in values.savedPlaces.indices where other != index && values.savedPlaces[other].kind == kind {
          values.savedPlaces[other].kind = .other
        }
      }
      values.savedPlaces[index].kind = kind
    }
    if let point {
      values.savedPlaces[index].latitude = point.coordinate.latitude
      values.savedPlaces[index].longitude = point.coordinate.longitude
      values.savedPlaces[index].stopID = point.stopID
    }
  }

  func isSaved(from: PlaceChoice, to: PlaceChoice, vias: [StoredVia] = []) -> Bool {
    let f = StoredEnd(from), t = StoredEnd(to)
    return values.savedTrips.contains { $0.matches(from: f, to: t, vias: vias) }
  }

  func toggleSaved(from: PlaceChoice, to: PlaceChoice, vias: [StoredVia] = []) {
    let f = StoredEnd(from), t = StoredEnd(to)
    if let index = values.savedTrips.firstIndex(where: { $0.matches(from: f, to: t, vias: vias) }) {
      values.savedTrips.remove(at: index)
    } else {
      values.savedTrips.append(SavedTrip(from: f, to: t, vias: vias))
    }
  }

  func noteRecent(from: PlaceChoice, to: PlaceChoice, vias: [StoredVia] = []) {
    let f = StoredEnd(from), t = StoredEnd(to)
    var recents = values.recentTrips.filter { !$0.matches(from: f, to: t, vias: vias) }
    recents.insert(SavedTrip(from: f, to: t, vias: vias), at: 0)
    values.recentTrips = Array(recents.prefix(30))
  }
}
