import CoreLocation
import Foundation
import HeadwayCore
import Observation

/// What the sheet over the map is showing.
enum ActiveSheet: Identifiable, Equatable {
  case stop(String)
  case bus(String)  // vehicle id
  case settings
  case routes
  case search

  /// Stops and buses share one identity so that selecting another stop updates the open sheet instead of
  /// dismissing and presenting a new one.
  var id: String {
    switch self {
    case .stop, .bus: "detail"
    case .settings: "settings"
    case .routes: "routes"
    case .search: "search"
    }
  }

  var isDetail: Bool {
    switch self {
    case .stop, .bus: true
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

  private(set) var phase: Phase = .loading
  private(set) var schedule: Schedule?
  private(set) var vehicles: [VehicleSample] = []
  private(set) var predictions: [TripPrediction] = []
  private(set) var alerts: [ServiceAlert] = []
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
  /// A route the user has tapped to look at on its own; every other route is dimmed.
  var focusedRouteID: String?
  private(set) var cameraRequest: CameraRequest?

  @ObservationIgnored private let client = RealtimeClient()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var isActive = true
  @ObservationIgnored private var focusFromBus = false
  @ObservationIgnored private var lastAlertFetch = Date.distantPast

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

  private func pollLoop() async {
    while !Task.isCancelled {
      do {
        let snapshot = try await client.fetch(.vehicles)
        vehicles = snapshot.vehicles
        lastLiveUpdate = Date()
        liveFailing = false
      } catch is CancellationError {
        return
      } catch {
        if Task.isCancelled { return }  // a restart cancels the request; that is not a failure
        liveFailing = true
      }
      if Date().timeIntervalSince(lastAlertFetch) > 60 {
        // Service alerts change rarely and are tiny (about 3 KB).
        lastAlertFetch = Date()
        if let snapshot = try? await client.fetch(.alerts) { alerts = snapshot.alerts }
      }
      if sheet?.isDetail == true {
        // Trip predictions are about 250 KB, so they are only fetched while a stop or bus is open.
        if let snapshot = try? await client.fetch(.trips) { predictions = snapshot.predictions }
      }
      refreshArrivals()
      let interval = max(5, settings.values.updateInterval)
      try? await Task.sleep(for: .seconds(interval))
    }
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

  /// Alerts that concern this stop, either directly or through a route that serves it.
  func alerts(forStop id: String) -> [ServiceAlert] {
    let routes = Set(routesByStop[id] ?? [])
    return alerts.filter { alert in
      alert.stopIDs.contains(id) || !routes.isDisjoint(with: alert.routeIDs)
    }
  }

  func headsign(of tripID: String) -> String { schedule?.trips[tripID]?.headsign ?? "" }
}
