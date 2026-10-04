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
  private let highlightStopSource: MLNShapeSource
  private let busSource: MLNShapeSource
  private let selectedBusSource: MLNShapeSource

  private var casings: [String: MLNLineStyleLayer] = [:]
  private var lines: [String: MLNLineStyleLayer] = [:]
  private let stopLayer: MLNCircleStyleLayer
  private let favoriteLayer: MLNCircleStyleLayer
  private let selectedStopLayer: MLNCircleStyleLayer
  private let stopNames: MLNSymbolStyleLayer
  private let highlightStopLayer: MLNCircleStyleLayer
  private let arrowLayer: MLNSymbolStyleLayer
  private let lateLayer: MLNCircleStyleLayer
  private let earlyLayer: MLNCircleStyleLayer
  private let selectedBusLayer: MLNCircleStyleLayer
  private let offRouteLayer: MLNCircleStyleLayer
  private let staleLayer: MLNCircleStyleLayer
  private let journeySource: MLNShapeSource
  private let journeyPointSource: MLNShapeSource
  private var journeyCasing: MLNLineStyleLayer?
  private var journeyWalk: MLNLineStyleLayer?
  private var journeyRides: [MLNLineStyleLayer] = []
  private var journeyPointLayers: [String: MLNCircleStyleLayer] = [:]
  private var journeyArrows: MLNSymbolStyleLayer?
  static let journeyLegSlots = 10
  private var busRings: [String: MLNCircleStyleLayer] = [:]
  private var busDots: [String: MLNCircleStyleLayer] = [:]
  private var busLabels: [String: MLNSymbolStyleLayer] = [:]

  init(style: MLNStyle, overlay: MapOverlay) {
    self.style = style
    routeIDs = overlay.orderedRoutes.map(\.id)

    // Route polylines: one per distinct shape, tagged with its route and direction.
    var polylines: [MLNPolylineFeature] = []
    for line in overlay.data.lines where line.latitudes.count > 1 {
      var coordinates = zip(line.latitudes, line.longitudes).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
      let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
      feature.attributes = ["route": line.route, "dir": line.direction, "lane": line.lane]
      polylines.append(feature)
    }
    routeSource = MLNShapeSource(identifier: "routes", features: polylines, options: nil)
    stopSource = MLNShapeSource(identifier: "stops", features: [], options: nil)
    favoriteSource = MLNShapeSource(identifier: "favorite-stops", features: [], options: nil)
    selectedStopSource = MLNShapeSource(identifier: "selected-stop", features: [], options: nil)
    highlightStopSource = MLNShapeSource(identifier: "highlight-stops", features: [], options: nil)
    busSource = MLNShapeSource(identifier: "buses", features: [], options: nil)
    journeySource = MLNShapeSource(identifier: "journey", features: [], options: nil)
    journeyPointSource = MLNShapeSource(identifier: "journey-points", features: [], options: nil)
    selectedBusSource = MLNShapeSource(identifier: "selected-bus", features: [], options: nil)
    for source in [routeSource, stopSource, favoriteSource, selectedStopSource, highlightStopSource, busSource, selectedBusSource, journeySource, journeyPointSource] {
      style.addSource(source)
    }
    style.setImage(Self.arrowImage(), forName: "route-arrow")

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

    // Arrows along the focused route show which way its buses run.
    arrowLayer = MLNSymbolStyleLayer(identifier: "route-arrows", source: routeSource)
    Self.insertBelowLabels(arrowLayer, in: style)

    stopLayer = MLNCircleStyleLayer(identifier: Self.stopLayerID, source: stopSource)
    Self.insertBelowLabels(stopLayer, in: style)
    favoriteLayer = MLNCircleStyleLayer(identifier: "favorite-stops", source: favoriteSource)
    Self.insertBelowLabels(favoriteLayer, in: style)
    selectedStopLayer = MLNCircleStyleLayer(identifier: "selected-stop", source: selectedStopSource)
    Self.insertBelowLabels(selectedStopLayer, in: style)
    highlightStopLayer = MLNCircleStyleLayer(identifier: "highlight-stops", source: highlightStopSource)
    Self.insertBelowLabels(highlightStopLayer, in: style)

    // The journey sits above routes and stops but below stop names and buses.
    let casing = MLNLineStyleLayer(identifier: "journey-casing", source: journeySource)
    casing.lineCap = NSExpression(forConstantValue: "round")
    casing.lineJoin = NSExpression(forConstantValue: "round")
    Self.insertBelowLabels(casing, in: style)
    journeyCasing = casing
    let walk = MLNLineStyleLayer(identifier: "journey-walk", source: journeySource)
    walk.predicate = NSPredicate(format: "walk == %@", NSNumber(value: true))
    Self.insertBelowLabels(walk, in: style)
    journeyWalk = walk
    for slot in 0..<Self.journeyLegSlots {
      let ride = MLNLineStyleLayer(identifier: "journey-ride-\(slot)", source: journeySource)
      ride.predicate = NSPredicate(format: "walk == %@ AND leg == %d", NSNumber(value: false), slot)
      ride.lineCap = NSExpression(forConstantValue: "round")
      ride.lineJoin = NSExpression(forConstantValue: "round")
      Self.insertBelowLabels(ride, in: style)
      journeyRides.append(ride)
    }
    let arrows = MLNSymbolStyleLayer(identifier: "journey-arrows", source: journeySource)
    arrows.predicate = NSPredicate(format: "walk == %@", NSNumber(value: false))
    Self.insertBelowLabels(arrows, in: style)
    journeyArrows = arrows
    for kind in ["start", "transfer", "end"] {
      let layer = MLNCircleStyleLayer(identifier: "journey-point-\(kind)", source: journeyPointSource)
      layer.predicate = NSPredicate(format: "kind == %@", kind)
      Self.insertBelowLabels(layer, in: style)
      journeyPointLayers[kind] = layer
    }

    stopNames = MLNSymbolStyleLayer(identifier: "stop-names", source: stopSource)
    style.addLayer(stopNames)

    selectedBusLayer = MLNCircleStyleLayer(identifier: "selected-bus", source: selectedBusSource)
    style.addLayer(selectedBusLayer)
    lateLayer = MLNCircleStyleLayer(identifier: "bus-late", source: busSource)
    lateLayer.predicate = NSPredicate(format: "hl == %@", "late")
    style.addLayer(lateLayer)
    earlyLayer = MLNCircleStyleLayer(identifier: "bus-early", source: busSource)
    earlyLayer.predicate = NSPredicate(format: "hl == %@", "early")
    style.addLayer(earlyLayer)
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
    // A veil over buses whose last report is old: they may not be where they are drawn.
    staleLayer = MLNCircleStyleLayer(identifier: "bus-stale", source: busSource)
    staleLayer.predicate = NSPredicate(format: "stale == %@", NSNumber(value: true))
    style.addLayer(staleLayer)
  }

  /// A small white arrowhead with a dark edge, drawn pointing east; the map turns it along the line.
  private static func arrowImage() -> UIImage {
    let size = CGSize(width: 18, height: 18)
    return UIGraphicsImageRenderer(size: size).image { _ in
      let path = UIBezierPath()
      path.move(to: CGPoint(x: 3, y: 3))
      path.addLine(to: CGPoint(x: 15, y: 9))
      path.addLine(to: CGPoint(x: 3, y: 15))
      path.addLine(to: CGPoint(x: 6.5, y: 9))
      path.close()
      path.lineJoinStyle = .round
      UIColor(white: 0.1, alpha: 0.9).setStroke()
      path.lineWidth = 2
      path.stroke()
      UIColor.white.setFill()
      path.fill()
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

  /// A sideways offset of `lane` steps, where a step grows from `low` points at zoom 10 to `high` at zoom 16. The
  /// multiplication sits inside the zoom curve's stops, which is the only place a style may combine the two.
  private static func laneOffset(low: Double, high: Double) -> NSExpression {
    func step(_ size: Double) -> NSExpression {
      NSExpression(forFunction: "multiply:by:", arguments: [NSExpression(forKeyPath: "lane"), NSExpression(forConstantValue: size)])
    }
    let stops: [NSNumber: NSExpression] = [10: step(low), 16: step(high)]
    return NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", stops as NSDictionary)
  }

  // MARK: Restyling

  /// Colours, widths and visibility of everything except the data (stops and buses), which have their own setters.
  func applyStyle(_ state: MapState) {
    guard let overlay = state.overlay else { return }
    let theme = MapTheme.make(dark: state.isDark)
    let prefs = state.prefs
    let focus = state.focus
    let width = prefs.routeLineWidth
    let bundled = !focus.isActive && state.journeyID == nil

    for id in routeIDs {
      guard let route = overlay.routes[id], let line = lines[id], let casing = casings[id] else { continue }
      let look = RouteLook.make(route: route, state: state)
      let focused = focus.routes.contains(id)
      // The route in focus is drawn thicker, and only in the chosen direction.
      let boost = focused ? 1.5 : 1.0
      let predicate = focused && focus.direction != nil
        ? NSPredicate(format: "route == %@ AND dir == %d", id, focus.direction!)
        : NSPredicate(format: "route == %@", id)
      line.predicate = predicate
      casing.predicate = predicate
      line.isVisible = look.visible
      casing.isVisible = look.visible
      line.lineColor = NSExpression(forConstantValue: look.fill)
      line.lineOpacity = NSExpression(forConstantValue: look.opacity)
      line.lineWidth = Self.ramp([10: 2 * width * boost, 16: 6 * width * boost])
      // Routes that share a street lie side by side while looking at the whole network; a route on its own, or a
      // journey, is drawn on the street itself.
      let offset: NSExpression = bundled ? Self.laneOffset(low: 2 * width + 1, high: 6 * width + 2.5) : NSExpression(forConstantValue: 0)
      line.lineOffset = offset
      casing.lineOffset = offset
      // A route with an alert in force is dashed: its service differs from the usual.
      let alerted = state.alertRoutes.contains(id)
      line.lineCap = NSExpression(forConstantValue: alerted ? "butt" : "round")
      line.lineDashPattern = alerted ? NSExpression(forConstantValue: [1.8, 1.4]) : nil
      casing.lineColor = NSExpression(forConstantValue: theme.routeCasing)
      casing.lineOpacity = NSExpression(forConstantValue: look.opacity)
      casing.lineWidth = Self.ramp([10: 2 * width * boost + 1.5, 16: 6 * width * boost + 3])

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

    // Arrows along the focused route (only in the chosen direction)
    arrowLayer.isVisible = focus.isActive
    if focus.isActive {
      let routes = Array(focus.routes)
      arrowLayer.predicate = focus.direction != nil
        ? NSPredicate(format: "route IN %@ AND dir == %d", routes, focus.direction!)
        : NSPredicate(format: "route IN %@", routes)
    }
    arrowLayer.iconImageName = NSExpression(forConstantValue: "route-arrow")
    arrowLayer.symbolPlacement = NSExpression(forConstantValue: "line")
    arrowLayer.symbolSpacing = NSExpression(forConstantValue: 70)
    arrowLayer.iconRotationAlignment = NSExpression(forConstantValue: "map")
    arrowLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
    arrowLayer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    arrowLayer.iconScale = Self.ramp([10: 0.55, 16: 0.9])

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

    highlightStopLayer.circleColor = NSExpression(forConstantValue: UIColor.systemOrange.withAlphaComponent(0.25))
    highlightStopLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemOrange)
    highlightStopLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
    highlightStopLayer.circleRadius = Self.ramp([10: 7, 14: 11, 17: 16])

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

    staleLayer.circleColor = NSExpression(forConstantValue: theme.stopFill.withAlphaComponent(0.6))
    staleLayer.circleRadius = NSExpression(forConstantValue: prefs.markerSize.radius + 2.5)
    offRouteLayer.circleColor = NSExpression(forConstantValue: UIColor.clear)
    offRouteLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemOrange)
    offRouteLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
    offRouteLayer.circleRadius = NSExpression(forConstantValue: prefs.markerSize.radius + 5)

    for (layer, color) in [(lateLayer, UIColor.systemRed), (earlyLayer, UIColor.systemBlue)] {
      layer.circleColor = NSExpression(forConstantValue: UIColor.clear)
      layer.circleStrokeColor = NSExpression(forConstantValue: color)
      layer.circleStrokeWidth = NSExpression(forConstantValue: 4)
      layer.circleRadius = NSExpression(forConstantValue: prefs.markerSize.radius + 6)
    }

    selectedBusLayer.circleColor = NSExpression(forConstantValue: UIColor.clear)
    selectedBusLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemBlue)
    selectedBusLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
    selectedBusLayer.circleRadius = NSExpression(forConstantValue: prefs.markerSize.radius + 6)
  }

  // MARK: Journey

  func applyJourneyStyle(_ state: MapState) {
    let theme = MapTheme.make(dark: state.isDark)
    journeyCasing?.lineColor = NSExpression(forConstantValue: theme.routeCasing)
    journeyCasing?.lineWidth = Self.ramp([10: 8, 16: 16])
    journeyWalk?.lineColor = NSExpression(forConstantValue: state.isDark ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.3, alpha: 1))
    journeyWalk?.lineWidth = Self.ramp([10: 3, 16: 5])
    journeyWalk?.lineDashPattern = NSExpression(forConstantValue: [1.2, 1.4])
    journeyWalk?.lineCap = NSExpression(forConstantValue: "butt")
    if let arrows = journeyArrows {
      arrows.iconImageName = NSExpression(forConstantValue: "route-arrow")
      arrows.symbolPlacement = NSExpression(forConstantValue: "line")
      arrows.symbolSpacing = NSExpression(forConstantValue: 60)
      arrows.iconRotationAlignment = NSExpression(forConstantValue: "map")
      arrows.iconAllowsOverlap = NSExpression(forConstantValue: true)
      arrows.iconIgnoresPlacement = NSExpression(forConstantValue: true)
      arrows.iconScale = Self.ramp([10: 0.6, 16: 1.0])
    }
    let colors: [String: UIColor] = ["start": .systemGreen, "transfer": state.isDark ? .white : UIColor(white: 0.2, alpha: 1), "end": .systemRed]
    for (kind, layer) in journeyPointLayers {
      layer.circleColor = NSExpression(forConstantValue: theme.stopFill)
      layer.circleStrokeColor = NSExpression(forConstantValue: colors[kind] ?? .gray)
      layer.circleStrokeWidth = NSExpression(forConstantValue: 4)
      layer.circleRadius = Self.ramp([10: 5, 16: 9])
    }
  }

  func setJourney(_ state: MapState) {
    var features: [MLNPolylineFeature] = []
    for (index, line) in state.journeyLines.enumerated() where line.coordinates.count > 1 {
      var coordinates = line.coordinates
      let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
      feature.attributes = ["leg": min(index, Self.journeyLegSlots - 1), "walk": line.isWalk]
      features.append(feature)
      if !line.isWalk, index < Self.journeyLegSlots {
        journeyRides[index].lineColor = NSExpression(forConstantValue: line.color ?? UIColor.systemBlue)
        journeyRides[index].lineWidth = Self.ramp([10: 4.5, 16: 10])
      }
    }
    journeySource.shape = MLNShapeCollectionFeature(shapes: features)
    let points = state.journeyPoints.map { entry -> MLNPointFeature in
      let point = MLNPointFeature()
      point.coordinate = entry.coordinate
      point.attributes = ["kind": entry.kind]
      return point
    }
    journeyPointSource.shape = MLNShapeCollectionFeature(shapes: points)
  }

  // MARK: Data

  /// Stops to draw: those served by at least one visible route, or only the focused route's stops (in its direction)
  /// when one is focused.
  func setStops(_ state: MapState) {
    guard let overlay = state.overlay else { return }
    let hidden = state.prefs.hiddenRoutes
    let focus = state.focus
    let network = overlay.network
    var focusedStops: Set<String>?
    if state.journeyID != nil, state.prefs.focusStyle == .hide {
      focusedStops = []  // the journey's own points are drawn with it
    } else if focus.isActive {
      focusedStops = focus.routes.reduce(into: Set<String>()) { $0.formUnion(network.stops(route: $1, direction: focus.direction)) }
      focusedStops?.formUnion(focus.highlightedStops)
    }
    var features: [MLNPointFeature] = []
    features.reserveCapacity(overlay.data.stops.count)
    for stop in overlay.data.stops {
      if let focusedStops {
        if !focusedStops.contains(stop.id) { continue }
      } else {
        let routes = network.routesByStop[stop.id] ?? []
        if !routes.isEmpty, routes.allSatisfy({ hidden.contains($0) }) { continue }
      }
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      point.attributes = ["id": stop.id, "name": stop.name]
      features.append(point)
    }
    stopSource.shape = MLNShapeCollectionFeature(shapes: features)

    let favorites = state.prefs.favoriteStops.filter { focusedStops?.contains($0) ?? true }.compactMap { overlay.stops[$0] }.map { stop -> MLNPointFeature in
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      return point
    }
    favoriteSource.shape = MLNShapeCollectionFeature(shapes: favorites)

    let highlighted = focus.highlightedStops.compactMap { overlay.stops[$0] }.map { stop -> MLNPointFeature in
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      return point
    }
    highlightStopSource.shape = MLNShapeCollectionFeature(shapes: highlighted)
  }

  func setSelectedStop(_ state: MapState) {
    if let id = state.selectedStop, let stop = state.overlay?.stops[id] {
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      selectedStopSource.shape = point
    } else {
      selectedStopSource.shape = MLNShapeCollectionFeature(shapes: [])
    }
  }

  /// Reports older than this are shown veiled.
  static let staleAfter: TimeInterval = 75

  /// Draws buses at the given (possibly in-between) coordinates. While a route is in focus, only its buses (in the
  /// chosen direction) are drawn; while buses are highlighted, only those.
  func setBuses(_ buses: [DrawnBus], state: MapState) {
    let hidden = state.prefs.hiddenRoutes
    let focus = state.focus
    var features: [MLNPointFeature] = []
    var selected: MLNPointFeature?
    for bus in buses {
      let vehicle = bus.vehicle
      let route = vehicle.routeID
      if state.journeyID != nil, state.prefs.focusStyle == .hide {
        if !state.journeyTrips.contains(vehicle.tripID) { continue }
      } else if focus.isActive {
        if !focus.routes.contains(route) && state.prefs.focusStyle == .hide { continue }
        if focus.routes.contains(route), let direction = focus.direction, let own = state.vehicleDirections[vehicle.id], own != direction { continue }
        if !focus.highlightedBuses.isEmpty, focus.highlightedBuses[vehicle.id] == nil, state.prefs.focusStyle == .hide { continue }
      } else if hidden.contains(route) {
        continue
      }
      let point = MLNPointFeature()
      point.coordinate = bus.coordinate
      point.attributes = [
        "id": vehicle.id,
        "route": route,
        "label": state.overlay?.routes[route]?.shortName ?? route,
        "off": state.offRouteVehicles.contains(vehicle.id),
        "stale": bus.age > Self.staleAfter,
        "hl": focus.highlightedBuses[vehicle.id]?.rawValue ?? "",
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
