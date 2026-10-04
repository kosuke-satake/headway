import Foundation

/// Why a bus is ringed on the map.
enum BusHighlight: String, Equatable {
  case late, early
}

/// What the map is asked to show on its own: one route (in one direction), the routes of an alert with the stops it
/// names, or the buses of a delay list. Everything else is hidden (or dimmed, as the rider chose).
struct MapFocus: Equatable {
  var routes: Set<String> = []
  /// Direction of the single focused route (0 or 1); `nil` shows both.
  var direction: Int?
  /// Stops to ring (for an alert about closed or moved stops).
  var highlightedStops: [String] = []
  /// Buses to ring, and why. When there are any, other buses are hidden (or dimmed).
  var highlightedBuses: [String: BusHighlight] = [:]
  /// What the chip over the map says instead of the route's name (an alert's title, "Late buses", ...).
  var label: String?
  /// True when the focus came from a bus being opened; closing the bus then clears it.
  var fromBus = false

  var isActive: Bool { !routes.isEmpty }

  static func route(_ id: String, direction: Int? = nil) -> MapFocus { MapFocus(routes: [id], direction: direction) }
}

/// What the map does with routes that are not in focus.
enum FocusStyle: String, Codable, CaseIterable, Identifiable {
  /// Draw nothing for them: only the route in focus stays on the map.
  case hide
  /// Draw them faintly.
  case dim
  var id: String { rawValue }
}
