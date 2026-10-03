import HeadwayCore
import SwiftUI

/// The full day's timetable for a stop: hours down the side, minutes across, one block per route and direction.
struct TimetableView: View {
  @Environment(AppModel.self) private var model
  let stopID: String

  @State private var dayOffset = 0
  @State private var routeFilter: String?

  var body: some View {
    let text = model.timeText()
    let departures = loadDepartures()
    let routeIDs = Array(Set(departures.map(\.routeID))).sorted { (model.route($0)?.sortOrder ?? .max, $0) < (model.route($1)?.sortOrder ?? .max, $1) }
    List {
      Section {
        Picker("Day", selection: $dayOffset) {
          ForEach(0..<7, id: \.self) { Text(dayTitle($0)).tag($0) }
        }
        .pickerStyle(.menu)
        if routeIDs.count > 1 {
          Picker("Route", selection: $routeFilter) {
            Text("All routes").tag(String?.none)
            ForEach(routeIDs, id: \.self) { Text("Route \(model.route($0)?.shortName ?? $0)").tag(String?.some($0)) }
          }
          .pickerStyle(.menu)
        }
      }
      if departures.isEmpty {
        Text("No service on this day.").foregroundStyle(.secondary)
      }
      ForEach(groups(departures), id: \.key) { group in
        Section {
          ForEach(hours(group.departures, text: text), id: \.hour) { row in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(row.hour).font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 54, alignment: .trailing)
              Text(row.minutes.joined(separator: "  ")).font(.body).monospacedDigit()
              Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
          }
        } header: {
          HStack(spacing: 8) {
            RouteBadge(routeID: group.routeID, compact: true)
            Text(group.headsign.prettyHeadsign).textCase(nil).font(.subheadline.weight(.semibold))
          }
        }
      }
    }
    .navigationTitle(model.schedule?.stops[stopID]?.name ?? "")
    .navigationBarTitleDisplayMode(.inline)
  }

  // MARK: Data

  private func dayStart() -> Date {
    let zone = model.schedule?.timeZone ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date()))!
  }

  private func dayTitle(_ offset: Int) -> String {
    let zone = model.schedule?.timeZone ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
    if offset == 0 { return String(localized: "Today") }
    if offset == 1 { return String(localized: "Tomorrow") }
    let formatter = DateFormatter()
    formatter.timeZone = zone
    formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return formatter.string(from: date)
  }

  private func loadDepartures() -> [ScheduledDeparture] {
    guard let schedule = model.schedule else { return [] }
    let start = dayStart()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
    let all = schedule.scheduledDepartures(from: stopID, from: start, until: end)
    guard let routeFilter else { return all }
    return all.filter { $0.routeID == routeFilter }
  }

  private struct Group {
    let key: String
    let routeID: String
    let headsign: String
    let departures: [ScheduledDeparture]
  }

  private func groups(_ departures: [ScheduledDeparture]) -> [Group] {
    let grouped = Dictionary(grouping: departures) { "\($0.routeID)|\($0.headsign)" }
    return grouped.map { key, items in Group(key: key, routeID: items[0].routeID, headsign: items[0].headsign, departures: items) }
      .sorted { (model.route($0.routeID)?.sortOrder ?? .max, $0.key) < (model.route($1.routeID)?.sortOrder ?? .max, $1.key) }
  }

  private func hours(_ departures: [ScheduledDeparture], text: TimeText) -> [(hour: String, minutes: [String])] {
    var rows: [(hour: String, minutes: [String])] = []
    for departure in departures.sorted(by: { $0.time < $1.time }) {
      let hour = text.hourLabel(departure.time)
      let minute = text.minuteLabel(departure.time)
      if let last = rows.last, last.hour == hour {
        rows[rows.count - 1].minutes.append(minute)
      } else {
        rows.append((hour, [minute]))
      }
    }
    return rows
  }
}
