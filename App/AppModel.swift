import CoreLocation
import Foundation
import HeadwayCore
import Observation

/// What the app is for at the moment. The map stays alive underneath the other two.
enum AppMode: String, CaseIterable, Identifiable {
  case map, info, plan
  var id: String { rawValue }
}

/// What the sheet over the map is showing.
enum ActiveSheet: Identifiable, Equatable {
  case stop(String)
  case bus(String)  // vehicle id
  case journey
  case settings
  case routes
  case search

  /// Stops and buses share one identity so that selecting another stop updates the open sheet instead of
  /// dismissing and presenting a new one.
  var id: String {
    switch self {
    case .stop, .bus, .journey: "detail"
    case .settings: "settings"
    case .routes: "routes"
    case .search: "search"
    }
  }

  var isDetail: Bool {
    switch self {
    case .stop, .bus, .journey: true
    default: false
    }
  }
}

/// Asks the map to move. Each request has a fresh `id` so that asking for the same place twice still animates.
struct CameraRequest: Equatable {
  let id = UUID()
  let latitude: Double
  let longitude: Double
  /// The zoom to use; the map never zooms out for a request, only in.
  let minimumZoom: Double
}

/// Asks the map to show all of some coordinates at once.
struct FitRequest: Equatable {
  let id = UUID()
  let coordinates: [Coordinate]
}

/// App-wide state: the timetable, live buses, what is selected, and the arrivals shown for it.
@MainActor @Observable
final class AppModel {
  enum Phase {
    case loading
    case ready
    case failed(String)
  }

  let settings: AppSettings
  let location = LocationController()
  let plan = PlanModel()
  @ObservationIgnored let watch = WatchNotifier()
  /// Set when the rider asked to watch a route but notifications are not allowed for the app.
  var notificationsDenied = false

  private(set) var phase: Phase = .loading
  private(set) var schedule: Schedule?
  private(set) var vehicles: [VehicleSample] = []
  private(set) var predictions: [TripPrediction] = []
  private(set) var alerts: [ServiceAlert] = []
  /// How punctual routes and stops have been, and how far live predictions have been off (from recordings).
  private(set) var punctuality: PunctualityTable = .empty
  /// Buses that are far from the line their trip should follow, so probably on a detour.
  private(set) var offRouteVehicleIDs: Set<String> = []
  /// When on, the stop sheet and timetable also show routes the user chose to hide.
  var showHiddenRoutes = false
  private(set) var arrivals: [Arrival] = []
  /// What the map draws: route lines, stops and the route network. Loaded from a saved copy at launch, so that the map
  /// is complete before the timetable has been parsed.
  private(set) var overlay: MapOverlay?
  /// Direction (0 or 1) of each live bus's trip.
  private(set) var vehicleDirections: [String: Int] = [:]
  /// Scheduled service of each route and direction (`outlookKey`), for "no buses right now" versus "not running today".
  private(set) var outlooks: [String: ServiceOutlook] = [:]
  /// True when the board shows service after the next three hours because nothing else is coming.
  private(set) var arrivalsAreLater = false
  /// The stop to go back to from a bus opened out of that stop's board.
  private(set) var returnStopID: String?
  /// When the vehicle feed last answered successfully.
  private(set) var lastLiveUpdate: Date?
  /// True when the most recent poll failed.
  private(set) var liveFailing = false

  var sheet: ActiveSheet? {
    didSet { if sheet != oldValue { selectionChanged() } }
  }
  var mode: AppMode = .map {
    didSet {
      guard mode != oldValue else { return }
      menuOpen = false
      if mode != .map, sheet != nil { sheet = nil }
      refreshStatus()
      restartPolling()  // predictions are needed in every mode but the plain map
    }
  }
  /// The side menu. A sheet is drawn above everything else, so opening the menu puts the sheet away first (a journey
  /// then waits in the bar at the bottom of the map).
  var menuOpen = false {
    didSet { if menuOpen, !oldValue, sheet != nil { sheet = nil } }
  }
  /// True while the planner shows a pushed screen (a journey's details): the edge swipe then goes back, not to the menu.
  var planPushed = false
  /// A place the rider long-pressed on the map, waiting for them to say what to do with it.
  var droppedPin: PlanPoint?
  /// The journey drawn on the map, with the lines to draw.
  private(set) var mapJourney: Journey?
  private(set) var journeyLines: [JourneyPolyline] = []
  private(set) var fitRequest: FitRequest?
  private(set) var status: ServiceStatus?
  /// What the user asked the map to show on its own (a route, an alert, late buses); everything else is hidden or dimmed.
  private(set) var focus = MapFocus()
  /// Routes under the finger after a tap on overlapping lines, waiting for the rider to say which one.
  var routeChoices: [String] = []
  private(set) var cameraRequest: CameraRequest?

