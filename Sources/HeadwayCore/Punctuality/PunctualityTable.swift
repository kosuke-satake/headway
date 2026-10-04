import Foundation

public enum DayType: Int, Sendable, Codable, CaseIterable {
  case weekday = 0
  case saturday = 1
  case sunday = 2

  public init(_ date: ServiceDate, in timeZone: TimeZone) {
    switch date.weekdayIndex(in: timeZone) {
    case 5: self = .saturday
    case 6: self = .sunday
    default: self = .weekday
    }
  }
}

/// Counts and spread of the delays seen in one group of observations.
public struct PunctualityCell: Sendable, Codable, Hashable {
  /// Observations in the group.
  public var n: Int
  /// Arrivals more than a minute early.
  public var early: Int
  /// Arrivals more than five minutes late.
  public var late: Int
  /// 10th, 50th and 90th percentile of the delay, in seconds (negative is early).
  public var p10: Int
  public var p50: Int
  public var p90: Int

  public init(n: Int, early: Int, late: Int, p10: Int, p50: Int, p90: Int) {
    self.n = n
    self.early = early
    self.late = late
    self.p10 = p10
    self.p50 = p50
    self.p90 = p90
  }

  public var onTime: Int { n - early - late }
  public var earlyShare: Double { n == 0 ? 0 : Double(early) / Double(n) }
  public var lateShare: Double { n == 0 ? 0 : Double(late) / Double(n) }
  public var onTimeShare: Double { n == 0 ? 0 : Double(onTime) / Double(n) }

  /// A cell from raw delays in seconds.
  public init?(delays: [Double]) {
    guard !delays.isEmpty else { return nil }
    let sorted = delays.sorted()
    func percentile(_ p: Double) -> Int { Int(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))].rounded()) }
    self.init(
      n: sorted.count, early: sorted.filter { $0 < Self.earlyThreshold }.count,
      late: sorted.filter { $0 > Self.lateThreshold }.count, p10: percentile(0.1), p50: percentile(0.5), p90: percentile(0.9))
  }

  /// More than a minute before the timetable: a rider who arrives on time misses the bus.
  public static let earlyThreshold = -60.0
  /// More than five minutes after the timetable.
  public static let lateThreshold = 300.0
}

/// How far off live predictions have been, for predictions made a given time ahead.
public struct PredictionBin: Sendable, Codable, Hashable {
  /// Predictions made less than this many seconds before the arrival (and at least the previous bin's limit).
  public var horizon: Int
  public var n: Int
  /// Quantiles of (predicted - observed) in seconds: 5th, 50th and 95th percentile. Positive means the prediction was
  /// later than what happened, so the bus came earlier than predicted.
  public var q05: Int
  public var q50: Int
  public var q95: Int

  public init(horizon: Int, n: Int, q05: Int, q50: Int, q95: Int) {
    self.horizon = horizon
    self.n = n
    self.q05 = q05
    self.q50 = q50
    self.q95 = q95
  }
}

/// How punctual each route and stop usually is, built from recorded bus positions.
///
/// Two levels: a route at an hour of day, and a route at one stop in a two-hour block. The stop level is more
/// specific but has fewer observations, so `cell` falls back to the route level.
public struct PunctualityTable: Sendable, Codable {
  public var generated: Date
  /// First and last day (`yyyy-MM-dd`) that contributed.
  public var firstDay: String
  public var lastDay: String
  /// Number of different days observed.
  public var days: Int
  /// Number of observations in total.
  public var observations: Int
  public var routeCells: [String: PunctualityCell]
  public var stopCells: [String: PunctualityCell]
  /// Accuracy of live predictions by how far ahead they were made, shortest horizon first.
  public var predictionBins: [PredictionBin]

  public init(
    generated: Date, firstDay: String, lastDay: String, days: Int, observations: Int,
    routeCells: [String: PunctualityCell], stopCells: [String: PunctualityCell], predictionBins: [PredictionBin] = []
  ) {
    self.predictionBins = predictionBins
    self.generated = generated
    self.firstDay = firstDay
    self.lastDay = lastDay
    self.days = days
    self.observations = observations
    self.routeCells = routeCells
    self.stopCells = stopCells
  }

  public static let empty = PunctualityTable(
    generated: .distantPast, firstDay: "", lastDay: "", days: 0, observations: 0, routeCells: [:], stopCells: [:])

  /// Fewest observations a cell needs before it is shown.
  public static let minimumRoute = 30
  public static let minimumStop = 12

  public static func routeKey(route: String, dayType: DayType, hour: Int) -> String { "\(route)|\(dayType.rawValue)|\(hour)" }
  public static func stopKey(route: String, stop: String, dayType: DayType, hour: Int) -> String {
    "\(route)|\(stop)|\(dayType.rawValue)|\(hour / 2)"
  }

  public enum Scope: Sendable { case stop, route }

  public struct Match: Sendable {
    public let cell: PunctualityCell
    public let scope: Scope
    public let dayType: DayType
    public let hour: Int
  }

  /// The best statistics for a route (and optionally a stop) at `date`: the stop's own when it has enough
  /// observations, else the route's at that hour, else the route's at a neighbouring hour.
  public func match(route: String, stop: String?, at date: Date, in timeZone: TimeZone) -> Match? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let hour = calendar.component(.hour, from: date)
    let dayType = DayType(ServiceDate(date, in: timeZone), in: timeZone)
    if let stop, let cell = stopCells[Self.stopKey(route: route, stop: stop, dayType: dayType, hour: hour)],
      cell.n >= Self.minimumStop
    {
      return Match(cell: cell, scope: .stop, dayType: dayType, hour: hour)
    }
    for candidate in [hour, hour - 1, hour + 1] where candidate >= 0 {
      if let cell = routeCells[Self.routeKey(route: route, dayType: dayType, hour: candidate)], cell.n >= Self.minimumRoute {
        return Match(cell: cell, scope: .route, dayType: dayType, hour: candidate)
      }
    }
    return nil
  }

  /// The range around a predicted arrival that the bus has reached 90% of the time, as offsets in seconds from the
  /// prediction (the first is usually negative: the earliest the bus may come). `nil` without enough data.
  public func window(predictedIn seconds: TimeInterval) -> (earliest: TimeInterval, latest: TimeInterval)? {
    guard let bin = predictionBins.first(where: { seconds < Double($0.horizon) }) ?? predictionBins.last, bin.n >= 100 else {
      return nil
    }
    // actual - predicted = -(predicted - observed)
    return (earliest: -Double(bin.q95), latest: -Double(bin.q05))
  }

  private enum CodingKeys: String, CodingKey {
    case generated, firstDay, lastDay, days, observations, routeCells, stopCells, predictionBins
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    generated = try c.decode(Date.self, forKey: .generated)
    firstDay = try c.decode(String.self, forKey: .firstDay)
    lastDay = try c.decode(String.self, forKey: .lastDay)
    days = try c.decode(Int.self, forKey: .days)
    observations = try c.decode(Int.self, forKey: .observations)
    routeCells = try c.decode([String: PunctualityCell].self, forKey: .routeCells)
    stopCells = try c.decode([String: PunctualityCell].self, forKey: .stopCells)
    predictionBins = try c.decodeIfPresent([PredictionBin].self, forKey: .predictionBins) ?? []
  }

  public static func decode(_ data: Data) throws -> PunctualityTable {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PunctualityTable.self, from: data)
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}
