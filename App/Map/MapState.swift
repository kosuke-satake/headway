import HeadwayCore
import UIKit

/// The preferences that affect how the map looks. Kept separate from `Preferences` so that saving the camera
/// position (which changes `Preferences`) never restyles the map.
struct MapPreferences: Equatable {
  var routePalette: RoutePalette = .agency
  var markerSize: MarkerSize = .medium
  var showRouteNameOnBuses = true
  var routeLineWidth = 1.0
  var stopVisibility: StopVisibility = .zoomed
  var showStopNames = true
  var smoothBusMovement = true
  var estimateBusPositions = true
  var hiddenRoutes: Set<String> = []
  var favoriteStops: [String] = []

  init() {}

  init(_ p: Preferences) {
    routePalette = p.routePalette
    markerSize = p.markerSize
    showRouteNameOnBuses = p.showRouteNameOnBuses
    routeLineWidth = p.routeLineWidth
    stopVisibility = p.stopVisibility
    showStopNames = p.showStopNames
    smoothBusMovement = p.smoothBusMovement
    estimateBusPositions = p.estimateBusPositions
    hiddenRoutes = p.hiddenRoutes
    favoriteStops = p.favoriteStops
  }
}

/// Everything the map needs to draw, gathered in one value so the coordinator can tell what changed.
struct MapState {
  var schedule: Schedule?
  var routesByStop: [String: [String]] = [:]
  var vehicles: [VehicleSample] = []
  var prefs = MapPreferences()
  var focusedRoute: String?
  var selectedStop: String?
  var selectedVehicle: String?
  var isDark = false
  /// Height of the bottom sheet that covers the map, so the camera can centre in the visible part.
  var bottomInset: CGFloat = 0
  var locationAuthorized = false
  /// Routes with an alert in force (drawn dashed) and buses away from their usual line (ringed in orange).
  var alertRoutes: Set<String> = []
  var offRouteVehicles: Set<String> = []
  /// The journey shown on the map: an id to notice changes, its lines, and the points where legs meet.
  var journeyID: String?
  var journeyLines: [JourneyLine] = []
  var journeyPoints: [(coordinate: CLLocationCoordinate2D, kind: String)] = []
}

/// One line of a journey, ready to draw.
struct JourneyLine {
  let coordinates: [CLLocationCoordinate2D]
  let color: UIColor?  // nil for walking
  let isWalk: Bool
}

/// Colours and visibility of one route, derived from the state.
struct RouteLook {
  let fill: UIColor
  let busFill: UIColor
  let busText: UIColor
  let opacity: Double
  let visible: Bool

  static func make(route: Route, state: MapState) -> RouteLook {
    let routes = state.schedule.map { Array($0.routes.values) } ?? []
    let prefs = state.prefs
    let isFocused = state.focusedRoute == route.id
    let anyFocus = state.focusedRoute != nil
    let agency = UIColor(hex: route.colorHex)
    // The quiet palette greys the lines; the focused route and the bus markers keep their agency colour.
    var line = prefs.routePalette == .quiet && isFocused ? agency : RouteColors.fill(for: route, palette: prefs.routePalette, among: routes)
    var bus = prefs.routePalette == .quiet ? agency : line
    if state.isDark {
      line = RouteColors.forDarkMap(line)
      bus = RouteColors.forDarkMap(bus)
    }
    return RouteLook(
      fill: line,
      busFill: bus,
      busText: RouteColors.text(on: bus),
      opacity: (anyFocus && !isFocused) || state.journeyID != nil ? 0.2 : 1,
      visible: !prefs.hiddenRoutes.contains(route.id))
  }
}