  @ObservationIgnored private let client = RealtimeClient()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var isActive = true
  @ObservationIgnored private var lastAlertFetch = Date.distantPast
  @ObservationIgnored private var lastTripsFetch = Date.distantPast
  @ObservationIgnored private var feedTimestamp: Date?
  @ObservationIgnored private var feedPeriod: TimeInterval = 30
  @ObservationIgnored private var periods: [TimeInterval] = []

  static let scheduleURL = URL(string: "https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip")!

  init(settings: AppSettings) {
    self.settings = settings
  }

  // MARK: Derived state

  var selectedStopID: String? {
    if case .stop(let id) = sheet { return id }
    return nil
  }

  var selectedVehicle: VehicleSample? {
    if case .bus(let id) = sheet { return vehicles.first { $0.id == id } }
    return nil
  }

  var orderedRoutes: [Route] { overlay?.orderedRoutes ?? [] }

  func route(_ id: String) -> Route? { overlay?.routes[id] ?? schedule?.routes[id] }

  /// Route ids serving each stop, ordered like the route list.
  var routesByStop: [String: [String]] { overlay?.network.routesByStop ?? [:] }

  /// Key of `outlooks`: a route in one direction, or in both (nil).
  nonisolated static func outlookKey(route: String, direction: Int?) -> String { "\(route)|\(direction.map(String.init) ?? "*")" }

  func outlook(route: String, direction: Int?) -> ServiceOutlook? { outlooks[Self.outlookKey(route: route, direction: direction)] }

  /// Buses on a route (in one direction, or both) in the live feed.
  func busCount(route: String, direction: Int?) -> Int {
    vehicles.reduce(0) { count, vehicle in
      guard vehicle.routeID == route else { return count }
      if let direction, vehicleDirections[vehicle.id] != direction { return count }
      return count + 1
    }
  }

  /// Which way buses go at a stop ("Southbound"), when the feed says.
  func stopSide(_ id: String?) -> String? {
    guard let id else { return nil }
    return Compass.bound(schedule?.stops[id]?.facing ?? overlay?.stops[id]?.facing)
  }

  /// The direction of a trip in words ("Southbound"), from the feed's direction name.
  func tripDirection(_ tripID: String) -> String? {
    guard let trip = schedule?.trips[tripID], !trip.directionName.isEmpty else { return nil }
    return Self.compassName(trip.directionName)
  }

  /// A stop's name with the way its buses go, to tell apart the two stops of the same name on either side of a street.
  func stopTitle(_ point: PlanPoint) -> String {
    guard let side = stopSide(point.stopID) else { return point.name }
    return "\(point.name) (\(side))"
  }

  /// The ways a route runs (one entry per direction).
  func variants(of route: String) -> [RouteVariant] { overlay?.network.variants(of: route) ?? [] }

  var hiddenRoutes: Set<String> { settings.values.hiddenRoutes }

  /// Arrivals for the selected stop, without routes the user hides (unless they asked to see them).
  var boardArrivals: [Arrival] {
    showHiddenRoutes ? arrivals : arrivals.filter { !hiddenRoutes.contains($0.routeID) }
  }

  var hiddenArrivalCount: Int { arrivals.count - arrivals.filter { !hiddenRoutes.contains($0.routeID) }.count }

  /// Routes serving a stop, without hidden ones unless the user asked to see them.
  func visibleRoutes(atStop id: String) -> [String] {
    let all = routesByStop[id] ?? []
    return showHiddenRoutes ? all : all.filter { !hiddenRoutes.contains($0) }
  }

  /// Alerts in force right now.
  var activeAlerts: [ServiceAlert] {
    let now = Date()
    return alerts.filter { $0.isActive(at: now) }
  }

  /// Alerts in force, without those that only concern routes the rider hides.
  var visibleActiveAlerts: [ServiceAlert] {
    activeAlerts.filter { $0.routeIDs.isEmpty || $0.routeIDs.contains { !hiddenRoutes.contains($0) } }
  }

  var upcomingAlerts: [ServiceAlert] {
    let now = Date()
    return alerts.filter { $0.isUpcoming(at: now) }
  }

  /// Routes with an alert in force: drawn dashed on the map.
  var alertRouteIDs: Set<String> { Set(activeAlerts.flatMap(\.routeIDs)) }

