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
  /// Route ids serving each stop, ordered like the route list.
  private(set) var routesByStop: [String: [String]] = [:]
  /// The most common destinations of each route, for the route list.
  private(set) var headsignsByRoute: [String: [String]] = [:]
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
  var menuOpen = false
  /// A place the rider long-pressed on the map, waiting for them to say what to do with it.
  var droppedPin: PlanPoint?
  /// The journey drawn on the map, with the lines to draw.
  private(set) var mapJourney: Journey?
  private(set) var journeyLines: [JourneyPolyline] = []
  private(set) var fitRequest: FitRequest?
  private(set) var status: ServiceStatus?
  /// A route the user has tapped to look at on its own; every other route is dimmed.
  var focusedRouteID: String?
  private(set) var cameraRequest: CameraRequest?

  @ObservationIgnored private let client = RealtimeClient()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var isActive = true
  @ObservationIgnored private var focusFromBus = false
  @ObservationIgnored private var lastAlertFetch = Date.distantPast
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

  var orderedRoutes: [Route] {
    (schedule?.routes.values.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }) ?? []
  }

  func route(_ id: String) -> Route? { schedule?.routes[id] }

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
      if focusedRouteID == nil {
        focusedRouteID = vehicle.routeID
        focusFromBus = true
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

  /// Runs the planner with what the app currently knows.
  func searchJourneys() async {
    await plan.search(schedule: schedule, predictions: predictions, vehicles: vehicles, here: location.location)
  }

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

  func toggleFocus(route id: String) {
    focusFromBus = false
    focusedRouteID = focusedRouteID == id ? nil : id
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
    if sheet == nil, focusFromBus {
      focusedRouteID = nil
      focusFromBus = false
    }
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
      try await apply(try await Self.parse(url))
      phase = .ready
      Task { _ = await refreshFromNetwork(force: false) }
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private struct Parsed {
    let schedule: Schedule
    let routesByStop: [String: [String]]
    let headsigns: [String: [String]]
  }

  private static func parse(_ url: URL) async throws -> Parsed {
    let schedule = try await Task.detached(priority: .userInitiated) { try Schedule.load(zipAt: url) }.value
    let index = await Task.detached(priority: .utility) { Self.routesByStop(in: schedule) }.value
    let headsigns = await Task.detached(priority: .utility) { Self.headsigns(in: schedule) }.value
    return Parsed(schedule: schedule, routesByStop: index, headsigns: headsigns)
  }

  private func apply(_ parsed: Parsed) async throws {
    schedule = parsed.schedule
    routesByStop = parsed.routesByStop
    headsignsByRoute = parsed.headsigns
    refreshArrivals()
  }

  /// Fetches the timetable at most once a day (or when `force` is set). A new feed replaces the loaded one only if its
  /// version differs; a failed attempt (offline) changes nothing.
  private func refreshFromNetwork(force: Bool) async -> RefreshResult {
    guard let cache = Self.cacheURL else { return .failed }
    let modified = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    if !force, Date().timeIntervalSince(modified) < 86_400 { return .upToDate }
    do {
      let (temporary, response) = try await URLSession.shared.download(from: Self.scheduleURL)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
      let fresh = try await Self.parse(temporary)
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

  /// Used only when there is no local copy at all.
  private func downloadZip(replacingCache: Bool) async -> Bool {
    guard let cache = Self.cacheURL else { return false }
    do {
      let (temporary, response) = try await URLSession.shared.download(from: Self.scheduleURL)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
      try? FileManager.default.removeItem(at: cache)
      try FileManager.default.moveItem(at: temporary, to: cache)
      return true
    } catch {
      return false
    }
  }

  nonisolated private static func routesByStop(in schedule: Schedule) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for (stopID, visits) in schedule.visitsByStop {
      var routes: Set<String> = []
      for visit in visits { if let trip = schedule.trips[visit.tripID] { routes.insert(trip.routeID) } }
      result[stopID] = routes.sorted {
        let a = schedule.routes[$0]?.sortOrder ?? .max
        let b = schedule.routes[$1]?.sortOrder ?? .max
        return (a, $0) < (b, $1)
      }
    }
    return result
  }

  nonisolated private static func headsigns(in schedule: Schedule) -> [String: [String]] {
    var counts: [String: [String: Int]] = [:]
    for trip in schedule.trips.values where !trip.headsign.isEmpty { counts[trip.routeID, default: [:]][trip.headsign, default: 0] += 1 }
    return counts.mapValues { byHeadsign in
      byHeadsign.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(2).map(\.key)
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
        if isNew { await refreshSlowData() }
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
    if sheet?.isDetail == true || mode != .map {
      if let snapshot = try? await client.fetch(.trips) { predictions = snapshot.predictions }
    }
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
