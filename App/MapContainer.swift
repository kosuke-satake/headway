import HeadwayCore
import MapLibre
import SwiftUI

/// The MapLibre map with every route, every stop and the live buses.
struct MapContainer: UIViewRepresentable {
  @Environment(AppModel.self) private var model

  func makeCoordinator() -> MapCoordinator { MapCoordinator() }

  func makeUIView(context: Context) -> MLNMapView {
    let mapView = MLNMapView(frame: .zero, styleURL: BaseStyle.url)
    mapView.delegate = context.coordinator
    mapView.setCenter(CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012), zoomLevel: 12, animated: false)
    mapView.automaticallyAdjustsContentInset = false
    mapView.logoView.isHidden = false
    return mapView
  }

  func updateUIView(_ mapView: MLNMapView, context: Context) {
    context.coordinator.update(schedule: model.schedule, vehicles: model.vehicles)
  }
}

final class MapCoordinator: NSObject, MLNMapViewDelegate {
  private var style: MLNStyle?
  private var routesDrawn = false
  private var pendingSchedule: Schedule?
  private var pendingVehicles: [VehicleSample] = []
  private var busSource: MLNShapeSource?

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    self.style = style
    routesDrawn = false
    busSource = nil
    redraw()
  }

  func update(schedule: Schedule?, vehicles: [VehicleSample]) {
    pendingSchedule = schedule
    pendingVehicles = vehicles
    redraw()
  }

  private func redraw() {
    guard let style else { return }
    if let schedule = pendingSchedule, !routesDrawn {
      RouteLayers.add(schedule: schedule, to: style)
      routesDrawn = true
      busSource = nil
    }
    if routesDrawn {
      if busSource == nil, let schedule = pendingSchedule { busSource = RouteLayers.addBuses(schedule: schedule, to: style) }
      busSource?.shape = RouteLayers.busFeatures(pendingVehicles)
    }
  }
}

/// Builds the route, stop and bus layers. Each route has its own layers so that it can later be highlighted or hidden.
enum RouteLayers {
  static func add(schedule: Schedule, to style: MLNStyle) {
    // Route lines: one polyline per distinct shape, tagged with its route.
    var routeOfShape: [String: String] = [:]
    for trip in schedule.trips.values where routeOfShape[trip.shapeID] == nil { routeOfShape[trip.shapeID] = trip.routeID }
    var lines: [MLNPolylineFeature] = []
    for (shapeID, points) in schedule.shapes {
      guard let route = routeOfShape[shapeID], points.count > 1 else { continue }
      var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
      let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
      line.attributes = ["route": route]
      lines.append(line)
    }
    let routeSource = MLNShapeSource(identifier: "routes", features: lines, options: nil)
    style.addSource(routeSource)

    // Stops.
    let stopFeatures = schedule.stops.values.map { stop -> MLNPointFeature in
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
      point.attributes = ["name": stop.name]
      return point
    }
    let stopSource = MLNShapeSource(identifier: "stops", features: stopFeatures, options: nil)
    style.addSource(stopSource)

    for route in schedule.routes.values.sorted(by: { $0.sortOrder < $1.sortOrder }) {
      let casing = MLNLineStyleLayer(identifier: "route-casing-\(route.id)", source: routeSource)
      casing.predicate = NSPredicate(format: "route == %@", route.id)
      casing.lineColor = NSExpression(forConstantValue: UIColor.white)
      casing.lineWidth = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", [10: 3.5, 16: 9])
      casing.lineCap = NSExpression(forConstantValue: "round")
      casing.lineJoin = NSExpression(forConstantValue: "round")
      style.addLayer(casing)
    }
    for route in schedule.routes.values.sorted(by: { $0.sortOrder < $1.sortOrder }) {
      let line = MLNLineStyleLayer(identifier: "route-\(route.id)", source: routeSource)
      line.predicate = NSPredicate(format: "route == %@", route.id)
      line.lineColor = NSExpression(forConstantValue: UIColor(hex: route.colorHex))
      line.lineWidth = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", [10: 2, 16: 6])
      line.lineCap = NSExpression(forConstantValue: "round")
      line.lineJoin = NSExpression(forConstantValue: "round")
      style.addLayer(line)
    }

    let stopLayer = MLNCircleStyleLayer(identifier: "stops", source: stopSource)
    stopLayer.circleColor = NSExpression(forConstantValue: UIColor.white)
    stopLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor(white: 0.25, alpha: 1))
    stopLayer.circleStrokeWidth = NSExpression(forConstantValue: 1.25)
    stopLayer.circleRadius = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", [11: 1.5, 14: 3, 17: 6])
    stopLayer.circleOpacity = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", [11: 0, 12.5: 1])
    style.addLayer(stopLayer)
  }

  static func addBuses(schedule: Schedule, to style: MLNStyle) -> MLNShapeSource {
    let source = MLNShapeSource(identifier: "buses", features: [], options: nil)
    style.addSource(source)
    for route in schedule.routes.values {
      let ring = MLNCircleStyleLayer(identifier: "bus-ring-\(route.id)", source: source)
      ring.predicate = NSPredicate(format: "route == %@", route.id)
      ring.circleColor = NSExpression(forConstantValue: UIColor.white)
      ring.circleRadius = NSExpression(forConstantValue: 9.5)
      style.addLayer(ring)
      let dot = MLNCircleStyleLayer(identifier: "bus-\(route.id)", source: source)
      dot.predicate = NSPredicate(format: "route == %@", route.id)
      dot.circleColor = NSExpression(forConstantValue: UIColor(hex: route.colorHex))
      dot.circleRadius = NSExpression(forConstantValue: 7)
      style.addLayer(dot)
    }
    return source
  }

  static func busFeatures(_ vehicles: [VehicleSample]) -> MLNShapeCollectionFeature {
    let features = vehicles.map { vehicle -> MLNPointFeature in
      let point = MLNPointFeature()
      point.coordinate = CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude)
      point.attributes = ["route": vehicle.routeID, "bearing": vehicle.bearing ?? 0]
      return point
    }
    return MLNShapeCollectionFeature(shapes: features)
  }
}

extension UIColor {
  /// `RRGGBB` without a leading `#`.
  convenience init(hex: String) {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    self.init(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1)
  }
}
