import CoreLocation
import Foundation
import HeadwayCore
import Observation

/// Where a trip starts or ends, as chosen by the rider.
enum PlaceChoice: Equatable {
  case myLocation
  case point(PlanPoint)

  var title: String {
    switch self {
    case .myLocation: String(localized: "My location")
    case .point(let point): point.name
    }
  }
}

/// The trip planner's inputs and results.
@MainActor @Observable
final class PlanModel {
  enum Departure: Equatable {
    case now
    case at(Date)
  }

  enum Phase: Equatable {
    case idle
    case searching
    case done
    case failed(String)
  }

  var from: PlaceChoice? = .myLocation
  var to: PlaceChoice?
  var departure: Departure = .now
  private(set) var results: [Journey] = []
  private(set) var phase: Phase = .idle
  /// When the results were computed, so that the screen can say how fresh they are.
  private(set) var searchedAt: Date?

  var canSearch: Bool { from != nil && to != nil }

  func swap() { (from, to) = (to, from) }

  func clearResults() {
    results = []
    phase = .idle
  }

  /// Plans in the background so that scrolling stays smooth; the search itself takes only milliseconds on a warm
  /// timetable, but loading connections for a window of hours is more work than it looks.
  func search(schedule: Schedule?, predictions: [TripPrediction], vehicles: [VehicleSample], here: CLLocation?) async {
    guard let schedule else {
      phase = .failed(String(localized: "The timetable is not loaded yet."))
      return
    }
    guard let from, let to else { return }
    guard let origin = resolve(from, here: here), let destination = resolve(to, here: here) else {
      phase = .failed(String(localized: "Your location is not available. Choose a starting stop or turn on location."))
      return
    }
    phase = .searching
    let start: Date
    switch departure {
    case .now: start = Date()
    case .at(let date): start = date
    }
    let journeys = await Task.detached(priority: .userInitiated) {
      TripPlanner(schedule: schedule).plan(
        from: origin, to: destination, departAt: start, predictions: predictions, vehicles: vehicles)
    }.value
    results = journeys
    searchedAt = Date()
    phase = .done
  }

  private func resolve(_ choice: PlaceChoice, here: CLLocation?) -> PlanPoint? {
    switch choice {
    case .point(let point): return point
    case .myLocation:
      guard let here else { return nil }
      return PlanPoint(
        name: String(localized: "My location"),
        coordinate: Coordinate(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude))
    }
  }
}
