import Foundation
import HeadwayCore
import Testing

@testable import Headway

@MainActor @Suite struct PlannerSettingsTests {
  private func makeSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "headway-tests-\(UUID().uuidString)")!)
  }

  private func point(_ name: String, _ lat: Double = 43.07, _ lon: Double = -89.40, stop: String? = nil) -> PlanPoint {
    PlanPoint(name: name, coordinate: Coordinate(latitude: lat, longitude: lon), stopID: stop)
  }

  @Test func homeAndWorkExistOnce() {
    let settings = makeSettings()
    settings.save(place: point("First"), as: .home)
    settings.save(place: point("Second", 43.08), as: .home)
    settings.save(place: point("Office", 43.09), as: .work)
    #expect(settings.values.savedPlaces.filter { $0.kind == .home }.count == 1)
    #expect(settings.place(of: .home)?.point.coordinate.latitude == 43.08)
    #expect(settings.place(of: .work)?.name == String(localized: "Work"))
  }

  @Test func savingTheSamePlaceTwiceKeepsOneCopy() {
    let settings = makeSettings()
    settings.save(place: point("Cafe", 43.0712, -89.4012), as: .other)
    settings.save(place: point("Cafe", 43.0712, -89.4012), as: .other)
    #expect(settings.values.savedPlaces.count == 1)
  }

  @Test func savedTripsToggleAndMatchWhateverTheirIDs() {
    let settings = makeSettings()
    let from = PlaceChoice.myLocation
    let to = PlaceChoice.point(point("Campus", stop: "42"))
    #expect(!settings.isSaved(from: from, to: to))
    settings.toggleSaved(from: from, to: to)
    #expect(settings.isSaved(from: from, to: to))
    // The same stop reached through another copy of the place still counts.
    #expect(settings.isSaved(from: from, to: .point(point("Campus (renamed)", stop: "42"))))
    settings.toggleSaved(from: from, to: to)
    #expect(settings.values.savedTrips.isEmpty)
  }

  @Test func recentTripsAreUniqueAndCapped() {
    let settings = makeSettings()
    for index in 0..<40 {
      settings.noteRecent(from: .myLocation, to: .point(point("Place \(index)", 43.0 + Double(index) * 0.01, stop: "s\(index)")))
    }
    settings.noteRecent(from: .myLocation, to: .point(point("Place 33", 43.33, stop: "s33")))
    #expect(settings.values.recentTrips.count == 30)
    #expect(settings.values.recentTrips.first?.to.place?.stopID == "s33")
    #expect(Set(settings.values.recentTrips.compactMap { $0.to.place?.stopID }).count == 30)
  }

  @Test func differentPlacesDoNotMatch() {
    let a = StoredEnd(.point(point("A", 43.07, -89.40)))
    let b = StoredEnd(.point(point("B", 43.08, -89.40)))
    #expect(!a.matches(b))
    #expect(a.matches(StoredEnd(.point(point("A again", 43.07001, -89.40001)))))
    #expect(!StoredEnd(.myLocation).matches(a))
    #expect(StoredEnd(.myLocation).matches(StoredEnd(.myLocation)))
  }

  @Test func plannerPreferencesSurviveARestart() {
    let suite = "headway-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let first = AppSettings(defaults: defaults)
    first.values.walkSpeed = .slow
    first.values.maxTransfers = 1
    first.values.accessibleOnly = true
    first.save(place: point("Home place"), as: .home)
    first.toggleSaved(from: .myLocation, to: .point(point("Campus", stop: "1")))
    let second = AppSettings(defaults: defaults)
    #expect(second.values.walkSpeed == .slow)
    #expect(second.values.maxTransfers == 1)
    #expect(second.values.accessibleOnly)
    #expect(second.place(of: .home)?.name == String(localized: "Home"))
    #expect(second.values.savedTrips.count == 1)
  }

  @Test func resetKeepsSavedPlacesAndTrips() {
    let settings = makeSettings()
    settings.save(place: point("Home place"), as: .home)
    settings.toggleSaved(from: .myLocation, to: .point(point("Campus", stop: "1")))
    settings.values.walkSpeed = .fast
    settings.reset()
    #expect(settings.values.walkSpeed == .normal)
    #expect(settings.values.savedPlaces.count == 1)
    #expect(settings.values.savedTrips.count == 1)
  }
}

@Suite struct JourneyOrderingTests {
  private func journey(depart: Int, arrive: Int, rides: Int, walkMeters: Double) -> Journey {
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    let a = PlanPoint(name: "A", coordinate: Coordinate(latitude: 43, longitude: -89), stopID: "a")
    let b = PlanPoint(name: "B", coordinate: Coordinate(latitude: 43.01, longitude: -89), stopID: "b")
    var legs: [JourneyLeg] = []
    if walkMeters > 0 {
      legs.append(.walk(WalkLeg(from: a, to: b, start: base.addingTimeInterval(Double(depart) * 60), end: base.addingTimeInterval(Double(depart) * 60 + 60), meters: walkMeters)))
    }
    for index in 0..<rides {
      let start = depart + 1 + index * 10
      legs.append(.ride(RideLeg(
        tripID: "t\(depart)-\(index)", routeID: "R", headsign: "X", fromStop: a, toStop: b,
        depart: base.addingTimeInterval(Double(start) * 60), arrive: base.addingTimeInterval(Double(index == rides - 1 ? arrive : start + 8) * 60),
        stopCount: 3, delay: nil, isLive: false)))
    }
    return Journey(legs: legs)
  }

  @Test func sortsByTheChosenKey() {
    let fastDirectWalky = journey(depart: 0, arrive: 20, rides: 1, walkMeters: 900)
    let slowTransferShortWalk = journey(depart: 5, arrive: 40, rides: 2, walkMeters: 100)
    let list = [slowTransferShortWalk, fastDirectWalky]
    #expect(PlanModel.sorted(list, by: .departure).first == fastDirectWalky)
    #expect(PlanModel.sorted(list, by: .arrival).first == fastDirectWalky)
    #expect(PlanModel.sorted(list, by: .fewestTransfers).first == fastDirectWalky)
    #expect(PlanModel.sorted(list, by: .leastWalking).first == slowTransferShortWalk)
  }

  @Test func highlightsOnlyWhenTheyTellJourneysApart() {
    let a = journey(depart: 0, arrive: 20, rides: 1, walkMeters: 900)
    let b = journey(depart: 5, arrive: 40, rides: 2, walkMeters: 100)
    let marks = PlanModel.highlights([a, b])
    #expect(marks[a.id]?.contains(.fastest) == true)
    #expect(marks[a.id]?.contains(.fewestTransfers) == true)
    #expect(marks[b.id]?.contains(.leastWalking) == true)
    // One journey alone gets no badge.
    #expect(PlanModel.highlights([a]).isEmpty)
    // Two identical-looking journeys: nothing stands out.
    let twin = journey(depart: 10, arrive: 30, rides: 1, walkMeters: 900)
    #expect(PlanModel.highlights([a, twin]).values.allSatisfy { !$0.contains(.fewestTransfers) && !$0.contains(.leastWalking) })
  }
}
