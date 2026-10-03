import Foundation
import ZIPFoundation

public enum ScheduleError: Error {
  case missingFile(String)
  case unreadableArchive(URL)
}

/// The static GTFS feed, held in memory.
///
/// This is the straightforward loader used by tests and the analysis tool. The app will load the same feed into
/// SQLite once so that start-up does not parse 600,000 rows each time.
public struct Schedule: Sendable {
  public let timeZone: TimeZone
  public let feedVersion: String
  public let feedStart: ServiceDate?
  public let feedEnd: ServiceDate?
  public let routes: [String: Route]
  public let stops: [String: Stop]
  public let trips: [String: Trip]
  /// Stop times per trip, ordered by `sequence`.
  public let stopTimes: [String: [StopTime]]
  /// Shape polylines, ordered by point sequence.
  public let shapes: [String: [Coordinate]]
  public let calendars: [String: ServiceCalendar]
  /// `service_id` -> date -> exception type (1 = added, 2 = removed).
  public let calendarExceptions: [String: [ServiceDate: Int]]

  // MARK: Loading

  public static func load(zipAt url: URL) throws -> Schedule {
    guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
      throw ScheduleError.unreadableArchive(url)
    }
    func file(_ name: String) throws -> Data {
      guard let entry = archive[name] else { throw ScheduleError.missingFile(name) }
      var data = Data()
      _ = try archive.extract(entry) { data.append($0) }
      return data
    }
    func optionalFile(_ name: String) -> Data? { archive[name] == nil ? nil : try? file(name) }
    return try Schedule(file: file, optionalFile: optionalFile)
  }

  public static func load(directory url: URL) throws -> Schedule {
    func file(_ name: String) throws -> Data {
      let path = url.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: path) else { throw ScheduleError.missingFile(name) }
      return data
    }
    func optionalFile(_ name: String) -> Data? { try? file(name) }
    return try Schedule(file: file, optionalFile: optionalFile)
  }

  private init(file: (String) throws -> Data, optionalFile: (String) -> Data?) throws {
    // agency.txt gives the time zone that every schedule time is relative to.
    let agency = CSVFile(data: try file("agency.txt"))
    var zoneName = "America/Chicago"
    agency.forEachRow { row in
      let name = row.string(agency.header["agency_timezone"])
      if !name.isEmpty, zoneName == "America/Chicago" { zoneName = name }
    }
    self.timeZone = TimeZone(identifier: zoneName) ?? TimeZone(identifier: "America/Chicago")!

    var version = ""
    var start: ServiceDate?
    var end: ServiceDate?
    if let data = optionalFile("feed_info.txt") {
      let info = CSVFile(data: data)
      info.forEachRow { row in
        version = row.string(info.header["feed_version"])
        start = row.int(info.header["feed_start_date"]).map(ServiceDate.init)
        end = row.int(info.header["feed_end_date"]).map(ServiceDate.init)
      }
    }
    self.feedVersion = version
    self.feedStart = start
    self.feedEnd = end

    // routes
    var routes: [String: Route] = [:]
    let routeFile = CSVFile(data: try file("routes.txt"))
    let rh = routeFile.header
    routeFile.forEachRow { row in
      let id = row.string(rh["route_id"])
      let short = row.string(rh["route_short_name"])
      let color = row.string(rh["route_color"])
      let textColor = row.string(rh["route_text_color"])
      routes[id] = Route(
        id: id,
        shortName: short.isEmpty ? id : short,
        longName: row.string(rh["route_long_name"]),
        colorHex: color.isEmpty ? "5A6B7B" : color,
        textColorHex: textColor.isEmpty ? "FFFFFF" : textColor,
        sortOrder: row.int(rh["route_sort_order"]) ?? Int.max
      )
    }
    self.routes = routes

    // stops
    var stops: [String: Stop] = [:]
    let stopFile = CSVFile(data: try file("stops.txt"))
    let sh = stopFile.header
    stopFile.forEachRow { row in
      guard let lat = row.double(sh["stop_lat"]), let lon = row.double(sh["stop_lon"]) else { return }
      let id = row.string(sh["stop_id"])
      stops[id] = Stop(
        id: id,
        code: row.string(sh["stop_code"]),
        name: row.string(sh["stop_name"]),
        latitude: lat,
        longitude: lon,
        facing: row.int(sh["cardinal_direction"])
      )
    }
    self.stops = stops

    // trips
    var trips: [String: Trip] = [:]
    let tripFile = CSVFile(data: try file("trips.txt"))
    let th = tripFile.header
    tripFile.forEachRow { row in
      let id = row.string(th["trip_id"])
      trips[id] = Trip(
        id: id,
        routeID: row.string(th["route_id"]),
        serviceID: row.string(th["service_id"]),
        headsign: row.string(th["trip_headsign"]),
        directionID: row.int(th["direction_id"]) ?? 0,
        shapeID: row.string(th["shape_id"]),
        blockID: row.string(th["block_id"])
      )
    }
    self.trips = trips

    // stop_times
    var stopTimes: [String: [StopTime]] = [:]
    let timeFile = CSVFile(data: try file("stop_times.txt"))
    let ih = timeFile.header
    let tripCol = ih["trip_id"], stopCol = ih["stop_id"], seqCol = ih["stop_sequence"]
    let arrCol = ih["arrival_time"], depCol = ih["departure_time"]
    timeFile.forEachRow { row in
      let departure = parseGTFSTime(row.string(depCol))
      let arrival = parseGTFSTime(row.string(arrCol))
      // GTFS allows one of the two to be blank on interpolated stops; use whichever exists.
      guard let seconds = arrival ?? departure else { return }
      stopTimes[row.string(tripCol), default: []].append(
        StopTime(
          stopID: row.string(stopCol),
          sequence: row.int(seqCol) ?? 0,
          arrival: seconds,
          departure: departure ?? seconds
        )
      )
    }
    for key in stopTimes.keys { stopTimes[key]!.sort { $0.sequence < $1.sequence } }
    self.stopTimes = stopTimes

    // shapes
    var rawShapes: [String: [(Int, Coordinate)]] = [:]
    if let data = optionalFile("shapes.txt") {
      let shapeFile = CSVFile(data: data)
      let hh = shapeFile.header
      shapeFile.forEachRow { row in
        guard let lat = row.double(hh["shape_pt_lat"]), let lon = row.double(hh["shape_pt_lon"]) else { return }
        rawShapes[row.string(hh["shape_id"]), default: []].append(
          (row.int(hh["shape_pt_sequence"]) ?? 0, Coordinate(latitude: lat, longitude: lon))
        )
      }
    }
    self.shapes = rawShapes.mapValues { points in points.sorted { $0.0 < $1.0 }.map(\.1) }

    // calendar
    var calendars: [String: ServiceCalendar] = [:]
    if let data = optionalFile("calendar.txt") {
      let calendarFile = CSVFile(data: data)
      let ch = calendarFile.header
      let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
      calendarFile.forEachRow { row in
        calendars[row.string(ch["service_id"])] = ServiceCalendar(
          weekdays: days.map { row.int(ch[$0]) == 1 },
          startDate: row.int(ch["start_date"]) ?? 0,
          endDate: row.int(ch["end_date"]) ?? 99_999_999
        )
      }
    }
    self.calendars = calendars

    var exceptions: [String: [ServiceDate: Int]] = [:]
    if let data = optionalFile("calendar_dates.txt") {
      let datesFile = CSVFile(data: data)
      let dh = datesFile.header
      datesFile.forEachRow { row in
        guard let date = row.int(dh["date"]), let type = row.int(dh["exception_type"]) else { return }
        exceptions[row.string(dh["service_id"]), default: [:]][ServiceDate(date)] = type
      }
    }
    self.calendarExceptions = exceptions
  }

  // MARK: Queries

  /// Service IDs that run on `date`, following `calendar.txt` and then `calendar_dates.txt`.
  public func activeServiceIDs(on date: ServiceDate) -> Set<String> {
    var active: Set<String> = []
    let weekday = date.weekdayIndex(in: timeZone)
    for (id, calendar) in calendars
    where calendar.weekdays[weekday] && date.value >= calendar.startDate && date.value <= calendar.endDate {
      active.insert(id)
    }
    for (id, byDate) in calendarExceptions {
      switch byDate[date] {
      case 1: active.insert(id)
      case 2: active.remove(id)
      default: break
      }
    }
    return active
  }

  /// Trips whose scheduled span covers `moment`, with the service date each one belongs to.
  ///
  /// A trip that leaves at 23:50 and ends at 00:20 belongs to the previous service date after midnight, so both the
  /// current and the previous service date are checked.
  ///
  /// `inset` shrinks the span at both ends (in seconds), which keeps trips that are about to start or have just
  /// ended out of the result.
  public func scheduledTrips(at moment: Date, inset: Int = 0) -> [(trip: Trip, serviceDate: ServiceDate)] {
    let today = ServiceDate(moment, in: timeZone)
    var result: [(Trip, ServiceDate)] = []
    for date in [today, today.adding(days: -1, in: timeZone)] {
      let seconds = Int(moment.timeIntervalSince(date.midnight(in: timeZone)))
      let active = activeServiceIDs(on: date)
      for trip in trips.values where active.contains(trip.serviceID) {
        guard let times = stopTimes[trip.id], let first = times.first, let last = times.last else { continue }
        if seconds >= first.departure + inset && seconds <= last.arrival - inset { result.append((trip, date)) }
      }
    }
    return result
  }

  /// The scheduled arrival instant of `trip` at `sequence`, given the service date the trip runs on.
  public func scheduledArrival(tripID: String, sequence: Int, on date: ServiceDate) -> Date? {
    guard let stop = stopTimes[tripID]?.first(where: { $0.sequence == sequence }) else { return nil }
    return date.midnight(in: timeZone).addingTimeInterval(TimeInterval(stop.arrival))
  }
}