  func timeText() -> TimeText {
    TimeText(
      timeZone: schedule?.timeZone ?? TimeZone(identifier: "America/Chicago")!,
      clockFormat: settings.values.clockFormat,
      arrivalStyle: settings.values.arrivalStyle)
  }

  // MARK: Lifecycle

  func start() async {
    guard !started else { return }
    started = true
    restartPolling()
    Task { await loadPunctuality() }
    // The saved copy of the map data shows every route right away; the timetable is parsed behind it.
    if let saved = await Task.detached(priority: .userInitiated, operation: { OverlayStore.load() }).value, overlay == nil {
      overlay = saved
    }
    await loadSchedule()
  }

  enum RefreshResult { case updated, upToDate, failed }

  /// Downloads the timetable now, whatever the cache says.
  func refreshTimetable() async -> RefreshResult {
    await refreshFromNetwork(force: true)
  }

  func retry() async {
    phase = .loading
    await loadSchedule()
  }

  /// Live polling pauses in the background when the user chose that.
  func setActive(_ active: Bool) {
    isActive = active
    restartPolling()
  }

  // MARK: Selection and camera

  func selectStop(_ id: String, moveCamera: Bool = true) {
    guard let stop = schedule?.stops[id] else { return }
    settings.noteRecent(stop: id)
    Haptics.selection(enabled: settings.values.hapticFeedback)
    sheet = .stop(id)
    if moveCamera { fly(to: stop.latitude, stop.longitude, minimumZoom: 15) }
  }

  func selectBus(_ vehicleID: String) {
    returnStopID = selectedStopID ?? (sheet?.isDetail == true ? returnStopID : nil)
    sheet = .bus(vehicleID)
    if let vehicle = vehicles.first(where: { $0.id == vehicleID }) {
      fly(to: vehicle.latitude, vehicle.longitude, minimumZoom: 14)
      if !focus.isActive {
        var next = MapFocus.route(vehicle.routeID, direction: vehicleDirections[vehicle.id])
        next.fromBus = true
        focus = next
      }
    }
  }

  // MARK: Punctuality

  private func loadPunctuality() async {
    guard let url = Bundle.main.url(forResource: "punctuality", withExtension: "json") else { return }
    let table = await Task.detached(priority: .utility) { () -> PunctualityTable? in
      guard let data = try? Data(contentsOf: url) else { return nil }
      return try? PunctualityTable.decode(data)
    }.value
    if let table { punctuality = table }
  }

  /// Past punctuality of `route` (at `stop`, if given) at this time of day and week, when there is enough history.
  func reliability(route: String, stop: String?, at date: Date = Date()) -> PunctualityTable.Match? {
    punctuality.match(route: route, stop: stop, at: date, in: schedule?.timeZone ?? TimeZone(identifier: "America/Chicago")!)
  }

  /// When a live bus has come in 9 of 10 past cases for a prediction this far ahead.
  func window(for arrival: Arrival, now: Date = Date()) -> (earliest: Date, latest: Date)? {
    guard arrival.status == .live,
      let offsets = punctuality.window(predictedIn: arrival.expected.timeIntervalSince(now))
    else { return nil }
    return (max(now, arrival.expected.addingTimeInterval(offsets.earliest)), arrival.expected.addingTimeInterval(offsets.latest))
  }

  // MARK: Journeys

  /// The planner's options as set in Settings.
  func plannerOptions() -> PlanOptions {
    let prefs = settings.values
    var options = PlanOptions()
    options.walkSpeed = prefs.walkSpeed.metersPerSecond
    options.maxWalkMeters = Double(prefs.maxWalkMeters)
    options.maxRides = prefs.maxTransfers + 1
    options.minTransferSeconds = Double(prefs.transferSeconds)
    options.accessibleOnly = prefs.accessibleOnly
    return options
  }

  func planContext() -> PlanContext {
    PlanContext(
      schedule: schedule, predictions: predictions, vehicles: vehicles, here: location.location, options: plannerOptions())
  }

  /// Runs the planner with what the app currently knows, and remembers the search.
  func searchJourneys() async {
    if let from = plan.from, let to = plan.to { settings.noteRecent(from: from, to: to, vias: plan.storedVias) }
    await plan.search(planContext())
  }

  func loadLaterJourneys() async { await plan.loadLater(planContext()) }
  func loadEarlierJourneys() async { await plan.loadEarlier(planContext()) }

