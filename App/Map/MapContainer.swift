import CoreLocation
import HeadwayCore
import MapLibre
import SwiftUI

/// What a tap on the map hit.
enum MapTap {
  case stop(String)
  case bus(String)
  /// Every route whose line passes under the finger (several when lines overlap).
  case routes([String])
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
      case .routes(let ids): model.tapRoutes(ids)
      case .empty:
        // A journey's summary stays open while looking around the map; a stop or bus sheet closes. Tapping the empty
        // map also lets go of a route that was looked at on its own.
        model.routeChoices = []
        if model.focus.isActive, model.mapJourney == nil { model.clearFocus() }
        switch model.sheet {
        case .stop?, .bus?: model.clearSelection()
        default: break
        }
      }
    }
    coordinator.onLongPress = { [model] latitude, longitude in
      model.droppedPin = PlanPoint(name: String(localized: "Dropped pin"), coordinate: Coordinate(latitude: latitude, longitude: longitude))
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
    state.overlay = model.overlay
    state.schedule = model.schedule
    state.vehicles = model.vehicles
    state.vehicleDirections = model.vehicleDirections
    state.prefs = MapPreferences(model.settings.values)
    state.focus = model.focus
    state.selectedStop = model.selectedStopID
    state.selectedVehicle = model.selectedVehicle?.id
    state.isDark = colorScheme == .dark
    state.bottomInset = bottomInset
    state.locationAuthorized = model.location.isAuthorized
    state.alertRoutes = model.alertRouteIDs
    state.offRouteVehicles = model.offRouteVehicleIDs
    if let journey = model.mapJourney {
      state.journeyID = journey.id
      state.journeyTrips = Set(journey.rides.map(\.tripID))
      let routes = model.orderedRoutes
      let palette = model.settings.values.routePalette
      state.journeyLines = model.journeyLines.map { line in
        let color = line.routeID.flatMap { id in routes.first { $0.id == id } }.map {
          let fill = RouteColors.fill(for: $0, palette: palette == .quiet ? .agency : palette, among: routes)
          return colorScheme == .dark ? RouteColors.forDarkMap(fill) : fill
        }
        return JourneyLine(
          coordinates: line.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
          color: color, isWalk: line.routeID == nil)
      }
      var points: [(CLLocationCoordinate2D, String)] = []
      for (index, line) in model.journeyLines.enumerated() {
        guard let first = line.coordinates.first, let last = line.coordinates.last else { continue }
        let begin = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
        let end = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
        if index == 0 { points.append((begin, "start")) } else { points.append((begin, "transfer")) }
        if index == model.journeyLines.count - 1 { points.append((end, "end")) }
      }
      state.journeyPoints = points
    }
    context.coordinator.apply(state, camera: model.cameraRequest, fit: model.fitRequest)
  }

  static func dismantleUIView(_ mapView: MLNMapView, coordinator: MapCoordinator) {
    coordinator.detach()
  }
}

