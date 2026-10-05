import CoreLocation
import Foundation
import HeadwayCore

/// What the map draws of the timetable: route lines, stops and which routes serve them.
///
/// Parsing the timetable takes a moment on every launch, so a compact copy of what the map needs is saved after
/// each parse. The next launch reads that copy and shows every route at once, while the full timetable loads in the
/// background.
struct MapOverlayData: Codable, Equatable, Sendable {
  /// Raise this whenever what the overlay holds, or how it is computed (for example the bundling of lanes), changes: a
  /// saved copy of an older version is then ignored and rebuilt from the timetable.
  static let currentVersion = 7

  struct RouteInfo: Codable, Equatable, Sendable {
    var id: String
    var shortName: String
    var longName: String
    var colorHex: String
    var textColorHex: String
    var sortOrder: Int
  }

  /// A route line as parallel arrays of coordinates. In `lines`, one shape in one direction, drawn on the street; in
  /// `overview`, a stretch of the route's merged line (`direction` -1) with the `lane` at which it is drawn so that routes
  /// sharing a street lie next to each other (0 when alone; see `RouteBundler`).
  struct Line: Codable, Equatable, Sendable {
    var route: String
    var direction: Int
    var lane: Double = 0
    var latitudes: [Double]
    var longitudes: [Double]
  }

  struct StopInfo: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var code: String
    var latitude: Double
    var longitude: Double
    /// Bearing the stop faces, which is the way its buses go (the feed's `cardinal_direction`).
    var facing: Int? = nil
  }

  var version = MapOverlayData.currentVersion
  var feedVersion: String
  var routes: [RouteInfo]
  /// Each shape of each route, per direction: drawn when a route is looked at on its own.
  var lines: [Line]
  /// One line per route with lanes: drawn for the whole network.
  var overview: [Line] = []
  var stops: [StopInfo]
  var network: RouteNetwork

  init(feedVersion: String, routes: [RouteInfo], lines: [Line], overview: [Line] = [], stops: [StopInfo], network: RouteNetwork) {
    self.feedVersion = feedVersion
    self.routes = routes
    self.lines = lines
    self.overview = overview
    self.stops = stops
    self.network = network
  }

  init(schedule: Schedule, network: RouteNetwork) {
    feedVersion = schedule.feedVersion
    routes = schedule.routes.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }.map {
      RouteInfo(id: $0.id, shortName: $0.shortName, longName: $0.longName, colorHex: $0.colorHex, textColorHex: $0.textColorHex, sortOrder: $0.sortOrder)
    }
    var tripOfShape: [String: Trip] = [:]
    for trip in schedule.trips.values where tripOfShape[trip.shapeID] == nil { tripOfShape[trip.shapeID] = trip }
    let inputs = schedule.shapes.compactMap { shapeID, points -> BundleInput? in
      guard let trip = tripOfShape[shapeID], let route = schedule.routes[trip.routeID], points.count > 1 else { return nil }
      return BundleInput(route: route.id, order: route.sortOrder, direction: trip.directionID, shapeID: shapeID, points: points)
    }
    lines = inputs.map {
      Line(route: $0.route, direction: $0.direction, latitudes: $0.points.map(\.latitude), longitudes: $0.points.map(\.longitude))
    }
    .sorted { ($0.route, $0.direction, $0.latitudes.count) < ($1.route, $1.direction, $1.latitudes.count) }
    overview = RouteBundler.overview(inputs).map {
      Line(route: $0.route, direction: -1, lane: $0.lane, latitudes: $0.coordinates.map(\.latitude), longitudes: $0.coordinates.map(\.longitude))
    }
    stops = schedule.stops.values.sorted { $0.id < $1.id }.map {
      StopInfo(id: $0.id, name: $0.name, code: $0.code, latitude: $0.latitude, longitude: $0.longitude, facing: $0.facing)
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

  /// The timetable and the way the overlay was computed: when either changes, the map rebuilds its layers.
  var identity: String { "\(data.feedVersion)#\(data.version)" }

  /// True when the overlay was computed by an older version of the app and should be computed again.
  var isOutdated: Bool { data.version != MapOverlayData.currentVersion }

  static func == (a: MapOverlay, b: MapOverlay) -> Bool { a.identity == b.identity }

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

  /// The saved copy, even one computed by an older version of the app: an old drawing is better than an empty map while
  /// the new one is computed.
  static func load() -> MapOverlay? {
    guard let url, let bytes = try? Data(contentsOf: url),
      let data = try? PropertyListDecoder().decode(MapOverlayData.self, from: bytes)
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
