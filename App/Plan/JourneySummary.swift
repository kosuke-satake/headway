import Foundation
import HeadwayCore

/// A journey as lines of plain text, for sharing and for reminders.
struct JourneySummary {
  let text: TimeText
  let routeName: (String) -> String

  func lines(for journey: Journey, from: String, to: String) -> [String] {
    var lines = [
      "\(from) → \(to)",
      "\(text.clock(journey.departure)) → \(text.clock(journey.arrival)) · \(TimeText.duration(journey.duration))",
    ]
    for (index, leg) in journey.legs.enumerated() {
      defer {
        for stay in journey.stopovers where stay.afterLeg == index {
          lines.append(
            "• " + String(localized: "Stay at \(stay.place.name)") + ": \(text.clock(stay.arrive))–\(text.clock(stay.leave)) · \(TimeText.duration(stay.duration))")
        }
      }
      switch leg {
      case .walk(let walk):
        lines.append("• " + String(localized: "Walk \(TimeText.duration(walk.end.timeIntervalSince(walk.start))) to \(walk.to.name)"))
      case .ride(let ride):
        lines.append(
          "• " + String(localized: "Route \(routeName(ride.routeID)) to \(ride.headsign.prettyHeadsign)") + ": "
            + String(localized: "Board at \(ride.fromStop.name) · \(text.clock(ride.depart))") + ", "
            + String(localized: "Get off at \(ride.toStop.name) · \(text.clock(ride.arrive))"))
      }
    }
    return lines
  }

  /// What the reminder says: when to leave and what to take.
  func reminder(for journey: Journey) -> String {
    guard let first = journey.rides.first else { return String(localized: "Time to start walking.") }
    let route = String(localized: "Route \(routeName(first.routeID)) to \(first.headsign.prettyHeadsign)")
    if case .walk(let walk) = journey.legs.first {
      return String(
        localized: "Leave now: walk \(TimeText.duration(walk.end.timeIntervalSince(walk.start))) to \(first.fromStop.name). \(route) at \(text.clock(first.depart)).")
    }
    return String(localized: "\(route) leaves \(first.fromStop.name) at \(text.clock(first.depart)).")
  }
}
