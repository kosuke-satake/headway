import Foundation
import Testing

@testable import HeadwayCore

@Suite struct WatchTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func status(_ rows: [RouteStatus]) -> ServiceStatus {
    ServiceStatus(routes: rows, cancelledTrips: [], skippedStops: 0, silentTrips: [], busesOnRoad: rows.reduce(0) { $0 + $1.buses })
  }

  private func row(_ route: String, delays: [Double]) -> RouteStatus {
    let busDelays = delays.enumerated().map { BusDelay(vehicleID: "\(route)\($0.offset)", seconds: $0.element) }
    return RouteStatus(
      routeID: route, buses: delays.count, measured: delays.count,
      averageDelay: delays.isEmpty ? nil : delays.reduce(0, +) / Double(delays.count), worstDelay: delays.max(),
      lateBuses: delays.filter { $0 > ServiceStatusBuilder.lateThreshold }.count,
      earlyBuses: delays.filter { $0 < ServiceStatusBuilder.earlyThreshold }.count, busDelays: busDelays)
  }

  private func alert(_ id: String, routes: [String], start: TimeInterval?, end: TimeInterval?) -> ServiceAlert {
    ServiceAlert(
      entityID: id, header: "Detour \(id)", detail: "Details", url: nil, effect: "DETOUR",
      activePeriods: [AlertPeriod(start: start.map { now.addingTimeInterval($0) }, end: end.map { now.addingTimeInterval($0) })],
      routeIDs: routes, stopIDs: [])
  }

  @Test func lateAndEarlyBusesOnWatchedRoutesAreReported() {
    let rows = [row("A", delays: [400, 10, -200]), row("B", delays: [900])]
    let events = WatchEvaluator.evaluate(status: status(rows), alerts: [], now: now, routes: ["A"], kinds: [.late, .early])
    #expect(events.map(\.kind) == [.early, .late])
    #expect(events.allSatisfy { $0.routeID == "A" })
    let late = events.first { $0.kind == .late }
    #expect(late?.buses == 1 && late?.seconds == 400)
    let early = events.first { $0.kind == .early }
    #expect(early?.buses == 1 && early?.seconds == 200)
  }

  @Test func onlyAskedForKindsAreReported() {
    let rows = [row("A", delays: [400, -200])]
    #expect(WatchEvaluator.evaluate(status: status(rows), alerts: [], now: now, routes: ["A"], kinds: [.late]).map(\.kind) == [.late])
    #expect(WatchEvaluator.evaluate(status: status(rows), alerts: [], now: now, routes: [], kinds: [.late]).isEmpty)
    #expect(WatchEvaluator.evaluate(status: status(rows), alerts: [], now: now, routes: ["A"], kinds: []).isEmpty)
  }

  @Test func onTimeRoutesGiveNothing() {
    let rows = [row("A", delays: [30, -20, 100])]
    #expect(WatchEvaluator.evaluate(status: status(rows), alerts: [], now: now, routes: ["A"], kinds: Set(WatchKind.allCases)).isEmpty)
  }

  @Test func alertsAreReportedWhileActiveOrSoonToStart() {
    let alerts = [
      alert("now", routes: ["A"], start: -3600, end: 3600),
      alert("tomorrow", routes: ["A"], start: 6 * 3600, end: 12 * 3600),
      alert("next-month", routes: ["A"], start: 30 * 24 * 3600, end: 31 * 24 * 3600),
      alert("over", routes: ["A"], start: -7200, end: -3600),
      alert("other-route", routes: ["B"], start: -3600, end: 3600),
    ]
    let events = WatchEvaluator.evaluate(status: nil, alerts: alerts, now: now, routes: ["A"], kinds: [.alert])
    #expect(Set(events.map(\.alertID)) == ["now", "tomorrow"])
  }

  @Test func theLedgerStopsRepeats() {
    var ledger = WatchLedger()
    let late = WatchEvent(kind: .late, routeID: "A", buses: 1, seconds: 400, alertID: "", headline: "", detail: "")
    let detour = WatchEvent(kind: .alert, routeID: "A", buses: 0, seconds: 0, alertID: "x", headline: "H", detail: "")
    #expect(ledger.fresh([late, detour], now: now).count == 2)
    #expect(ledger.fresh([late, detour], now: now.addingTimeInterval(60)).isEmpty)
    // A route that stays late is mentioned again after a while; an alert is not.
    let later = now.addingTimeInterval(WatchLedger.repeatAfter + 1)
    #expect(ledger.fresh([late, detour], now: later).map(\.kind) == [.late])
  }

  @Test func theLedgerForgetsOldEntries() throws {
    var ledger = WatchLedger()
    let detour = WatchEvent(kind: .alert, routeID: "A", buses: 0, seconds: 0, alertID: "x", headline: "H", detail: "")
    _ = ledger.fresh([detour], now: now)
    let muchLater = now.addingTimeInterval(WatchLedger.forgetAfter + 1)
    #expect(ledger.fresh([detour], now: muchLater).count == 1)
    let copy = try JSONDecoder().decode(WatchLedger.self, from: JSONEncoder().encode(ledger))
    #expect(copy == ledger)
  }
}
