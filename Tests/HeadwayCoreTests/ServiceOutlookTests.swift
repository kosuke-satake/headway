import Foundation
import Testing

@testable import HeadwayCore

@Suite struct ServiceOutlookTests {
  let schedule: Schedule

  init() throws { schedule = try makePlannerFeed() }

  private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  @Test func aWeekdayRouteBeforeItsFirstTrip() {
    // 2026-10-05 is a Monday. Route R1 leaves A at 08:00 and 09:00.
    let outlook = schedule.outlook(route: "R1", direction: nil, at: at(5, 7, 0))
    #expect(outlook.today == .runs(first: at(5, 8, 0), last: at(5, 9, 0), trips: 2))
    #expect(outlook.nextStart == at(5, 8, 0))
    #expect(!outlook.onRoadNow)
    #expect(outlook.isInfrequent)
  }

  @Test func aTripOnTheRoad() {
    let outlook = schedule.outlook(route: "R1", direction: 0, at: at(5, 8, 5))
    #expect(outlook.onRoadNow)
    #expect(outlook.nextStart == at(5, 9, 0))
  }

  @Test func notRunningOnASaturdayPointsToTheNextWorkingDay() {
    // 2026-10-10 is a Saturday: nothing today, the next trip is Monday morning.
    let outlook = schedule.outlook(route: "R1", direction: nil, at: at(10, 12, 0))
    #expect(outlook.today == .none)
    #expect(outlook.nextStart == at(12, 8, 0))
    #expect(!outlook.onRoadNow)
    #expect(!outlook.isInfrequent)
  }

  @Test func theOtherDirectionAndUnknownRoutesHaveNothing() {
    #expect(schedule.outlook(route: "R1", direction: 1, at: at(5, 7, 0)).nextStart == nil)
    #expect(schedule.outlook(route: "NOPE", direction: nil, at: at(5, 7, 0)).today == .none)
  }

  @Test func afterTheLastTripTheNextOneIsTomorrow() {
    let outlook = schedule.outlook(route: "R1", direction: nil, at: at(5, 20, 0))
    #expect(outlook.nextStart == at(6, 8, 0))
  }
}
