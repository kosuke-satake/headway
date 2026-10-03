import HeadwayCore
import MapLibre
import UIKit

/// The layers Headway draws on top of the basemap, and the code that restyles them.
///
/// Routes and stops sit under the basemap's text labels (street and place names) but above its fills and roads.
/// Stop names and buses are drawn on top of everything so that they are never hidden.
final class MapLayers {
  static let stopLayerID = "stops"
  static func busDotID(_ route: String) -> String { "bus-\(route)" }
  static func lineID(_ route: String) -> String { "route-\(route)" }

  private let style: MLNStyle
  private let routeIDs: [String]

  private let routeSource: MLNShapeSource
  private let stopSource: MLNShapeSource
  private let favoriteSource: MLNShapeSource
  private let selectedStopSource: MLNShapeSource
  private let busSource: MLNShapeSource
  private let selectedBusSource: MLNShapeSource

  private var casings: [String: MLNLineStyleLayer] = [:]
  private var lines: [String: MLNLineStyleLayer] = [:]
  private let stopLayer: MLNCircleStyleLayer
  private let favoriteLayer: MLNCircleStyleLayer
  private let selectedStopLayer: MLNCircleStyleLayer
  private let stopNames: MLNSymbolStyleLayer
  private let selectedBusLayer: MLNCircleStyleLayer
  private let offRouteLayer: MLNCircleStyleLayer
  private var busRings: [String: MLNCircleStyleLayer] = [:]
  private var busDots: [String: MLNCircleStyleLayer] = [:]
  private var busLabels: [String: MLNSymbolStyleLayer] = [:]

  init(style: MLNStyle, schedule: Schedule) {
    self.style = style
    let routes = schedule.routes.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
    routeIDs = routes.map(\.id)

    // Route polylines: one per distinct shape, tagged with its route.
    var routeOfShape: [String: String] = [:]
    for trip in schedule.trips.values where routeOfShape[trip.shapeID] == nil { routeOfShape[trip.shapeID] = trip.routeID }
    var polylines: [MLNPolylineFeature] = []
    for (shapeID, points) in schedule.shapes {
      guard let route = routeOfShape[shapeID], points.count > 1 else { continue }
      var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
      let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
      line.attributes = ["route": route]
      polylines.append(line)
    }
    routeSource = MLNShapeSource(identifier: "routes", features: polylines, options: nil)
    stopSource = MLNShapeSource(identifier: "stops", features: [], options: nil)
    favoriteSource = MLNShapeSource(identifier: "favorite-stops", features: [], options: nil)
    selectedStopSource = MLNShapeSource(identifier: "selected-stop", features: [], options: nil)
    busSource = MLNShapeSource(identifier: "buses", features: [], options: nil)
    selectedBusSource = MLNShapeSource(identifier: "selected-bus", features: [], options: nil)
    for source in [routeSource, stopSource, favoriteSource, selectedStopSource, busSource, selectedBusSource] {
      style.addSource(source)
    }

    for id in routeIDs {
      let casing = MLNLineStyleLayer(identifier: "route-casing-\(id)", source: routeSource)
      casing.predicate = NSPredicate(format: "route == %@", id)
      casing.lineCap = NSExpression(forConstantValue: "round")
      casing.lineJoin = NSExpression(forConstantValue: "round")
      casings[id] = casing
      Self.insertBelowLabels(casing, in: style)
    }
    for id in routeIDs {
      let line = MLNLineStyleLayer(identifier: Self.lineID(id), source: routeSource)
      line.predicate = NSPredicate(format: "route == %@", id)
      line.lineCap = NSExpression(forConstantValue: "round")
      line.lineJoin = NSExpression(forConstantValue: "round")
      lines[id] = line
      Self.insertBelowLabels(line, in: style)
    }

    stopLayer = MLNCircleStyleLayer(identifier: Self.stopLayerID, source: stopSource)
    Self.insertBelowLabels(stopLayer, in: style)
    favoriteLayer = MLNCircleStyleLayer(identifier: "favorite-stops", source: favoriteSource)
    Self.insertBelowLabels(favoriteLayer, in: style)
    selectedStopLayer = MLNCircleStyleLayer(identifier: "selected-stop", source: selectedStopSource)
    Self.insertBelowLabels(selectedStopLayer, in: style)

    stopNames = MLNSymbolStyleLayer(identifier: "stop-names", source: stopSource)
    style.addLayer(stopNames)

    selectedBusLayer = MLNCircleStyleLayer(identifier: "selected-bus", source: selectedBusSource)
    style.addLayer(selectedBusLayer)
    offRouteLayer = MLNCircleStyleLayer(identifier: "off-route", source: busSource)
    offRouteLayer.predicate = NSPredicate(format: "off == %@", NSNumber(value: true))
    style.addLayer(offRouteLayer)
    for id in routeIDs {
      let ring = MLNCircleStyleLayer(identifier: "bus-ring-\(id)", source: busSource)
      ring.predicate = NSPredicate(format: "route == %@", id)
      busRings[id] = ring
      style.addLayer(ring)
      let dot = MLNCircleStyleLayer(identifier: Self.busDotID(id), source: busSource)
      dot.predicate = NSPredicate(format: "route == %@", id)
      busDots[id] = dot
      style.addLayer(dot)
      let label = MLNSymbolStyleLayer(identifier: "bus-label-\(id)", source: busSource)
      label.predicate = NSPredicate(format: "route == %@", id)
      busLabels[id] = label
      style.addLayer(label)
    }
  }

