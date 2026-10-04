import Foundation
import HeadwayCore

/// Turns recorded bus positions into arrival observations, stores them, and summarises them for the app.
struct PunctualityBuilder {
  let schedule: Schedule
  let recordings: Recordings
  let store: ObservationStore

  private var timeZone: TimeZone { schedule.timeZone }

  private func localDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
  }

  /// Adds each recorded day that is new (or has more recordings than last time) to the store.
  func ingest(force: Bool = false) throws {
    let files = recordings.files(of: .vehicles)
    var byDay: [String: [RecordedFile]] = [:]
    for file in files { byDay[localDay(file.recordedAt), default: []].append(file) }
    let days = byDay.keys.sorted()
    let estimator = ArrivalEstimator(schedule: schedule)
    for (index, day) in days.enumerated() {
      guard let serviceDay = Int(day.replacingOccurrences(of: "-", with: "")) else { continue }
      // Trips that run past midnight finish in the next day's recordings: take its first four hours too.
      var dayFiles = byDay[day] ?? []
      if index + 1 < days.count, days[index + 1] > day {
        let next = byDay[days[index + 1]] ?? []
        if let start = dayFiles.first?.recordedAt, let first = next.first?.recordedAt, first.timeIntervalSince(start) < 36 * 3600 {
          dayFiles += next.filter { $0.recordedAt.timeIntervalSince(first) < 4 * 3600 && localDay($0.recordedAt) != day }
        }
      }
      let signature = "\(byDay[day]?.count ?? 0)"
      if !force, store.meta("files:\(day)") == signature, day != days.last { continue }
      print("ingesting \(day): \(dayFiles.count) snapshots")

      var samples: [String: [PositionSample]] = [:]
      var serviceDateCache: [String: ServiceDate?] = [:]
      for file in dayFiles {
        let snapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
        for vehicle in snapshot.vehicles {
          guard !vehicle.tripID.isEmpty, let time = vehicle.timestamp else { continue }
          let cacheKey = "\(vehicle.tripID)|\(localDay(time))"
          let serviceDate: ServiceDate?
          if let cached = serviceDateCache[cacheKey] {
            serviceDate = cached
          } else {
            serviceDate = schedule.serviceDate(of: vehicle.tripID, near: time)
            serviceDateCache[cacheKey] = .some(serviceDate)
          }
          guard let serviceDate, serviceDate.value == serviceDay else { continue }
          let key = "\(vehicle.tripID)|\(serviceDate.value)"
          if samples[key]?.last?.time == time { continue }  // the same report seen in two feeds
          samples[key, default: []].append(
            PositionSample(time: time, coordinate: Coordinate(latitude: vehicle.latitude, longitude: vehicle.longitude)))
        }
      }

      var rows: [ObservationRow] = []
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      for (key, list) in samples {
        let parts = key.split(separator: "|")
        let tripID = String(parts[0])
        guard let trip = schedule.trips[tripID] else { continue }
        for observation in estimator.observations(tripID: tripID, serviceDate: ServiceDate(serviceDay), samples: list) {
          let scheduled = observation.scheduled
          rows.append(
            ObservationRow(
              day: serviceDay, trip: tripID, route: trip.routeID, stop: observation.stopID, sequence: observation.sequence,
              dayType: DayType(ServiceDate(scheduled, in: timeZone), in: timeZone).rawValue,
              hour: calendar.component(.hour, from: scheduled), scheduled: Int(scheduled.timeIntervalSince1970),
              delay: Int(observation.delay.rounded())))
        }
      }
      try store.replace(day: serviceDay, with: rows)
      try store.setMeta("files:\(day)", signature)
      print("  \(samples.count) trips, \(rows.count) observations")
    }
  }

  /// Writes the cells the app uses.
  func export(to url: URL) throws -> PunctualityTable {
    var routeCells: [String: PunctualityCell] = [:]
    var stopCells: [String: PunctualityCell] = [:]

    func group(_ sql: String, key: (OpaquePointer) -> String, into cells: inout [String: PunctualityCell]) throws {
      var currentKey = ""
      var delays: [Double] = []
      var result: [String: PunctualityCell] = [:]
      func flush() { if !delays.isEmpty, let cell = PunctualityCell(delays: delays), cell.n >= 5 { result[currentKey] = cell } }
      try store.rows(sql) { statement in
        let k = key(statement)
        if k != currentKey {
          flush()
          currentKey = k
          delays = []
        }
        delays.append(Double(ObservationStore.int(statement, 4)))
      }
      flush()
      cells = result
    }

    try group(
      "SELECT route, dt, hour, 0, delay FROM obs ORDER BY route, dt, hour, delay",
      key: { PunctualityTable.routeKey(route: ObservationStore.text($0, 0), dayType: DayType(rawValue: ObservationStore.int($0, 1)) ?? .weekday, hour: ObservationStore.int($0, 2)) },
      into: &routeCells)
    try group(
      "SELECT route, stop, dt, hour / 2, delay FROM obs ORDER BY route, stop, dt, hour / 2, delay",
      key: { "\(ObservationStore.text($0, 0))|\(ObservationStore.text($0, 1))|\(ObservationStore.int($0, 2))|\(ObservationStore.int($0, 3))" },
      into: &stopCells)

    var days = 0, total = 0
    var first = "", last = ""
    try store.rows("SELECT COUNT(DISTINCT day), COUNT(*), MIN(day), MAX(day) FROM obs") { statement in
      days = ObservationStore.int(statement, 0)
      total = ObservationStore.int(statement, 1)
      func format(_ value: Int) -> String { String(format: "%04d-%02d-%02d", value / 10_000, value / 100 % 100, value % 100) }
      first = format(ObservationStore.int(statement, 2))
      last = format(ObservationStore.int(statement, 3))
    }
    let predictionBins = try Accuracy(schedule: schedule, recordings: recordings, store: store).bins()
    let table = PunctualityTable(
      generated: Date(), firstDay: first, lastDay: last, days: days, observations: total, routeCells: routeCells,
      stopCells: stopCells, predictionBins: predictionBins)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try table.encoded().write(to: url)
    return table
  }
}