/// Owns the map's style layers and keeps them in sync with `MapState`.
final class MapCoordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
  var onTap: ((MapTap) -> Void)?
  var onLongPress: ((Double, Double) -> Void)?
  var onCameraIdle: ((Double, Double, Double) -> Void)?

  private weak var mapView: MLNMapView?
  private var layers: MapLayers?
  private var state = MapState()
  private var appliedOverlay: String?
  private var lastCameraID: UUID?
  private var lastFitID: UUID?
  private let animator = BusAnimator()
  private var displayLink: CADisplayLink?
  private var idleWork: DispatchWorkItem?

  func attach(mapView: MLNMapView) {
    self.mapView = mapView
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.delegate = self
    mapView.addGestureRecognizer(tap)
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    hold.minimumPressDuration = 0.6
    hold.delegate = self
    mapView.addGestureRecognizer(hold)
  }

  func detach() {
    displayLink?.invalidate()
    displayLink = nil
  }

  // MARK: Applying state

  func apply(_ new: MapState, camera: CameraRequest?, fit: FitRequest?) {
    let old = state
    state = new
    guard let mapView else { return }

    if new.isDark != old.isDark {
      // A different basemap: the style reloads, and `didFinishLoading` rebuilds every layer.
      layers = nil
      mapView.styleURL = BaseStyle.url(dark: new.isDark)
    }
    if new.locationAuthorized != old.locationAuthorized { mapView.showsUserLocation = new.locationAuthorized }

    if let overlay = new.overlay, appliedOverlay != nil, appliedOverlay != overlay.feedVersion, new.isDark == old.isDark {
      // A new timetable replaced the one the layers were built from: build them again.
      layers = nil
      appliedOverlay = nil
      mapView.reloadStyle(nil)
    }
    if layers == nil, new.overlay != nil, new.isDark == old.isDark, let style = mapView.style {
      buildLayers(style: style)
    }
    if let layers {
      let styleChanged = old.prefs != new.prefs || old.focus != new.focus || old.isDark != new.isDark
        || old.alertRoutes != new.alertRoutes
      if styleChanged || old.journeyID != new.journeyID { layers.applyStyle(new) }
      if styleChanged { layers.applyJourneyStyle(new) }
      if old.journeyID != new.journeyID { layers.setJourney(new) }
      if styleChanged || old.journeyID != new.journeyID { layers.setStops(new) }
      if old.selectedStop != new.selectedStop { layers.setSelectedStop(new) }
      if old.vehicles != new.vehicles || old.prefs.hiddenRoutes != new.prefs.hiddenRoutes
        || old.selectedVehicle != new.selectedVehicle || old.offRouteVehicles != new.offRouteVehicles
        || old.focus != new.focus || old.vehicleDirections != new.vehicleDirections || old.journeyID != new.journeyID
        || old.schedule?.feedVersion != new.schedule?.feedVersion
      {
        if old.vehicles != new.vehicles || old.prefs.estimateBusPositions != new.prefs.estimateBusPositions
          || old.schedule?.feedVersion != new.schedule?.feedVersion
        {
          animator.update(
            vehicles: new.vehicles, schedule: new.schedule, estimate: new.prefs.estimateBusPositions,
            smooth: new.prefs.smoothBusMovement, now: CACurrentMediaTime(), wall: Date())
        }
        flushBuses()
        startAnimationIfNeeded()
      }
    }

    if let camera, camera.id != lastCameraID {
      lastCameraID = camera.id
      fly(camera)
    }
    if let fit, fit.id != lastFitID {
      lastFitID = fit.id
      fitBounds(fit.coordinates)
    }
  }

  private func buildLayers(style: MLNStyle) {
    guard let overlay = state.overlay else { return }
    let built = MapLayers(style: style, overlay: overlay)
    layers = built
    appliedOverlay = overlay.feedVersion
    built.applyStyle(state)
    built.applyJourneyStyle(state)
    built.setJourney(state)
    built.setStops(state)
    built.setSelectedStop(state)
    animator.update(
      vehicles: state.vehicles, schedule: state.schedule, estimate: state.prefs.estimateBusPositions, smooth: false,
      now: CACurrentMediaTime(), wall: Date())
    flushBuses()
  }

  private func flushBuses() {
    guard let layers else { return }
    layers.setBuses(animator.positions(at: CACurrentMediaTime()).list, state: state)
  }

  // MARK: Smooth movement

  private func startAnimationIfNeeded() {
    guard state.prefs.smoothBusMovement || state.prefs.estimateBusPositions else { return }
    if displayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(tick))
      // Buses move slowly on screen; 20 frames a second looks smooth and is gentler on the battery.
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
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

  /// Zooms to show all of `coordinates`, leaving room for the sheet at the bottom and the buttons at the top.
  private func fitBounds(_ coordinates: [Coordinate]) {
    guard let mapView, let first = coordinates.first else { return }
    var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
    for c in coordinates {
      minLat = min(minLat, c.latitude)
      maxLat = max(maxLat, c.latitude)
      minLon = min(minLon, c.longitude)
      maxLon = max(maxLon, c.longitude)
    }
    let bounds = MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon), ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
    let padding = UIEdgeInsets(top: 130, left: 40, bottom: max(state.bottomInset, 320) + 30, right: 40)
    mapView.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: true, completionHandler: nil)
  }

  // MARK: MLNMapViewDelegate

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    layers = nil
    if state.overlay != nil { buildLayers(style: style) }
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

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began, let mapView else { return }
    let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
    onLongPress?(coordinate.latitude, coordinate.longitude)
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
    var routes: [String] = []
    for line in mapView.visibleFeatures(in: box, styleLayerIdentifiers: layers.lineLayerIDs) {
      if let route = line.attribute(forKey: "route") as? String, !routes.contains(route) { routes.append(route) }
    }
    if !routes.isEmpty {
      onTap?(.routes(routes))
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
