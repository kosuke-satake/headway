import Foundation

/// What a rider can ask to be told about a route they watch.
public enum WatchKind: String, Sendable, Codable, CaseIterable {
  /// A bus is more than five minutes behind its timetable.
  case late
  /// A bus is more than two minutes ahead of its timetable.
  case early
  /// The city published an alert (a detour, a closed stop, ...) for the route.
  case alert
}

/// Something worth a notification.
public struct WatchEvent: Sendable, Hashable, Identifiable {
  public let kind: WatchKind
  public let routeID: String
  /// Late and early: how many buses are affected.
  public let buses: Int
  /// Late: the worst delay; early: how far ahead the earliest bus is. Seconds, always positive.
  public let seconds: Int
  /// Alerts: the alert's id, title and (shortened) text.
  public let alertID: String
  public let headline: String
  public let detail: String

  public init(kind: WatchKind, routeID: String, buses: Int, seconds: Int, alertID: String, headline: String, detail: String) {
    self.kind = kind
    self.routeID = routeID
    self.buses = buses
    self.seconds = seconds
    self.alertID = alertID
    self.headline = headline
    self.detail = detail
  }

  /// Late and early are told once per route and cooldown; an alert once, however long it lasts.
  public var id: String { kind == .alert ? "alert|\(alertID)|\(routeID)" : "\(kind.rawValue)|\(routeID)" }
}

public enum WatchEvaluator {
  /// How far ahead an alert that has not started yet is announced.
  public static let alertLookAhead: TimeInterval = 24 * 3600

  /// Events for the watched `routes`, limited to the `kinds` the rider asked for.
  public static func evaluate(
    status: ServiceStatus?, alerts: [ServiceAlert], now: Date, routes: Set<String>, kinds: Set<WatchKind>
  ) -> [WatchEvent] {
    guard !routes.isEmpty, !kinds.isEmpty else { return [] }
    var events: [WatchEvent] = []

    if let status {
      for row in status.routes where routes.contains(row.routeID) {
        if kinds.contains(.late), row.lateBuses > 0 {
          let worst = row.busDelays.map(\.seconds).max() ?? ServiceStatusBuilder.lateThreshold
          events.append(
            WatchEvent(kind: .late, routeID: row.routeID, buses: row.lateBuses, seconds: Int(worst.rounded()), alertID: "", headline: "", detail: ""))
        }
        if kinds.contains(.early), row.earlyBuses > 0 {
          let ahead = -(row.busDelays.map(\.seconds).min() ?? ServiceStatusBuilder.earlyThreshold)
          events.append(
            WatchEvent(kind: .early, routeID: row.routeID, buses: row.earlyBuses, seconds: Int(ahead.rounded()), alertID: "", headline: "", detail: ""))
        }
      }
    }

    if kinds.contains(.alert) {
      for alert in alerts where isWorthTelling(alert, at: now) {
        for route in alert.routeIDs where routes.contains(route) {
          events.append(
            WatchEvent(kind: .alert, routeID: route, buses: 0, seconds: 0, alertID: alert.entityID, headline: alert.header, detail: alert.detail))
        }
      }
    }
    return events.sorted { ($0.routeID, $0.kind.rawValue, $0.alertID) < ($1.routeID, $1.kind.rawValue, $1.alertID) }
  }

  private static func isWorthTelling(_ alert: ServiceAlert, at now: Date) -> Bool {
    if alert.isActive(at: now) { return true }
    return alert.activePeriods.contains { period in
      guard let start = period.start else { return false }
      return start > now && start.timeIntervalSince(now) <= alertLookAhead
    }
  }
}

/// Remembers what the rider has already been told, so that a bus that stays late is not announced every minute.
public struct WatchLedger: Sendable, Codable, Equatable {
  /// When each event was last announced.
  public private(set) var told: [String: Date] = [:]

  public init() {}

  /// Minutes before a late or early route is announced again.
  public static let repeatAfter: TimeInterval = 45 * 60
  /// Entries older than this are forgotten (an alert is then announced again if it is still around).
  public static let forgetAfter: TimeInterval = 7 * 24 * 3600

  /// The events that have not been announced recently. They count as announced from now on.
  public mutating func fresh(_ events: [WatchEvent], now: Date) -> [WatchEvent] {
    told = told.filter { now.timeIntervalSince($0.value) < Self.forgetAfter }
    var result: [WatchEvent] = []
    for event in events {
      if let last = told[event.id] {
        // Alerts are announced once; late and early again after a while.
        if event.kind == .alert || now.timeIntervalSince(last) < Self.repeatAfter { continue }
      }
      told[event.id] = now
      result.append(event)
    }
    return result
  }
}
