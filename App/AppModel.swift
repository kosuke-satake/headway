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

  /// Throws away the cached timetable and downloads a fresh one.
  func refreshTimetable() async {
    if let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("mmt_gtfs.zip"))
    }
    await loadSchedule()
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

  private func loadSchedule() async {
    do {
      let url = try await cachedScheduleZip()
      let loaded = try await Task.detached(priority: .userInitiated) { try Schedule.load(zipAt: url) }.value
      let index = await Task.detached(priority: .utility) { Self.routesByStop(in: loaded) }.value
      let headsigns = await Task.detached(priority: .utility) { Self.headsigns(in: loaded) }.value
      schedule = loaded
      routesByStop = index
      headsignsByRoute = headsigns
      phase = .ready
      refreshArrivals()
    } catch {
      phase = .failed(error.localizedDescription)
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

  /// The timetable zip in Application Support. It is downloaded once; a cached copy is used when offline.
  private func cachedScheduleZip() async throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let cached = directory.appendingPathComponent("mmt_gtfs.zip")
    let age = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      .map { Date().timeIntervalSince($0) }
    // Refresh at most once a day; a failed refresh falls back to the cached copy.
    if age == nil || age! > 86_400 {
      do {
        let (temporary, response) = try await URLSession.shared.download(from: Self.scheduleURL)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
          try? FileManager.default.removeItem(at: cached)
          try FileManager.default.moveItem(at: temporary, to: cached)
        }
      } catch {
        if age == nil { throw error }
      }
    }
    return cached
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

  func headsign(of tripID: String) -> String { schedule?.trips[tripID]?.headsign ?? "" }
}