  /// Draws a journey on the map and opens its summary.
  func showOnMap(_ journey: Journey) {
    guard let schedule else { return }
    let lines = journey.polylines(schedule: schedule)
    mapJourney = journey
    journeyLines = lines
    mode = .map
    sheet = .journey
    fitRequest = FitRequest(coordinates: lines.flatMap(\.coordinates))
  }

  func clearJourney() {
    mapJourney = nil
    journeyLines = []
    if sheet == .journey { sheet = nil }
  }

  /// Starts a trip from the rider's location (or the previous start) to `point`, in the planner.
  func startDirections(to point: PlanPoint) {
    plan.to = .point(point)
    plan.vias = []
    if plan.from == nil || plan.from == plan.to { plan.from = .myLocation }
    plan.clearResults()
    mapJourney = nil
    journeyLines = []
    mode = .plan
    location.start()
  }

  /// Starts a trip from `point` to wherever the rider wants to go.
  func startDirections(from point: PlanPoint) {
    plan.from = .point(point)
    plan.vias = []
    if plan.to == plan.from { plan.to = nil }
    plan.clearResults()
    mapJourney = nil
    journeyLines = []
    mode = .plan
  }

  func clearSelection() {
    returnStopID = nil
    sheet = nil
  }

  /// Shows only `id` (in one direction, or both). Choosing from a list zooms out to the whole route; tapping the map
  /// does not move the camera.
  func focusRoute(_ id: String, direction: Int? = nil, fit: Bool = true) {
    routeChoices = []
    focus = .route(id, direction: direction)
    if mode != .map { mode = .map }
    if fit { fitToFocus() }
  }

  /// A tap on route lines: one route is looked at on its own (or let go of when it already is); several ask which.
  func tapRoutes(_ ids: [String]) {
    let ordered = ids.sorted { (route($0)?.sortOrder ?? .max, $0) < (route($1)?.sortOrder ?? .max, $1) }
    if ordered.count == 1, let id = ordered.first {
      if focus.routes == [id], focus.highlightedStops.isEmpty, focus.highlightedBuses.isEmpty {
        focus = MapFocus()
      } else {
        focusRoute(id, direction: nil, fit: false)
      }
      routeChoices = []
    } else {
      routeChoices = ordered
    }
  }

  func clearFocus() {
    focus = MapFocus()
    routeChoices = []
  }

  /// Changes the direction of the route in focus (nil for both).
  func setFocusDirection(_ direction: Int?) {
    guard focus.routes.count == 1 else { return }
    focus.direction = direction
    focus.fromBus = false
  }

  /// "Show on map" for an alert: its routes, and the stops its text names, ringed.
  func focusAlert(_ alert: ServiceAlert) {
    let routes = alert.routeIDs.filter { overlay?.routes[$0] != nil }
    guard !routes.isEmpty else { return }
    var next = MapFocus(routes: Set(routes))
    next.highlightedStops = alertStops(alert)
    next.label = alert.header
    next.isAlert = true
    focus = next
    sheet = nil
    mode = .map
    fitToFocus()
  }

  /// Rings these buses (late or early) and hides the others.
  func focusBuses(_ buses: [String: BusHighlight], label: String) {
    let routes = Set(buses.keys.compactMap { id in vehicles.first { $0.id == id }?.routeID })
    guard !routes.isEmpty else { return }
    var next = MapFocus(routes: routes)
    next.highlightedBuses = buses
    next.label = label
    focus = next
    sheet = nil
    mode = .map
    fitToFocus()
  }

  /// True when the map has something to show for an alert (it names a route).
  func alertCanBeShown(_ alert: ServiceAlert) -> Bool { alert.routeIDs.contains { overlay?.routes[$0] != nil } }

  /// Shows the buses that are running late or early (all routes, or one) and rings them on the map.
  func focusDelays(route: String? = nil, late: Bool = true, early: Bool = false) {
    guard let status else { return }
    var buses: [String: BusHighlight] = [:]
    for row in status.routes where route == nil || row.routeID == route {
      if late { for id in row.lateVehicleIDs { buses[id] = .late } }
      if early { for id in row.earlyVehicleIDs { buses[id] = .early } }
    }
    if buses.isEmpty, let route {
      focusRoute(route)
    } else {
      let label = late && early ? String(localized: "Late and early buses") : (late ? String(localized: "Late buses") : String(localized: "Early buses"))
      focusBuses(buses, label: label)
    }
  }

