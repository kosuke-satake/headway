import Foundation
import HeadwayCore
import Testing

@testable import Headway

@MainActor @Suite struct MultiStopTests {
  private func makeSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "headway-tests-\(UUID().uuidString)")!)
  }

  private func place(_ name: String, _ lat: Double) -> PlaceChoice {
    .point(PlanPoint(name: name, coordinate: Coordinate(latitude: lat, longitude: -89.40)))
  }

  @Test func aTripWithStopsCannotBeSearchedUntilEveryStopHasAPlace() {
    let plan = PlanModel()
    plan.from = place("A", 43.00)
    plan.to = place("C", 43.02)
    #expect(plan.canSearch)
    plan.addVia()
    #expect(!plan.canSearch)
    plan.vias[0].place = place("B", 43.01)
    #expect(plan.canSearch)
  }

  @Test func atMostThreeStopsCanBeAdded() {
    let plan = PlanModel()
    for _ in 0..<5 { plan.addVia() }
    #expect(plan.vias.count == PlanModel.maxVias)
  }

  @Test func swappingTheEndsReversesTheStops() {
    let plan = PlanModel()
    plan.from = place("A", 43.00)
    plan.to = place("D", 43.03)
    plan.addVia()
    plan.addVia()
    plan.vias[0].place = place("B", 43.01)
    plan.vias[1].place = place("C", 43.02)
    plan.swap()
    #expect(plan.from?.title == "D")
    #expect(plan.to?.title == "A")
    #expect(plan.vias.map { $0.place?.title } == ["C", "B"])
  }

  @Test func savedTripsKeepTheirStopsAndOldSavesStillLoad() throws {
    let settings = makeSettings()
    let from = place("A", 43.00), to = place("C", 43.02)
    let via = [StoredVia(end: StoredEnd(place("B", 43.01)), dwellMinutes: 15)]
    settings.toggleSaved(from: from, to: to, vias: via)
    #expect(settings.isSaved(from: from, to: to, vias: via))
    // The same ends without the stop are a different trip.
    #expect(!settings.isSaved(from: from, to: to))
    #expect(settings.values.savedTrips[0].title == "A → B → C")

    // A trip saved before stops existed has no "vias" key.
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedTrip(from: StoredEnd(from), to: StoredEnd(to)))) as? [String: Any])
    json.removeValue(forKey: "vias")
    let old = try JSONDecoder().decode(SavedTrip.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.stops.isEmpty)
    #expect(old.matches(from: StoredEnd(from), to: StoredEnd(to)))
  }

  @Test func recentTripsWithDifferentStopsAreDifferentEntries() {
    let settings = makeSettings()
    let from = place("A", 43.00), to = place("C", 43.02)
    settings.noteRecent(from: from, to: to)
    settings.noteRecent(from: from, to: to, vias: [StoredVia(end: StoredEnd(place("B", 43.01)), dwellMinutes: 10)])
    settings.noteRecent(from: from, to: to)
    #expect(settings.values.recentTrips.count == 2)
    #expect(settings.values.recentTrips[0].stops.isEmpty)
  }

  @Test func theStayLabelReadsNaturally() {
    #expect(TimeText.minutesLabel(10) == String(localized: "10 min"))
    #expect(TimeText.minutesLabel(60) == String(localized: "1 h"))
    #expect(TimeText.minutesLabel(90) == String(localized: "1 h 30 min"))
  }
}
