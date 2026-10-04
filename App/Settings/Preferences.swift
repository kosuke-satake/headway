import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
}

enum StopVisibility: String, Codable, CaseIterable, Identifiable {
  /// Stops appear from a middle zoom level, so the city overview stays calm.
  case zoomed
  /// Stops are drawn at every zoom level.
  case always
  /// Only the selected stop and favourites are drawn.
  case hidden
  var id: String { rawValue }
}

enum MarkerSize: String, Codable, CaseIterable, Identifiable {
  case small, medium, large
  var id: String { rawValue }

  /// Radius in points of the coloured disc of a bus marker.
  var radius: Double {
    switch self {
    case .small: 8
    case .medium: 10.5
    case .large: 13
    }
  }
}

enum RoutePalette: String, Codable, CaseIterable, Identifiable {
  /// The colours Metro Transit publishes.
  case agency
  /// A colour-blind-safe palette, spread so that neighbouring routes differ more.
  case distinct
  /// Routes in grey; only the focused route is coloured.
  case quiet
  var id: String { rawValue }
}

enum ClockFormat: String, Codable, CaseIterable, Identifiable {
  case system, twelveHour, twentyFourHour
  var id: String { rawValue }
}

enum ArrivalStyle: String, Codable, CaseIterable, Identifiable {
  /// "4 min", switching to a clock time when far off.
  case countdown
  /// Always a clock time.
  case clock
  var id: String { rawValue }
}

/// Everything the user can customise, stored as one JSON value in `UserDefaults`.
///
/// Decoding falls back to the default for any missing key, so adding a setting never loses the existing ones.
struct Preferences: Codable, Equatable {
  // Appearance
  var appearance: AppearanceMode = .system
  var routePalette: RoutePalette = .agency
  var markerSize: MarkerSize = .medium
  var showRouteNameOnBuses = true
  var routeLineWidth: Double = 1.0  // multiplier, 0.6...1.6
  var stopVisibility: StopVisibility = .zoomed
  var showStopNames = true

  // Live data
  /// 0 follows the city's feed (a new one every 30 s); 30 and 60 are battery-saving fixed intervals.
  var updateInterval: Int = 0
  var smoothBusMovement = true
  /// Move each bus along its route at its last speed between reports.
  var estimateBusPositions = true
  var pauseLiveInBackground = true

  // Time
  var clockFormat: ClockFormat = .system
  var arrivalStyle: ArrivalStyle = .countdown
  var showDelayDetails = true

  // Behaviour
  var hapticFeedback = true
  var rememberMapPosition = true

  // User data
  var hiddenRoutes: Set<String> = []
  var favoriteStops: [String] = []
  var favoriteRoutes: [String] = []
  var recentStops: [String] = []

  // Last map position
  var lastLatitude: Double?
  var lastLongitude: Double?
  var lastZoom: Double?

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
    let d = Preferences()
    appearance = value(.appearance, d.appearance)
    routePalette = value(.routePalette, d.routePalette)
    markerSize = value(.markerSize, d.markerSize)
    showRouteNameOnBuses = value(.showRouteNameOnBuses, d.showRouteNameOnBuses)
    routeLineWidth = min(1.6, max(0.6, value(.routeLineWidth, d.routeLineWidth)))
    stopVisibility = value(.stopVisibility, d.stopVisibility)
    showStopNames = value(.showStopNames, d.showStopNames)
    // Earlier versions stored 5, 10 or 15 seconds; those now mean "follow the feed".
    updateInterval = [30, 60].contains(value(.updateInterval, d.updateInterval)) ? value(.updateInterval, d.updateInterval) : 0
    smoothBusMovement = value(.smoothBusMovement, d.smoothBusMovement)
    estimateBusPositions = value(.estimateBusPositions, d.estimateBusPositions)
    pauseLiveInBackground = value(.pauseLiveInBackground, d.pauseLiveInBackground)
    clockFormat = value(.clockFormat, d.clockFormat)
    arrivalStyle = value(.arrivalStyle, d.arrivalStyle)
    showDelayDetails = value(.showDelayDetails, d.showDelayDetails)
    hapticFeedback = value(.hapticFeedback, d.hapticFeedback)
    rememberMapPosition = value(.rememberMapPosition, d.rememberMapPosition)
    hiddenRoutes = value(.hiddenRoutes, d.hiddenRoutes)
    favoriteStops = value(.favoriteStops, d.favoriteStops)
    favoriteRoutes = value(.favoriteRoutes, d.favoriteRoutes)
    recentStops = value(.recentStops, d.recentStops)
    lastLatitude = try? c.decodeIfPresent(Double.self, forKey: .lastLatitude)
    lastLongitude = try? c.decodeIfPresent(Double.self, forKey: .lastLongitude)
    lastZoom = try? c.decodeIfPresent(Double.self, forKey: .lastZoom)
  }

  private enum Key: String, CodingKey {
    case appearance, routePalette, markerSize, showRouteNameOnBuses, routeLineWidth, stopVisibility, showStopNames
    case updateInterval, smoothBusMovement, estimateBusPositions, pauseLiveInBackground
    case clockFormat, arrivalStyle, showDelayDetails
    case hapticFeedback, rememberMapPosition
    case hiddenRoutes, favoriteStops, favoriteRoutes, recentStops
    case lastLatitude, lastLongitude, lastZoom
  }
}
