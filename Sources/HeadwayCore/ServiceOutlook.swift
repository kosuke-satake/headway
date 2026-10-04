import Foundation

/// When a route runs in one direction: used to tell "no buses right now" from "not running today".
public struct ServiceOutlook: Sendable, Equatable {
  public enum Today: Sendable, Equatable {
    /// Runs today; `first` and `last` are the scheduled start of the first and last trip.
    case runs(first: Date, last: Date, trips: Int)
    /// No trips today.
    case none
  }

  public let today: Today
  /// The scheduled start of the next trip that has not left yet (today, or on one of the next days), if any.
  public let nextStart: Date?
  /// True when a trip is scheduled to be on the road at the moment asked about.
  public let onRoadNow: Bool

  /// A route running only a few times a day, so that a long gap between buses is expected.
  public var isInfrequent: Bool {
    if case .runs(_, _, let trips) = today { return trips <= 6 }
    return false
  }
}

extension Schedule {
  /// Scheduled service of `route` in `direction` (nil for both) around `moment`.
  ///
  /// Looks at yesterday (for trips running past midnight), today and the next `daysAhead` days.
  public func outlook(route: String, direction: Int?, at moment: Date, daysAhead: Int = 7) -> ServiceOutlook {
    let todayDate = ServiceDate(moment, in: timeZone)
    var todayStarts: [Date] = []
    var next: Date?
    var onRoad = false

    // Found once: looking at every trip of the feed for every day would be slow.
    let candidates = trips.values.filter { $0.routeID == route && (direction == nil || $0.directionID == direction) }

    func consider(_ date: ServiceDate, isToday: Bool) {
      let active = activeServiceIDs(on: date)
      let midnight = date.midnight(in: timeZone)
      for trip in candidates {
        guard active.contains(trip.serviceID), let times = stopTimes[trip.id], let first = times.first, let last = times.last
        else { continue }
        let start = midnight.addingTimeInterval(TimeInterval(first.departure))
        let end = midnight.addingTimeInterval(TimeInterval(last.arrival))
        if start <= moment && moment <= end { onRoad = true }
        if isToday { todayStarts.append(start) }
        if start > moment, next == nil || start < next! { next = start }
      }
    }

    consider(todayDate.adding(days: -1, in: timeZone), isToday: false)
    consider(todayDate, isToday: true)
    for offset in 1...max(1, daysAhead) where next == nil { consider(todayDate.adding(days: offset, in: timeZone), isToday: false) }

    let sorted = todayStarts.sorted()
    let today: ServiceOutlook.Today = sorted.isEmpty ? .none : .runs(first: sorted[0], last: sorted[sorted.count - 1], trips: sorted.count)
    return ServiceOutlook(today: today, nextStart: next, onRoadNow: onRoad)
  }
}
