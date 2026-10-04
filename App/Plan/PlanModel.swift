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

/// What the planner needs from the rest of the app for one search.
struct PlanContext {
  let schedule: Schedule?
  let predictions: [TripPrediction]
  let vehicles: [VehicleSample]
  let here: CLLocation?
  let options: PlanOptions
}

/// The trip planner's inputs and results.
@MainActor @Observable
final class PlanModel {
  enum Departure: Equatable {
    case now
    case at(Date)
    case arriveBy(Date)
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
  /// True after a search for earlier (later) journeys found nothing new, so the button can go away.
  private(set) var noEarlier = false
  private(set) var noLater = false
  private(set) var isLoadingMore = false

  var canSearch: Bool { from != nil && to != nil }

  func swap() { (from, to) = (to, from) }

  func clearResults() {
    results = []
    phase = .idle
    noEarlier = false
    noLater = false
  }

  // MARK: Searching

  /// Plans in the background so that scrolling stays smooth.
  func search(_ context: PlanContext) async {
    guard let schedule = context.schedule else {
      phase = .failed(String(localized: "The timetable is not loaded yet."))
      return
    }
    guard let (origin, destination) = resolveEnds(context.here) else {
      phase = .failed(String(localized: "Your location is not available. Choose a starting stop or turn on location."))
      return
    }
    phase = .searching
    noEarlier = false
    noLater = false
    let mode = departure
    let journeys = await Task.detached(priority: .userInitiated) { () -> [Journey] in
      let planner = TripPlanner(schedule: schedule)
      switch mode {
      case .now:
        return planner.plan(
          from: origin, to: destination, departAt: Date(), options: context.options, predictions: context.predictions,
          vehicles: context.vehicles)
      case .at(let date):
        return planner.plan(
          from: origin, to: destination, departAt: date, options: context.options, predictions: context.predictions,
          vehicles: context.vehicles)
      case .arriveBy(let deadline):
        return planner.plan(
          from: origin, to: destination, arriveBy: deadline, options: context.options, predictions: context.predictions,
          vehicles: context.vehicles)
      }
    }.value
    results = journeys
    searchedAt = Date()
    phase = .done
  }

  /// Adds journeys that leave after the last one shown.
  func loadLater(_ context: PlanContext) async {
    guard let schedule = context.schedule, let (origin, destination) = resolveEnds(context.here),
      let latest = results.map(\.departure).max()
    else { return }
    isLoadingMore = true
    let more = await Task.detached(priority: .userInitiated) {
      TripPlanner(schedule: schedule).plan(
        from: origin, to: destination, departAt: latest.addingTimeInterval(90), options: context.options,
        predictions: context.predictions, vehicles: context.vehicles)
    }.value
    merge(more, grewBy: &noLater)
    isLoadingMore = false
  }

  /// Adds journeys that arrive before the first one shown.
  func loadEarlier(_ context: PlanContext) async {
    guard let schedule = context.schedule, let (origin, destination) = resolveEnds(context.here),
      let earliest = results.map(\.arrival).min()
    else { return }
    isLoadingMore = true
    let more = await Task.detached(priority: .userInitiated) {
      TripPlanner(schedule: schedule).plan(
        from: origin, to: destination, arriveBy: earliest.addingTimeInterval(-60), options: context.options,
        predictions: context.predictions, vehicles: context.vehicles)
    }.value
    merge(more, grewBy: &noEarlier)
    isLoadingMore = false
  }

  private func merge(_ more: [Journey], grewBy exhausted: inout Bool) {
    let known = Set(results.map(\.id))
    let fresh = more.filter { !known.contains($0.id) && !$0.rides.isEmpty }
    if fresh.isEmpty {
      exhausted = true
    } else {
      results += fresh
    }
  }

  private func resolveEnds(_ here: CLLocation?) -> (PlanPoint, PlanPoint)? {
    guard let from, let to, let origin = resolve(from, here: here), let destination = resolve(to, here: here) else { return nil }
    return (origin, destination)
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

  // MARK: Ordering and highlights

  nonisolated static func sorted(_ journeys: [Journey], by sort: JourneySort) -> [Journey] {
    switch sort {
    case .departure: journeys.sorted { ($0.departure, $0.arrival) < ($1.departure, $1.arrival) }
    case .arrival: journeys.sorted { ($0.arrival, $0.departure) < ($1.arrival, $1.departure) }
    case .fewestTransfers: journeys.sorted { ($0.transfers, $0.arrival) < ($1.transfers, $1.arrival) }
    case .leastWalking:
      journeys.sorted { (Int($0.walkingMeters / 50), $0.arrival) < (Int($1.walkingMeters / 50), $1.arrival) }
    }
  }

  enum Highlight: Sendable { case fastest, fewestTransfers, leastWalking }

  /// Which of the results stands out: the shortest trip, the one with fewest transfers, the one with least walking.
  /// A highlight is only given when it tells one journey from the others.
  nonisolated static func highlights(_ journeys: [Journey]) -> [String: [Highlight]] {
    guard journeys.count > 1 else { return [:] }
    var result: [String: [Highlight]] = [:]
    func mark(_ best: Journey?, _ highlight: Highlight, distinct: Bool) {
      if let best, distinct { result[best.id, default: []].append(highlight) }
    }
    let fastest = journeys.min { $0.duration < $1.duration }
    mark(fastest, .fastest, distinct: Set(journeys.map { Int($0.duration / 60) }).count > 1)
    let fewest = journeys.min { ($0.transfers, $0.duration) < ($1.transfers, $1.duration) }
    mark(fewest, .fewestTransfers, distinct: Set(journeys.map(\.transfers)).count > 1)
    let least = journeys.min { ($0.walkingMeters, $0.duration) < ($1.walkingMeters, $1.duration) }
    mark(least, .leastWalking, distinct: Set(journeys.map { Int($0.walkingMeters / 100) }).count > 1)
    return result
  }
}
