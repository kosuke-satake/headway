import CoreLocation
import HeadwayCore
import MapLibre
import SwiftUI

/// What a tap on the map hit.
enum MapTap {
  case stop(String)
  case bus(String)
  case route(String)
  case empty
}

/// The MapLibre map: basemap, routes, stops and live buses.
struct MapContainer: UIViewRepresentable {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme

  /// Height of the sheet covering the lower part of the map, used to centre selections in what is still visible.
  var bottomInset: CGFloat

  func makeCoordinator() -> MapCoordinator { MapCoordinator() }

  func makeUIView(context: Context) -> MLNMapView {
    let coordinator = context.coordinator
    let mapView = MLNMapView(frame: .zero, styleURL: BaseStyle.url(dark: colorScheme == .dark))
    mapView.delegate = coordinator
    mapView.allowsRotating = false
    mapView.allowsTilting = false
    mapView.automaticallyAdjustsContentInset = false
    let prefs = model.settings.values
    if prefs.rememberMapPosition, let lat = prefs.lastLatitude, let lon = prefs.lastLongitude {
      mapView.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon), zoomLevel: prefs.lastZoom ?? 12, animated: false)
    } else {
      mapView.setCenter(CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012), zoomLevel: 12, animated: false)
    }
    coordinator.attach(mapView: mapView)
    coordinator.onTap = { [model] tap in
      switch tap {
      case .stop(let id): model.selectStop(id)
      case .bus(let id): model.selectBus(id)
      case .route(let id): model.toggleFocus(route: id)
      case .empty: if model.sheet?.isDetail == true { model.clearSelection() }
      }
    }
    coordinator.onCameraIdle = { [model] latitude, longitude, zoom in
      guard model.settings.values.rememberMapPosition else { return }
      model.settings.values.lastLatitude = latitude
      model.settings.values.lastLongitude = longitude
      model.settings.values.lastZoom = zoom
    }
    return mapView
  }

  func updateUIView(_ mapView: MLNMapView, context: Context) {
    var state = MapState()
    state.schedule = model.schedule
    state.routesByStop = model.routesByStop
    state.vehicles = model.vehicles
    state.prefs = MapPreferences(model.settings.values)
    state.focusedRoute = model.focusedRouteID
    state.selectedStop = model.selectedStopID
    state.selectedVehicle = model.selectedVehicle?.id
    state.isDark = colorScheme == .dark
    state.bottomInset = bottomInset
    state.locationAuthorized = model.location.isAuthorized
    context.coordinator.apply(state, camera: model.cameraRequest)
  }

  static func dismantleUIView(_ mapView: MLNMapView, coordinator: MapCoordinator) {
    coordinator.detach()
  }
}