  /// Stops an alert is about: the ids it lists, plus stop codes written in its text ("stop 1234").
  func alertStops(_ alert: ServiceAlert) -> [String] {
    guard let overlay else { return [] }
    var found = alert.stopIDs.filter { overlay.stops[$0] != nil }
    let byCode = Dictionary(overlay.data.stops.filter { !$0.code.isEmpty }.map { ($0.code, $0.id) }, uniquingKeysWith: { first, _ in first })
    for code in StopCodes.find(in: alert.header + " " + alert.detail) {
      if let id = byCode[code], !found.contains(id) { found.append(id) }
    }
    return found
  }

  /// Zooms the map out to show what is in focus.
  private func fitToFocus() {
    guard let overlay, focus.isActive else { return }
    var points: [Coordinate] = []
    for route in focus.routes { points += overlay.coordinates(route: route, direction: focus.direction) }
    for id in focus.highlightedStops { if let stop = overlay.stops[id] { points.append(Coordinate(latitude: stop.latitude, longitude: stop.longitude)) } }
    for id in focus.highlightedBuses.keys { if let bus = vehicles.first(where: { $0.id == id }) { points.append(Coordinate(latitude: bus.latitude, longitude: bus.longitude)) } }
    if !points.isEmpty { fitRequest = FitRequest(coordinates: points) }
  }

  /// The feed's direction name in the app's language ("Westbound" is "西行き"); other names are shown as the feed has them.
  private static func compassName(_ name: String) -> String {
    switch name.lowercased() {
    case "eastbound": String(localized: "Eastbound")
    case "westbound": String(localized: "Westbound")
    case "northbound": String(localized: "Northbound")
    case "southbound": String(localized: "Southbound")
    default: name.capitalized
    }
  }

  /// An arrow for the compass direction a route runs in ("Westbound" is an arrow to the left).
  func directionSymbol(route: String, direction: Int) -> String {
    switch variants(of: route).first(where: { $0.direction == direction })?.directionName.lowercased() {
    case "eastbound": "arrow.right"
    case "westbound": "arrow.left"
    case "northbound": "arrow.up"
    case "southbound": "arrow.down"
    default: "arrow.right"
    }
  }

  /// "Westbound to Airport, Epic Campus" for the direction of a route.
  func directionTitle(route: String, direction: Int) -> String {
    guard let variant = variants(of: route).first(where: { $0.direction == direction }) else { return "" }
    let places = variant.headsigns.map(\.prettyHeadsign).joined(separator: ", ")
    let name = Self.compassName(variant.directionName)
    if name.isEmpty { return places }
    return places.isEmpty ? name : String(localized: "\(name) to \(places)")
  }

  func fly(to latitude: Double, _ longitude: Double, minimumZoom: Double) {
    cameraRequest = CameraRequest(latitude: latitude, longitude: longitude, minimumZoom: minimumZoom)
  }

  func locateMe() {
    location.start()
    if let here = location.location {
      fly(to: here.coordinate.latitude, here.coordinate.longitude, minimumZoom: 15)
    }
  }

  private func selectionChanged() {
    showHiddenRoutes = false
    // Closing a bus sheet releases the route that selecting the bus focused.
    if sheet == nil, focus.fromBus { focus = MapFocus() }
    refreshArrivals()
    restartPolling()  // trip predictions are only fetched while a stop or bus is open
  }

  // MARK: Timetable

  private static var cacheURL: URL? {
    try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("mmt_gtfs.zip")
  }

