import Foundation

public struct Route: Sendable, Identifiable, Hashable {
  public let id: String
  public let shortName: String
  public let longName: String
  /// Six hex digits without `#`; falls back to a neutral colour when the feed has none.
  public let colorHex: String
  public let textColorHex: String
  public let sortOrder: Int

  public init(id: String, shortName: String, longName: String, colorHex: String, textColorHex: String, sortOrder: Int) {
    self.id = id
    self.shortName = shortName
    self.longName = longName
    self.colorHex = colorHex
    self.textColorHex = textColorHex
    self.sortOrder = sortOrder
  }
}

public struct Stop: Sendable, Identifiable, Hashable {
  public let id: String
  public let code: String
  public let name: String
  public let latitude: Double
  public let longitude: Double
  /// Bearing in degrees the stop faces (GTFS extension `cardinal_direction`), when provided.
  public let facing: Int?
  /// GTFS `wheelchair_boarding`: 0 unknown, 1 accessible, 2 not accessible.
  public let wheelchairBoarding: Int
}

public struct Trip: Sendable, Identifiable, Hashable {
  public let id: String
  public let routeID: String
  public let serviceID: String
  public let headsign: String
  public let directionID: Int
  public let shapeID: String
  public let blockID: String
  /// GTFS `wheelchair_accessible`: 0 unknown, 1 accessible, 2 not accessible.
  public let wheelchairAccessible: Int
}

public struct StopTime: Sendable, Hashable {
  public let stopID: String
  public let sequence: Int
  /// Seconds after midnight of the service day; can exceed 86,400 for trips that run past midnight.
  public let arrival: Int
  public let departure: Int
}

/// One scheduled visit to a stop, as stored in the per-stop index.
public struct StopVisit: Sendable, Hashable {
  public let tripID: String
  public let sequence: Int
  public let arrival: Int
  public let departure: Int
}

/// A scheduled departure from a particular stop on a particular service date.
public struct ScheduledDeparture: Sendable, Hashable {
  public let tripID: String
  public let routeID: String
  public let headsign: String
  public let directionID: Int
  public let serviceDate: ServiceDate
  public let sequence: Int
  public let time: Date
}

public struct Coordinate: Sendable, Hashable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// Weekly pattern of one `service_id` plus its date range.
public struct ServiceCalendar: Sendable {
  /// Monday = index 0 ... Sunday = index 6.
  public let weekdays: [Bool]
  public let startDate: Int
  public let endDate: Int
}

/// A date written as `yyyymmdd`, the way GTFS writes it.
public struct ServiceDate: Sendable, Hashable, Comparable {
  public let value: Int
  public init(_ value: Int) { self.value = value }

  public static func < (lhs: ServiceDate, rhs: ServiceDate) -> Bool { lhs.value < rhs.value }

  public init(_ date: Date, in timeZone: TimeZone) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    self.value = parts.year! * 10_000 + parts.month! * 100 + parts.day!
  }

  /// Midnight at the start of this date in `timeZone`.
  public func midnight(in timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = DateComponents(year: value / 10_000, month: value / 100 % 100, day: value % 100)
    return calendar.date(from: parts)!
  }

  public func adding(days: Int, in timeZone: TimeZone) -> ServiceDate {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return ServiceDate(calendar.date(byAdding: .day, value: days, to: midnight(in: timeZone))!, in: timeZone)
  }

  /// Monday = 0 ... Sunday = 6.
  public func weekdayIndex(in timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let weekday = calendar.component(.weekday, from: midnight(in: timeZone))  // Sunday = 1
    return (weekday + 5) % 7
  }
}

/// Parses `H:MM:SS` or `HH:MM:SS` (hours may be 24 or more) into seconds.
func parseGTFSTime(_ text: String) -> Int? {
  var seconds = 0
  var parts = 0
  var current = 0
  var sawDigit = false
  for byte in text.utf8 {
    if byte == UInt8(ascii: ":") {
      guard sawDigit else { return nil }
      seconds = seconds * 60 + current
      current = 0
      sawDigit = false
      parts += 1
    } else if byte >= 48 && byte <= 57 {
      current = current * 10 + Int(byte - 48)
      sawDigit = true
    } else if byte != UInt8(ascii: " ") {
      return nil
    }
  }
  guard sawDigit, parts == 2 else { return nil }
  return seconds * 60 + current
}
