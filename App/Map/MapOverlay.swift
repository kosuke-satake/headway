import CoreLocation
import Foundation
import HeadwayCore

/// What the map draws of the timetable: route lines, stops and which routes serve them.
///
/// Parsing the timetable takes a moment on every launch, so a compact copy of what the map needs is saved after
/// each parse. The next launch reads that copy and shows every route at once, while the full timetable loads in the
/// background.
struct MapOverlayData: Codable, Equatable, Sendable {
  static let currentVersion = 1

  struct RouteInfo: Codable, Equatable, Sendable {
    var id: String
    var shortName: String
    var longName: String
    var colorHex: String
    var textColorHex: String
    var sortOrder: Int
  }

  /// One route line in one direction, as parallel arrays of coordinates.
  struct Line: Codable, Equatable, Sendable {
    var route: String
    var direction: Int
    var latitudes: [Double]
    var longitudes: [Double]
  }

  struct StopInfo: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var code: String
    var latitude: Double
    var longitude: Double
  }

  var version = MapOverlayData.currentVersion
  var feedVersion: String
  var routes: [RouteInfo]
  var lines: [Line]
  var stops: [StopInfo]
  var network: RouteNetwork

  init(feedVersion: String, routes: [RouteInfo], lines: [Line], stops: [StopInfo], network: RouteNetwork) {
    self.feedVersion = feedVersion
    self.routes = routes
    self.lines = lines
    self.stops = stops
    self.network = network
  }

  init(schedule: Schedule, network: RouteNetwork) {
    feedVersion = schedule.feedVersion
    routes = schedule.routes.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }.map {
      RouteInfo(id: $0.id, shortName: $0.shortName, longName: $0.longName, colorHex: $0.colorHex, textColorHex: $0.textColorHex, sortOrder: $0.sortOrder)
    }
    var routeOfShape: [String: (route: String, direction: Int)] = [:]
    for trip in schedule.trips.values where routeOfShape[trip.shapeID] == nil {
      routeOfShape[trip.shapeID] = (trip.routeID, trip.directionID)
    }
    lines = schedule.shapes.compactMap { shapeID, points in
      guard let owner = routeOfShape[shapeID], points.count > 1 else { return nil }
      return Line(route: owner.route, direction: owner.direction, latitudes: points.map(\.latitude), longitudes: points.map(\.longitude))
    }
    .sorted { ($0.route, $0.direction, $0.latitudes.count) < ($1.route, $1.direction, $1.latitudes.count) }
    stops = schedule.stops.values.sorted { $0.id < $1.id }.map {
      StopInfo(id: $0.id, name: $0.name, code: $0.code, latitude: $0.latitude, longitude: $0.longitude)
    }
    self.network = network
  }
}

/// `MapOverlayData` with the lookups the map needs. A class, so that the dictionaries are built once and the value can
/// be passed around cheaply.
final class MapOverlay: Equatable, @unchecked Sendable {
  let data: MapOverlayData
  let routes: [String: Route]
  let orderedRoutes: [Route]
  let stops: [String: MapOverlayData.StopInfo]

  init(_ data: MapOverlayData) {
    self.data = data
    let models = data.routes.map {
      Route(id: $0.id, shortName: $0.shortName, longName: $0.longName, colorHex: $0.colorHex, textColorHex: $0.textColorHex, sortOrder: $0.sortOrder)
    }
    orderedRoutes = models
    routes = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
    stops = Dictionary(data.stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  var feedVersion: String { data.feedVersion }
  var network: RouteNetwork { data.network }

  static func == (a: MapOverlay, b: MapOverlay) -> Bool { a.feedVersion == b.feedVersion && a.data.version == b.data.version }

  /// All the coordinates of a route's lines (in one direction, or both), thinned so that a camera fit stays cheap.
  func coordinates(route: String, direction: Int?) -> [Coordinate] {
    var result: [Coordinate] = []
    for line in data.lines where line.route == route && (direction == nil || line.direction == direction) {
      for index in stride(from: 0, to: line.latitudes.count, by: 8) {
        result.append(Coordinate(latitude: line.latitudes[index], longitude: line.longitudes[index]))
      }
    }
    return result
  }
}

/// Where the saved copy lives.
enum OverlayStore {
  private static var url: URL? {
    try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("map-overlay.plist")
  }

  static func load() -> MapOverlay? {
    guard let url, let bytes = try? Data(contentsOf: url),
      let data = try? PropertyListDecoder().decode(MapOverlayData.self, from: bytes),
      data.version == MapOverlayData.currentVersion
    else { return nil }
    return MapOverlay(data)
  }

  static func save(_ data: MapOverlayData) {
    guard let url else { return }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    if let bytes = try? encoder.encode(data) { try? bytes.write(to: url, options: .atomic) }
  }
}
