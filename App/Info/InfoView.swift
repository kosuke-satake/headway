import HeadwayCore
import SwiftUI

/// The service board: what is going wrong or right right now, without the map.
struct InfoView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    NavigationStack {
      List {
        summary
        favorites
        alertsSection
        delaysSection
        cancellationsSection
        silentSection
        upcomingSection
      }
      .navigationTitle("Service info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarLeading) { MenuButton(plain: true) } }
      .refreshable {
        model.refreshStatus()
        try? await Task.sleep(for: .milliseconds(400))
      }
    }
    .onAppear { model.refreshStatus() }
  }

  // MARK: Summary

  private var summary: some View {
    Section {
      let status = model.status
      let late = status?.routes.filter { $0.lateBuses > 0 }.count ?? 0
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text("\(status?.busesOnRoad ?? model.vehicles.count)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
          Text("buses on the road").foregroundStyle(.secondary)
          Spacer()
          LiveAgeText()
        }
        HStack(spacing: 8) {
          SummaryChip(symbol: "exclamationmark.triangle.fill", tint: .orange, text: String(localized: "\(model.visibleActiveAlerts.count) alerts"))
          SummaryChip(symbol: "clock.badge.exclamationmark", tint: late > 0 ? .red : .green,
            text: late > 0 ? String(localized: "\(late) routes late") : String(localized: "No late routes"))
        }
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: Favourites

  @ViewBuilder private var favorites: some View {
    let stops = model.settings.values.favoriteStops.compactMap { model.schedule?.stops[$0] }
    if !stops.isEmpty {
      Section("My stops") {
        ForEach(stops) { stop in FavoriteStopRow(stop: stop) }
      }
    }
  }

  // MARK: Alerts

  @ViewBuilder private var alertsSection: some View {
    Section {
      let alerts = model.visibleActiveAlerts
      if alerts.isEmpty {
        Label("No service alerts", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      } else {
        ForEach(alerts) { AlertCard(alert: $0) }
      }
    } header: {
      Text("Detours and alerts")
    } footer: {
      Text("Routes with an alert are drawn dashed on the map. The city does not publish the detour paths; the details link to its detour page.")
    }
  }

  @ViewBuilder private var upcomingSection: some View {
    let upcoming = model.upcomingAlerts
    if !upcoming.isEmpty {
      Section("Coming up") {
        ForEach(upcoming) { AlertCard(alert: $0) }
      }
    }
  }

  // MARK: Delays

  @ViewBuilder private var delaysSection: some View {
    Section {
      if let status = model.status {
        let rows = status.routes.filter { !model.hiddenRoutes.contains($0.routeID) }
        let late = rows.filter { $0.lateBuses > 0 }
        if rows.isEmpty {
          Text("No buses are reporting.").foregroundStyle(.secondary)
        } else if late.isEmpty {
          Label("No routes are running more than five minutes late.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        ForEach(rows.sorted { ($0.averageDelay ?? -.infinity) > ($1.averageDelay ?? -.infinity) }) { RouteStatusRow(status: $0) }
      } else {
        ProgressView()
      }
    } header: {
      Text("Delays right now")
    } footer: {
      Text("Measured from each bus's predicted arrival at its next stop compared with the timetable. Buses without a prediction are not counted.")
    }
  }

  // MARK: Cancellations

  @ViewBuilder private var cancellationsSection: some View {
    Section {
      if let status = model.status {
        if status.cancelledTrips.isEmpty, status.skippedStops == 0 {
          Label("No cancelled trips or skipped stops reported", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        ForEach(status.cancelledTrips, id: \.entityID) { trip in
          HStack(spacing: 10) {
            RouteBadge(routeID: trip.routeID, compact: true)
            Text(model.headsign(of: trip.tripID).prettyHeadsign).lineLimit(1)
            Spacer()
            Text("Cancelled").font(.caption.weight(.semibold)).foregroundStyle(.red)
          }
        }
        if status.skippedStops > 0 {
          Label("\(status.skippedStops) stops are being skipped by some trips", systemImage: "forward.end.alt")
            .foregroundStyle(.orange)
        }
      }
    } header: {
      Text("Cancellations")
    }
  }

  // MARK: Silent trips

  @ViewBuilder private var silentSection: some View {
    if let status = model.status, !status.silentTrips.isEmpty {
      let text = model.timeText()
      let trips = status.silentTrips.filter { !model.hiddenRoutes.contains($0.routeID) }
      Section {
        ForEach(trips.prefix(12)) { trip in
          HStack(spacing: 10) {
            RouteBadge(routeID: trip.routeID, compact: true)
            Text(trip.headsign.prettyHeadsign).lineLimit(1)
            Spacer()
            Text("\(text.clock(trip.scheduledStart))–\(text.clock(trip.scheduledEnd))")
              .font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        if trips.count > 12 {
          Text("and \(trips.count - 12) more").font(.footnote).foregroundStyle(.secondary)
        }
      } header: {
        Text("Not reporting a position (\(trips.count))")
      } footer: {
        Text("These trips should be running by the timetable, but no bus reports being on them. The bus may be running without live tracking, or the trip may not be running. Times shown for them come from the timetable.")
      }
    }
  }
}

// MARK: - Pieces

private struct SummaryChip: View {
  let symbol: String
  let tint: Color
  let text: String

  var body: some View {
    Label { Text(text).font(.footnote.weight(.medium)) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(tint.opacity(0.12), in: Capsule())
  }
}

private struct LiveAgeText: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if let updated = model.lastLiveUpdate {
        Text("Updated \(Int(context.date.timeIntervalSince(updated))) s ago").font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }
}

struct AlertCard: View {
  @Environment(AppModel.self) private var model
  let alert: ServiceAlert
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        if !alert.detail.isEmpty { withAnimation(.snappy) { expanded.toggle() } }
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: icon).foregroundStyle(.orange).frame(width: 22)
          VStack(alignment: .leading, spacing: 6) {
            Text(alert.header).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
            if !alert.routeIDs.isEmpty {
              HStack(spacing: 4) { ForEach(alert.routeIDs, id: \.self) { RouteBadge(routeID: $0, compact: true) } }
            }
          }
          Spacer(minLength: 0)
          if !alert.detail.isEmpty {
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        Text(alert.detail).font(.footnote).foregroundStyle(.secondary)
        if let url = alert.url {
          Link(destination: url) { Label("Detour details", systemImage: "arrow.up.right.square") }.font(.footnote.weight(.medium))
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var icon: String {
    switch alert.effect {
    case "NO_SERVICE": "nosign"
    case "REDUCED_SERVICE", "SIGNIFICANT_DELAYS": "clock.badge.exclamationmark"
    case "STOP_MOVED": "mappin.and.ellipse"
    default: "arrow.triangle.turn.up.right.diamond.fill"
    }
  }
}

private struct RouteStatusRow: View {
  @Environment(AppModel.self) private var model
  let status: RouteStatus

  var body: some View {
    HStack(spacing: 12) {
      if model.route(status.routeID) != nil {
        RouteBadge(routeID: status.routeID)
      } else {
        // Buses that report a position but no known route (for example in the garage or on a deadhead run).
        Image(systemName: "questionmark")
          .font(.subheadline.weight(.bold)).foregroundStyle(.white)
          .frame(width: 34, height: 28).background(.gray, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("\(status.buses) buses").font(.subheadline)
        if model.route(status.routeID) == nil {
          Text("Not on a route").font(.caption).foregroundStyle(.secondary)
        } else if status.measured == 0 {
          Text("No prediction").font(.caption).foregroundStyle(.secondary)
        } else if status.lateBuses > 0 {
          Text("\(status.lateBuses) buses more than 5 min late").font(.caption).foregroundStyle(.red)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 1) {
        if let average = status.averageDelay {
          let label = TimeText.delay(Int(average.rounded())) ?? ""
          Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(color(average)).monospacedDigit()
        }
        if let usual = model.reliability(route: status.routeID, stop: nil), let label = TimeText.delay(usual.cell.p50) {
          Text("usually \(label)").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func color(_ delay: Double) -> Color {
    if delay > ServiceStatusBuilder.lateThreshold { return .red }
    if delay > 90 { return .orange }
    return .secondary
  }
}

private struct FavoriteStopRow: View {
  @Environment(AppModel.self) private var model
  let stop: Stop

  var body: some View {
    let arrivals = upcoming()
    let text = model.timeText()
    Button {
      model.mode = .map
      model.selectStop(stop.id)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Text(stop.name).font(.subheadline.weight(.semibold))
        if arrivals.isEmpty {
          Text("No buses soon").font(.caption).foregroundStyle(.secondary)
        } else {
          HStack(spacing: 10) {
            ForEach(arrivals) { arrival in
              HStack(spacing: 4) {
                RouteBadge(routeID: arrival.routeID, compact: true)
                Text(text.arrival(arrival, now: Date())).font(.footnote.weight(.medium)).monospacedDigit()
                if arrival.status == .live { Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.green) }
              }
            }
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func upcoming() -> [Arrival] {
    guard let schedule = model.schedule else { return [] }
    return Array(
      Arrivals.upcoming(
        schedule: schedule, stopID: stop.id, now: Date(), predictions: model.predictions, vehicles: model.vehicles, limit: 12
      )
      .filter { !model.hiddenRoutes.contains($0.routeID) }.prefix(3))
  }
}