  private static func insertBelowLabels(_ layer: MLNStyleLayer, in style: MLNStyle) {
    if let firstLabel = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
      style.insertLayer(layer, below: firstLabel)
    } else {
      style.addLayer(layer)
    }
  }

  private static func ramp(_ stops: [Double: Double]) -> NSExpression {
    NSExpression(
      format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", stops as NSDictionary)
  }

  // MARK: Restyling

  /// Colours, widths and visibility of everything except the data (stops and buses), which have their own setters.
  func applyStyle(_ state: MapState) {
    guard let schedule = state.schedule else { return }
    let theme = MapTheme.make(dark: state.isDark)
    let prefs = state.prefs
    let width = prefs.routeLineWidth

    for id in routeIDs {
      guard let route = schedule.routes[id], let line = lines[id], let casing = casings[id] else { continue }
      let look = RouteLook.make(route: route, state: state)
      line.isVisible = look.visible
      casing.isVisible = look.visible
      line.lineColor = NSExpression(forConstantValue: look.fill)
      line.lineOpacity = NSExpression(forConstantValue: look.opacity)
      line.lineWidth = Self.ramp([10: 2 * width, 16: 6 * width])
      // A route with an alert in force is dashed: its service differs from the usual.
      let alerted = state.alertRoutes.contains(id)
      line.lineCap = NSExpression(forConstantValue: alerted ? "butt" : "round")
      line.lineDashPattern = alerted ? NSExpression(forConstantValue: [1.8, 1.4]) : nil
      casing.lineColor = NSExpression(forConstantValue: theme.routeCasing)
      casing.lineOpacity = NSExpression(forConstantValue: look.opacity)
      casing.lineWidth = Self.ramp([10: 2 * width + 1.5, 16: 6 * width + 3])

      let radius = prefs.markerSize.radius
      let ring = busRings[id]!, dot = busDots[id]!, label = busLabels[id]!
      for layer in [ring, dot] { layer.isVisible = look.visible }
      label.isVisible = look.visible && prefs.showRouteNameOnBuses
      ring.circleColor = NSExpression(forConstantValue: theme.busRing)
      ring.circleRadius = NSExpression(forConstantValue: radius + 2)
      ring.circleOpacity = NSExpression(forConstantValue: look.opacity)
      dot.circleColor = NSExpression(forConstantValue: look.busFill)
      dot.circleRadius = NSExpression(forConstantValue: radius)
      dot.circleOpacity = NSExpression(forConstantValue: look.opacity)
      label.text = NSExpression(forKeyPath: "label")
      label.textFontNames = NSExpression(forConstantValue: ["Noto Sans Medium"])
      label.textFontSize = NSExpression(forConstantValue: radius * 1.05)
      label.textColor = NSExpression(forConstantValue: look.busText)
      label.textOpacity = NSExpression(forConstantValue: look.opacity)
      label.textAllowsOverlap = NSExpression(forConstantValue: true)
      label.textIgnoresPlacement = NSExpression(forConstantValue: true)
    }

    // Stops
    stopLayer.isVisible = prefs.stopVisibility != .hidden
    stopLayer.circleColor = NSExpression(forConstantValue: theme.stopFill)
    stopLayer.circleStrokeColor = NSExpression(forConstantValue: theme.stopStroke)
    stopLayer.circleStrokeWidth = NSExpression(forConstantValue: 1.25)
    stopLayer.circleRadius = Self.ramp([11: 1.6, 14: 3.2, 17: 6])
    switch prefs.stopVisibility {
    case .always: stopLayer.circleOpacity = Self.ramp([9: 0.7, 11: 1])
    default: stopLayer.circleOpacity = Self.ramp([11.5: 0, 13: 1])
    }
    stopLayer.circleStrokeOpacity = stopLayer.circleOpacity

    favoriteLayer.circleColor = NSExpression(forConstantValue: UIColor.clear)
    favoriteLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemOrange)
    favoriteLayer.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
    favoriteLayer.circleRadius = Self.ramp([10: 4, 14: 7, 17: 10])

    selectedStopLayer.circleColor = NSExpression(forConstantValue: UIColor.systemBlue.withAlphaComponent(0.18))
    selectedStopLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemBlue)
    selectedStopLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
    selectedStopLayer.circleRadius = Self.ramp([10: 7, 14: 10, 17: 14])

    stopNames.isVisible = prefs.showStopNames && prefs.stopVisibility != .hidden
    stopNames.minimumZoomLevel = 15
    stopNames.text = NSExpression(forKeyPath: "name")
    stopNames.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
    stopNames.textFontSize = NSExpression(forConstantValue: 11)
    stopNames.textColor = NSExpression(forConstantValue: theme.labelText)
    stopNames.textHaloColor = NSExpression(forConstantValue: theme.labelHalo)
    stopNames.textHaloWidth = NSExpression(forConstantValue: 1.5)
    stopNames.textAnchor = NSExpression(forConstantValue: "top")
    stopNames.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.9)))
    stopNames.maximumTextWidth = NSExpression(forConstantValue: 8)

    offRouteLayer.circleColor = NSExpression(forConstantValue: UIColor.clear)
    offRouteLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemOrange)
    offRouteLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
    offRouteLayer.circleRadius = NSExpression(forConstantValue: prefs.markerSize.radius + 5)

    selectedBusLayer.circleColor = NSExpression(forConstantValue: UIColor.clear)
    selectedBusLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemBlue)
    selectedBusLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
    selectedBusLayer.circleRadius = NSExpression(forConstantValue: prefs.markerSize.radius + 6)
  }

  // MARK: Data

  /// Stops to draw: those served by at least one visible route, or only the focused route's stops when one is focused.
  func setStops(_ state: MapState) {
    guard let schedule = state.schedule else { return }
    let hidden = state.prefs.hiddenRoutes
    var features: [MLNPointFeature] = []
    features.reserveCapacity(schedule.stops.count)
    for stop in schedule.stops.values {
      let routes = state.routesByStop[stop.id] ?? []
      if let focus = state.focusedRoute {
        if !routes.contains(focus) { continue }
      } else if !routes.isEmpty, routes.allSatisfy({ hidden.contains($0) }) {
        continue
      }
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      point.attributes = ["id": stop.id, "name": stop.name]
      features.append(point)
    }
    stopSource.shape = MLNShapeCollectionFeature(shapes: features)

    let favorites = state.prefs.favoriteStops.compactMap { schedule.stops[$0] }.map { stop -> MLNPointFeature in
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      return point
    }
    favoriteSource.shape = MLNShapeCollectionFeature(shapes: favorites)
  }

  func setSelectedStop(_ state: MapState) {
    if let id = state.selectedStop, let stop = state.schedule?.stops[id] {
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      selectedStopSource.shape = point
    } else {
      selectedStopSource.shape = MLNShapeCollectionFeature(shapes: [])
    }
  }

  /// Draws buses at the given (possibly in-between) coordinates.
  func setBuses(_ buses: [(vehicle: VehicleSample, coordinate: CLLocationCoordinate2D)], state: MapState) {
    let hidden = state.prefs.hiddenRoutes
    var features: [MLNPointFeature] = []
    var selected: MLNPointFeature?
    for (vehicle, coordinate) in buses where !hidden.contains(vehicle.routeID) {
      let point = MLNPointFeature()
      point.coordinate = coordinate
      point.attributes = [
        "id": vehicle.id,
        "route": vehicle.routeID,
        "label": state.schedule?.routes[vehicle.routeID]?.shortName ?? vehicle.routeID,
        "off": state.offRouteVehicles.contains(vehicle.id),
      ]
      features.append(point)
      if vehicle.id == state.selectedVehicle { selected = point }
    }
    busSource.shape = MLNShapeCollectionFeature(shapes: features)
    selectedBusSource.shape = selected ?? MLNShapeCollectionFeature(shapes: [])
  }

  var busDotLayerIDs: Set<String> { Set(routeIDs.map(Self.busDotID)) }
  var lineLayerIDs: Set<String> { Set(routeIDs.map(Self.lineID)) }
}
