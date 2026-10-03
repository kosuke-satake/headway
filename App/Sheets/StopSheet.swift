import HeadwayCore
import SwiftUI

/// The board for one stop: what is coming next, live where possible, and a way into the full timetable.
struct StopSheet: View {
  @Environment(AppModel.self) private var model
  let stopID: String

  var body: some View {
    NavigationStack {
      if let stop = model.schedule?.stops[stopID] {
        VStack(spacing: 0) {
          header(stop)
          Divider()
          board
        }
        .navigationBarHidden(true)
        .navigationDestination(for: String.self) { id in TimetableView(stopID: id) }
      } else {
        ContentUnavailableView("Stop not found", systemImage: "mappin.slash")
      }
    }
  }

  // MARK: Header

  private func header(_ stop: Stop) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(stop.name).font(.title3.weight(.semibold)).lineLimit(2)
          HStack(spacing: 6) {
            if !stop.code.isEmpty { Text("Stop \(stop.code)") }
            if let distance = distance(to: stop) { Text("· \(distance)") }
          }
          .font(.footnote).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button {
          model.startDirections(to: PlanPoint(name: stop.name, coordinate: Coordinate(latitude: stop.latitude, longitude: stop.longitude), stopID: stop.id))
        } label: {
          Image(systemName: "arrow.triangle.turn.up.right.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.accentColor).frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Directions to here"))
        Button { model.settings.toggleFavorite(stop: stop.id) } label: {
          Image(systemName: model.settings.isFavorite(stop: stop.id) ? "star.fill" : "star")
            .font(.title3).foregroundStyle(model.settings.isFavorite(stop: stop.id) ? Color.orange : .secondary)
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel(model.settings.isFavorite(stop: stop.id) ? Text("Remove from favorites") : Text("Add to favorites"))
        Button { model.clearSelection() } label: {
          Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).frame(width: 36, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
      }
      let routes = model.visibleRoutes(atStop: stop.id)
      if !routes.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) { ForEach(routes, id: \.self) { RouteBadge(routeID: $0, compact: true) } }
        }
      }
    }
    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
  }

  private func distance(to stop: Stop) -> String? {
    guard let here = model.location.location else { return nil }
    let meters = here.distance(from: .init(latitude: stop.latitude, longitude: stop.longitude))
    return meters < 20_000 ? TimeText.distance(meters) : nil
  }

  // MARK: Board

  private var board: some View {
    List {
      let alerts = model.alerts(forStop: stopID)
      if !alerts.isEmpty {
        Section {
          ForEach(alerts) { AlertRow(alert: $0) }
        }
      }
      let arrivals = model.boardArrivals
      if arrivals.isEmpty {
        Text(LocalizedStringKey(model.schedule == nil ? "Loading timetable…" : "No buses are scheduled here soon."))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .listRowSeparator(.hidden)
      } else {
        if model.arrivalsAreLater {
          Label("No more buses for a while. Service resumes:", systemImage: "moon.zzz")
            .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        }
        TimelineView(.periodic(from: .now, by: 10)) { context in
          VStack(spacing: 0) {
            ForEach(arrivals) { arrival in
              ArrivalRow(arrival: arrival, now: context.date)
              if arrival.id != arrivals.last?.id { Divider() }
            }
          }
        }
        .listRowInsets(EdgeInsets())
      }
      if model.hiddenArrivalCount > 0 || model.showHiddenRoutes, !model.hiddenRoutes.isEmpty {
        Toggle(isOn: Bindable(model).showHiddenRoutes) {
          Text("Show hidden routes").font(.footnote)
        }
        .onChange(of: model.showHiddenRoutes) { _, _ in model.refreshArrivals() }
      }
      NavigationLink(value: stopID) {
        Label("Full timetable", systemImage: "calendar.day.timeline.left")
      }
    }
    .listStyle(.plain)
  }
}

struct ArrivalRow: View {
  @Environment(AppModel.self) private var model
  let arrival: Arrival
  let now: Date

  var body: some View {
    let text = model.timeText()
    Button {
      if let vehicle = arrival.vehicle { model.selectBus(vehicle.id) }
    } label: {
      HStack(spacing: 12) {
        RouteBadge(routeID: arrival.routeID)
        VStack(alignment: .leading, spacing: 2) {
          Text(arrival.headsign.prettyHeadsign).font(.body).lineLimit(1)
          LiveStatus(arrival: arrival, showDelay: model.settings.values.showDelayDetails)
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 1) {
          Text(text.arrival(arrival, now: now))
            .font(.title3.weight(arrival.status == .live ? .semibold : .regular)).monospacedDigit()
          if model.settings.values.arrivalStyle == .countdown, arrival.minutes(from: now) < 60 {
            Text(text.clock(arrival.expected)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Only buses with a position can be shown on the map; timetable-only rows stay fully legible but do nothing.
    .allowsHitTesting(arrival.vehicle != nil)
    .accessibilityElement(children: .combine)
  }
}

/// A service alert such as a detour. The headline always shows; the details open on tap.
struct AlertRow: View {
  let alert: ServiceAlert
  @State private var expanded = false

  var body: some View {
    Button {
      if !alert.detail.isEmpty { withAnimation(.snappy) { expanded.toggle() } }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 4) {
          Text(alert.header).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
          if expanded, !alert.detail.isEmpty {
            Text(alert.detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            if let url = alert.url {
              Link(destination: url) { Label("Detour details", systemImage: "arrow.up.right.square") }
                .font(.footnote.weight(.medium))
            }
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
    .accessibilityElement(children: .combine)
    .accessibilityHint(alert.detail.isEmpty ? Text("") : Text("Shows details"))
  }
}
