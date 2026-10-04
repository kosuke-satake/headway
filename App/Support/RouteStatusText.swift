import Foundation
import HeadwayCore

/// What to tell the rider about a route that shows no buses: not an error, but one of a few ordinary reasons.
struct RouteLiveStatus: Equatable {
  enum Kind: Equatable {
    /// Buses are on the road (`count` of them).
    case buses(Int)
    /// A trip is scheduled right now but no bus reports a position for it.
    case notReporting
    /// Runs today, but not at this moment (before the first trip, between trips, or after the last).
    case between
    /// No trips today.
    case notToday
    /// Not known yet (the timetable is still loading) or nothing is scheduled in the coming week.
    case unknown
  }

  let kind: Kind
  let text: String
  /// True when the line is good news (buses are running).
  var isRunning: Bool { if case .buses = kind { true } else { false } }
}

extension AppModel {
  /// The live status of a route in one direction (nil for both), in words.
  func liveStatus(route: String, direction: Int?, now: Date = Date()) -> RouteLiveStatus {
    let count = busCount(route: route, direction: direction)
    if count > 0 { return RouteLiveStatus(kind: .buses(count), text: String(localized: "\(count) buses now")) }
    guard let outlook = outlook(route: route, direction: direction) else {
      return RouteLiveStatus(kind: .unknown, text: String(localized: "No buses right now"))
    }
    let next = outlook.nextStart.map { nextText($0, now: now) }
    switch outlook.today {
    case .none:
      let base = String(localized: "Not running today")
      return RouteLiveStatus(kind: .notToday, text: next.map { "\(base) · \(String(localized: "next \($0)"))" } ?? base)
    case .runs(_, _, let trips):
      if outlook.onRoadNow { return RouteLiveStatus(kind: .notReporting, text: String(localized: "A trip is scheduled but no bus is reporting")) }
      var parts: [String] = [String(localized: "No buses right now")]
      if outlook.isInfrequent { parts.append(String(localized: "only \(trips) trips today")) }
      if let next { parts.append(String(localized: "next \(next)")) }
      return RouteLiveStatus(kind: .between, text: parts.joined(separator: " · "))
    }
  }

  /// "14:20" for later today, "Mon 6:10" for another day.
  private func nextText(_ date: Date, now: Date) -> String {
    let text = timeText()
    let zone = schedule?.timeZone ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    if calendar.isDate(date, inSameDayAs: now) { return text.clock(date) }
    let formatter = DateFormatter()
    formatter.timeZone = zone
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("E")
    return "\(formatter.string(from: date)) \(text.clock(date))"
  }
}
