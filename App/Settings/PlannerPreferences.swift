import Foundation
import HeadwayCore

enum PlaceKind: String, Codable, CaseIterable, Identifiable {
  case home, work, other
  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .home: "house.fill"
    case .work: "briefcase.fill"
    case .other: "star.fill"
    }
  }
}

/// A place the rider saved: home, work, or any other.
struct StoredPlace: Codable, Hashable, Identifiable {
  var id: String = UUID().uuidString
  var name: String
  var kind: PlaceKind = .other
  var latitude: Double
  var longitude: Double
  /// Set when the place is a bus stop.
  var stopID: String?

  init(name: String, kind: PlaceKind = .other, point: PlanPoint) {
    self.name = name
    self.kind = kind
    latitude = point.coordinate.latitude
    longitude = point.coordinate.longitude
    stopID = point.stopID
  }

  var point: PlanPoint {
    PlanPoint(name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude), stopID: stopID)
  }
}

/// One end of a saved trip: the rider's location at the time, or a fixed place.
struct StoredEnd: Codable, Hashable {
  var isMyLocation: Bool
  var place: StoredPlace?

  init(_ choice: PlaceChoice) {
    switch choice {
    case .myLocation:
      isMyLocation = true
      place = nil
    case .point(let point):
      isMyLocation = false
      place = StoredPlace(name: point.name, point: point)
    }
  }

  var choice: PlaceChoice { isMyLocation ? .myLocation : .point(place?.point ?? PlanPoint(name: "", coordinate: Coordinate(latitude: 0, longitude: 0))) }
  var title: String { isMyLocation ? String(localized: "My location") : (place?.name ?? "") }

  /// Two ends are the same when they are the same place, whatever id each copy was given.
  func matches(_ other: StoredEnd) -> Bool {
    if isMyLocation || other.isMyLocation { return isMyLocation == other.isMyLocation }
    guard let a = place, let b = other.place else { return false }
    if let x = a.stopID, let y = b.stopID { return x == y }
    return abs(a.latitude - b.latitude) < 0.0002 && abs(a.longitude - b.longitude) < 0.0002
  }
}

/// A place stopped at on the way, and for how long.
struct StoredVia: Codable, Hashable {
  var end: StoredEnd
  var dwellMinutes: Int

  func matches(_ other: StoredVia) -> Bool { end.matches(other.end) && dwellMinutes == other.dwellMinutes }
}

/// A trip the rider keeps, or searched recently.
struct SavedTrip: Codable, Hashable, Identifiable {
  var id: String = UUID().uuidString
  var from: StoredEnd
  var to: StoredEnd
  /// Places stopped at between the start and the destination; nil (absent in older saves) for an ordinary trip.
  var vias: [StoredVia]?
  var date: Date = Date()

  init(from: StoredEnd, to: StoredEnd, vias: [StoredVia] = []) {
    self.from = from
    self.to = to
    self.vias = vias.isEmpty ? nil : vias
  }

  var stops: [StoredVia] { vias ?? [] }

  var title: String { ([from.title] + stops.map(\.end.title) + [to.title]).joined(separator: " → ") }

  func matches(from f: StoredEnd, to t: StoredEnd, vias v: [StoredVia] = []) -> Bool {
    guard from.matches(f), to.matches(t), stops.count == v.count else { return false }
    return zip(stops, v).allSatisfy { $0.matches($1) }
  }
}

enum WalkSpeed: String, Codable, CaseIterable, Identifiable {
  case slow, normal, fast
  var id: String { rawValue }
  /// Metres per second.
  var metersPerSecond: Double {
    switch self {
    case .slow: 1.0
    case .normal: 1.25
    case .fast: 1.5
    }
  }
}

enum JourneySort: String, Codable, CaseIterable, Identifiable {
  case departure, arrival, fewestTransfers, leastWalking
  var id: String { rawValue }
}