  /// The timetable to start with: the cached download, else the copy bundled with the app, else nothing.
  private func startingZip() -> URL? {
    guard let cache = Self.cacheURL else { return nil }
    if FileManager.default.fileExists(atPath: cache.path) { return cache }
    guard let seed = Bundle.main.url(forResource: "mmt_gtfs", withExtension: "zip") else { return nil }
    try? FileManager.default.copyItem(at: seed, to: cache)
    // Mark the copy as old so that the first launch with a connection fetches a fresh timetable.
    try? FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: cache.path)
    return FileManager.default.fileExists(atPath: cache.path) ? cache : seed
  }

  private func loadSchedule() async {
    do {
      var url = startingZip()
      if url == nil {
        // Nothing local: the first launch needs the network.
        guard await downloadZip(replacingCache: true) else { throw URLError(.notConnectedToInternet) }
        url = Self.cacheURL
      }
      guard let url else { throw URLError(.fileDoesNotExist) }
      try await apply(try await Self.parse(url, current: overlay))
      phase = .ready
      Task { _ = await refreshFromNetwork(force: false) }
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private struct Parsed {
    let schedule: Schedule
    /// Nil when the drawing the map already has is for this timetable and current.
    let overlay: MapOverlayData?
  }

  /// Parses a timetable, and computes the map's drawing for it unless `current` (the drawing the map has) already fits:
  /// laying out the lanes takes a moment, so it is done once per timetable, not on every launch.
  private static func parse(_ url: URL, current: MapOverlay? = nil) async throws -> Parsed {
    let schedule = try await Task.detached(priority: .userInitiated) { try Schedule.load(zipAt: url) }.value
    if let current, current.feedVersion == schedule.feedVersion, !current.isOutdated {
      return Parsed(schedule: schedule, overlay: nil)
    }
    let overlay = await Task.detached(priority: .utility) { MapOverlayData(schedule: schedule, network: RouteNetwork(schedule: schedule)) }.value
    return Parsed(schedule: schedule, overlay: overlay)
  }

  private func apply(_ parsed: Parsed) async throws {
    schedule = parsed.schedule
    if let data = parsed.overlay {
      overlay = MapOverlay(data)
      Task.detached(priority: .utility) { OverlayStore.save(data) }
    }
    vehicleDirections = directions(of: vehicles)
    refreshOutlooks()
    refreshArrivals()
  }

  /// Works out today's service of every route and direction in the background (a few hundred milliseconds in a Release
  /// build); called when the timetable arrives and when a screen that shows it opens.
  func refreshOutlooks() {
    guard let schedule, let overlay else { return }
    let routes = overlay.orderedRoutes.map(\.id)
    Task.detached(priority: .utility) { [weak self] in
      let now = Date()
      var result: [String: ServiceOutlook] = [:]
      for route in routes {
        for direction in [nil, 0, 1] as [Int?] {
          result[Self.outlookKey(route: route, direction: direction)] = schedule.outlook(route: route, direction: direction, at: now)
        }
      }
      await MainActor.run { self?.outlooks = result }
    }
  }

  /// The direction of each bus's trip, from the timetable.
  private func directions(of vehicles: [VehicleSample]) -> [String: Int] {
    guard let schedule else { return [:] }
    var result: [String: Int] = [:]
    for vehicle in vehicles { if let trip = schedule.trips[vehicle.tripID] { result[vehicle.id] = trip.directionID } }
    return result
  }

  /// Fetches the timetable at most once a day (or when `force` is set). The server is asked first whether the file has
  /// changed (it sends an ETag), so a day without a new timetable costs a few hundred bytes instead of 7 MB. A new feed
  /// replaces the loaded one only if its version differs; a failed attempt (offline) changes nothing.
  private func refreshFromNetwork(force: Bool) async -> RefreshResult {
    guard let cache = Self.cacheURL else { return .failed }
    let modified = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    if !force, Date().timeIntervalSince(modified) < 86_400 { return .upToDate }
    var request = URLRequest(url: Self.scheduleURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let defaults = UserDefaults.standard
    if FileManager.default.fileExists(atPath: cache.path) {
      if let etag = defaults.string(forKey: Self.etagKey) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
      if let date = defaults.string(forKey: Self.lastModifiedKey) { request.setValue(date, forHTTPHeaderField: "If-Modified-Since") }
    }
    do {
      let (temporary, response) = try await URLSession.shared.download(for: request)
      guard let http = response as? HTTPURLResponse else { return .failed }
      if http.statusCode == 304 {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
        return .upToDate
      }
      guard http.statusCode == 200 else { return .failed }
      let fresh = try await Self.parse(temporary, current: overlay)
      remember(http, in: defaults)
      if fresh.schedule.feedVersion == schedule?.feedVersion {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
        return .upToDate
      }
      try? FileManager.default.removeItem(at: cache)
      try FileManager.default.moveItem(at: temporary, to: cache)
      try await apply(fresh)
      return .updated
    } catch {
      return .failed
    }
  }

  private static let etagKey = "timetable.etag"
  private static let lastModifiedKey = "timetable.lastModified"

  /// Keeps what the server said about the file we have, for the next conditional request.
  private func remember(_ response: HTTPURLResponse, in defaults: UserDefaults) {
    defaults.set(response.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
    defaults.set(response.value(forHTTPHeaderField: "Last-Modified"), forKey: Self.lastModifiedKey)
  }

  /// Used only when there is no local copy at all.
  private func downloadZip(replacingCache: Bool) async -> Bool {
    guard let cache = Self.cacheURL else { return false }
    do {
      let (temporary, response) = try await URLSession.shared.download(from: Self.scheduleURL)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
      try? FileManager.default.removeItem(at: cache)
      try FileManager.default.moveItem(at: temporary, to: cache)
      remember(http, in: .standard)
      return true
    } catch {
      return false
    }
  }

  // MARK: Live data

  private func restartPolling() {
    pollTask?.cancel()
    guard started else { return }
    if !isActive && settings.values.pauseLiveInBackground { return }
    pollTask = Task { [weak self] in await self?.pollLoop() }
  }

  /// The city rebuilds its feed on a fixed beat (30 s, measured) and each bus reports on the same beat, so asking more
  /// often only returns the same data. After a new feed is seen, the next request waits until just before the next
  /// beat; if the feed has not changed yet, it tries again every 2 seconds. This gives the freshest positions with
  /// about a third of the requests of a fixed 10-second poll. Only local time is used, so a wrong clock on the phone
  /// cannot throw the timing off.
  private func pollLoop() async {
    var unchanged = 0
    var lastChange = Date.distantPast
    while !Task.isCancelled {
      var delay = 10.0
      do {
        let snapshot = try await client.fetch(.vehicles)
        let isNew = vehicles.isEmpty || snapshot.feedTimestamp == nil || snapshot.feedTimestamp != feedTimestamp
        if isNew {
          if let old = feedTimestamp, let new = snapshot.feedTimestamp, new > old { notePeriod(new.timeIntervalSince(old)) }
          feedTimestamp = snapshot.feedTimestamp
          vehicles = snapshot.vehicles
          vehicleDirections = directions(of: snapshot.vehicles)
          offRouteVehicleIDs = computeOffRoute(snapshot.vehicles)
          unchanged = 0
          lastChange = Date()
        } else {
          unchanged += 1
        }
        lastLiveUpdate = Date()
        liveFailing = false
        let fixed = settings.values.updateInterval
        if fixed > 0 {
          delay = Double(fixed)
        } else if isNew, let stamp = snapshot.feedTimestamp, let serverNow = snapshot.serverDate {
          // The next feed is stamped one period after this one. The server's own clock says how far off that is, so the
          // phone's clock does not matter. A second and a half leaves time for the server to publish it.
          delay = min(45, max(2, stamp.addingTimeInterval(feedPeriod + 1.5).timeIntervalSince(serverNow)))
        } else if isNew {
          delay = max(2, lastChange.addingTimeInterval(feedPeriod - 1).timeIntervalSinceNow)
        } else {
          delay = unchanged < 8 ? 2 : 10  // the feed is late or stopped: do not hammer the server
        }
        if isNew {
          await refreshSlowData()
          await evaluateWatch()
        }
      } catch is CancellationError {
        return
      } catch {
        if Task.isCancelled { return }  // a restart cancels the request; that is not a failure
        liveFailing = true
      }
      refreshArrivals()
      refreshStatus()
      try? await Task.sleep(for: .seconds(delay))
    }
  }

  /// Alerts (about 3 KB, change rarely) and trip predictions (about 250 KB, only needed while a stop, a bus, the service
  /// board or the planner is open) ride along with a new vehicle feed.
  private func refreshSlowData() async {
    if Date().timeIntervalSince(lastAlertFetch) > 60 {
      lastAlertFetch = Date()
      if let snapshot = try? await client.fetch(.alerts) { alerts = snapshot.alerts }
    }
    // Watching a route needs the predictions too, but a minute old is old enough.
    let watching = settings.values.watchEnabled && !settings.values.watchedRoutes.isEmpty && Date().timeIntervalSince(lastTripsFetch) > 60
    if sheet?.isDetail == true || mode != .map || watching {
      if let snapshot = try? await client.fetch(.trips) {
        predictions = snapshot.predictions
        lastTripsFetch = Date()
      }
    }
  }

  // MARK: Watched routes

  /// Turns watching of a route on or off; the first time, asks for permission to send notifications.
  func setWatching(route id: String, _ on: Bool) async {
    if on {
      if !settings.values.watchEnabled {
        guard await WatchNotifier.authorize() else {
          notificationsDenied = true
          return
        }
        settings.values.watchEnabled = true
      }
      if !settings.values.watchedRoutes.contains(id) { settings.values.watchedRoutes.append(id) }
    } else {
      settings.values.watchedRoutes.removeAll { $0 == id }
    }
  }

  func isWatching(route id: String) -> Bool { settings.values.watchedRoutes.contains(id) }

  /// Looks at the watched routes with what is known now and notifies about anything new.
  func evaluateWatch() async {
    let prefs = settings.values
    guard prefs.watchEnabled, !prefs.watchedRoutes.isEmpty, let schedule else { return }
    var kinds: Set<WatchKind> = []
    if prefs.watchLate { kinds.insert(.late) }
    if prefs.watchEarly { kinds.insert(.early) }
    if prefs.watchAlerts { kinds.insert(.alert) }
    let now = Date()
    let status = ServiceStatusBuilder.build(schedule: schedule, predictions: predictions, vehicles: vehicles, now: now)
    let events = WatchEvaluator.evaluate(status: status, alerts: alerts, now: now, routes: Set(prefs.watchedRoutes), kinds: kinds)
    await watch.deliver(events, now: now) { [weak self] id in self?.route(id)?.shortName ?? id }
  }

  /// One check from the background: loads what is needed, looks, and goes back to sleep.
  func runBackgroundWatch() async {
    guard settings.values.watchEnabled, !settings.values.watchedRoutes.isEmpty else { return }
    if schedule == nil, let url = startingZip() { try? await apply(try await Self.parse(url, current: overlay)) }
    guard schedule != nil else { return }
    if let snapshot = try? await client.fetch(.vehicles) { vehicles = snapshot.vehicles }
    if let snapshot = try? await client.fetch(.trips) { predictions = snapshot.predictions }
    if let snapshot = try? await client.fetch(.alerts) { alerts = snapshot.alerts }
    await evaluateWatch()
  }

  /// The feed's rebuild period, learned from the gaps between its timestamps (30 s until seen).
  private func notePeriod(_ seconds: TimeInterval) {
    guard seconds > 5, seconds < 120 else { return }
    periods.append(seconds)
    if periods.count > 9 { periods.removeFirst() }
    feedPeriod = periods.sorted()[periods.count / 2]
  }

  /// Median age of the bus positions on screen, in seconds: how far behind the real buses the map is.
  func positionAge(at now: Date) -> TimeInterval? {
    let ages = vehicles.compactMap { $0.timestamp.map { now.timeIntervalSince($0) } }.sorted()
    guard !ages.isEmpty else { return nil }
    return max(0, ages[ages.count / 2])
  }

  /// Recomputes the service board when it is on screen.
  func refreshStatus() {
    guard mode == .info, let schedule else { return }
    status = ServiceStatusBuilder.build(schedule: schedule, predictions: predictions, vehicles: vehicles, now: Date())
  }

  /// A moving bus more than 150 m from its trip's line is treated as off its usual route. Standing buses (at a terminal
  /// or a stop) are ignored, since they are often parked off the line.
  private func computeOffRoute(_ vehicles: [VehicleSample]) -> Set<String> {
    guard let schedule else { return [] }
    var result: Set<String> = []
    for vehicle in vehicles {
      if let speed = vehicle.speed, speed < 0.5 { continue }
      if let distance = schedule.distanceFromRoute(of: vehicle), distance > 150 { result.insert(vehicle.id) }
    }
    return result
  }

  /// Recomputes the board for the selected stop.
  func refreshArrivals() {
    guard let schedule, let stopID = selectedStopID else {
      if !arrivals.isEmpty { arrivals = [] }
      return
    }
    let now = Date()
    var found = Arrivals.upcoming(schedule: schedule, stopID: stopID, now: now, predictions: predictions, vehicles: vehicles)
    arrivalsAreLater = false
    if found.isEmpty {
      // Nothing in the next three hours (late at night): show when service resumes.
      found = Arrivals.upcoming(
        schedule: schedule, stopID: stopID, now: now, window: 30 * 3600, predictions: predictions, vehicles: vehicles, limit: 6)
      arrivalsAreLater = !found.isEmpty
    }
    arrivals = found
  }

  // MARK: Bus details

  func remainingStops(of vehicle: VehicleSample) -> [TripStopEta] {
    guard let schedule else { return [] }
    let prediction = predictions.first { $0.tripID == vehicle.tripID }
    return Arrivals.remainingStops(schedule: schedule, tripID: vehicle.tripID, now: Date(), prediction: prediction)
  }

  /// Alerts in force that concern this stop, directly or through a route that serves it.
  func alerts(forStop id: String) -> [ServiceAlert] {
    let routes = Set(visibleRoutes(atStop: id))
    return activeAlerts.filter { alert in
      alert.stopIDs.contains(id) || !routes.isDisjoint(with: alert.routeIDs)
    }
  }

  func alerts(forRoute id: String) -> [ServiceAlert] {
    activeAlerts.filter { $0.routeIDs.contains(id) }
  }

  func headsign(of tripID: String) -> String { schedule?.trips[tripID]?.headsign ?? "" }
}