/// Owns the map's style layers and keeps them in sync with `MapState`.
final class MapCoordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
  var onTap: ((MapTap) -> Void)?
  var onCameraIdle: ((Double, Double, Double) -> Void)?

  private weak var mapView: MLNMapView?
  private var layers: MapLayers?
  private var state = MapState()
  private var appliedStyleSchedule: String?
  private var lastCameraID: UUID?
  private let animator = BusAnimator()
  private var displayLink: CADisplayLink?
  private var idleWork: DispatchWorkItem?

  func attach(mapView: MLNMapView) {
    self.mapView = mapView
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.delegate = self
    mapView.addGestureRecognizer(tap)
  }

  func detach() {
    displayLink?.invalidate()
    displayLink = nil
  }

  // MARK: Applying state

  func apply(_ new: MapState, camera: CameraRequest?) {
    let old = state
    state = new
    guard let mapView else { return }

    if new.isDark != old.isDark {
      // A different basemap: the style reloads, and `didFinishLoading` rebuilds every layer.
      layers = nil
      mapView.styleURL = BaseStyle.url(dark: new.isDark)
    }
    if new.locationAuthorized != old.locationAuthorized { mapView.showsUserLocation = new.locationAuthorized }

    if layers == nil, new.schedule != nil, new.isDark == old.isDark, let style = mapView.style {
      buildLayers(style: style)
    }
    if let layers {
      let styleChanged = old.prefs != new.prefs || old.focusedRoute != new.focusedRoute || old.isDark != new.isDark
        || old.schedule?.feedVersion != new.schedule?.feedVersion
      if styleChanged { layers.applyStyle(new) }
      if styleChanged || old.routesByStop.count != new.routesByStop.count { layers.setStops(new) }
      if old.selectedStop != new.selectedStop { layers.setSelectedStop(new) }
      if old.vehicles != new.vehicles || old.prefs.hiddenRoutes != new.prefs.hiddenRoutes
        || old.selectedVehicle != new.selectedVehicle
      {
        if old.vehicles != new.vehicles {
          animator.update(
            vehicles: new.vehicles, smooth: new.prefs.smoothBusMovement, duration: Double(new.prefs.updateInterval),
            now: CACurrentMediaTime())
        }
        flushBuses()
        startAnimationIfNeeded()
      }
    }

    if let camera, camera.id != lastCameraID {
      lastCameraID = camera.id
      fly(camera)
    }
  }

  private func buildLayers(style: MLNStyle) {
    guard let schedule = state.schedule else { return }
    let built = MapLayers(style: style, schedule: schedule)
    layers = built
    appliedStyleSchedule = schedule.feedVersion
    built.applyStyle(state)
    built.setStops(state)
    built.setSelectedStop(state)
    animator.update(
      vehicles: state.vehicles, smooth: false, duration: 1, now: CACurrentMediaTime())
    flushBuses()
  }

  private func flushBuses() {
    guard let layers else { return }
    layers.setBuses(animator.positions(at: CACurrentMediaTime()).list, state: state)
  }

  // MARK: Smooth movement

  private func startAnimationIfNeeded() {
    guard state.prefs.smoothBusMovement else { return }
    if displayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(tick))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    displayLink?.isPaused = false
  }

  @objc private func tick() {
    guard let layers else { return }
    let result = animator.positions(at: CACurrentMediaTime())
    layers.setBuses(result.list, state: state)
    if result.finished { displayLink?.isPaused = true }
  }

  // MARK: Camera

  private func fly(_ request: CameraRequest) {
    guard let mapView else { return }
    let zoom = max(mapView.zoomLevel, request.minimumZoom)
    // Shift the map's centre south so that the target appears in the middle of the part the sheet leaves free.
    let metersPerPoint = mapView.metersPerPoint(atLatitude: request.latitude) * pow(2, mapView.zoomLevel - zoom)
    let shift = Double(state.bottomInset / 2) * metersPerPoint / 111_320
    mapView.setCenter(
      CLLocationCoordinate2D(latitude: request.latitude - shift, longitude: request.longitude), zoomLevel: zoom, animated: true)
  }

  // MARK: MLNMapViewDelegate

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    layers = nil
    if state.schedule != nil { buildLayers(style: style) }
  }

  func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
    // Save the camera once it has rested, not on every frame of a pan.
    idleWork?.cancel()
    let work = DispatchWorkItem { [weak self, weak mapView] in
      guard let mapView else { return }
      self?.onCameraIdle?(mapView.centerCoordinate.latitude, mapView.centerCoordinate.longitude, mapView.zoomLevel)
    }
    idleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }

  // MARK: Taps

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    true
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let mapView, let layers else { return }
    let point = gesture.location(in: mapView)

    // Buses first: they sit on top and are the thing riders look for.
    if let bus = nearest(to: point, in: mapView, layerIDs: layers.busDotLayerIDs, radius: 30), let id = bus.attribute(forKey: "id") as? String {
      onTap?(.bus(id))
      return
    }
    if let stop = nearest(to: point, in: mapView, layerIDs: [MapLayers.stopLayerID], radius: 26), let id = stop.attribute(forKey: "id") as? String {
      onTap?(.stop(id))
      return
    }
    let box = CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
    let lines = mapView.visibleFeatures(in: box, styleLayerIdentifiers: layers.lineLayerIDs)
    if let route = lines.first?.attribute(forKey: "route") as? String {
      onTap?(.route(route))
      return
    }
    onTap?(.empty)
  }

  /// The feature closest to `point` (in screen distance) among those within `radius` points.
  private func nearest(to point: CGPoint, in mapView: MLNMapView, layerIDs: Set<String>, radius: CGFloat) -> MLNFeature? {
    let box = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    var best: (feature: MLNFeature, distance: CGFloat)?
    for feature in mapView.visibleFeatures(in: box, styleLayerIdentifiers: layerIDs) {
      guard let pointFeature = feature as? MLNPointFeature else { continue }
      let screen = mapView.convert(pointFeature.coordinate, toPointTo: mapView)
      let distance = hypot(screen.x - point.x, screen.y - point.y)
      if distance <= radius, best == nil || distance < best!.distance { best = (feature, distance) }
    }
    return best?.feature
  }
}
