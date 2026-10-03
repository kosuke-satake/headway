import HeadwayCore
import SwiftUI

/// One bus: where it is going next and when it gets there.
struct BusSheet: View {
  @Environment(AppModel.self) private var model
  let vehicleID: String

  var body: some View {
    NavigationStack {
      if let vehicle = model.vehicles.first(where: { $0.id == vehicleID }) {
        let text = model.timeText()
        let stops = model.remainingStops(of: vehicle)
        VStack(spacing: 0) {
          header(vehicle)
          Divider()
          List {
            if stops.isEmpty {
              Text("No upcoming stops are known for this bus.").foregroundStyle(.secondary)
            } else {
              Section("Next stops") {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                  VStack(spacing: 0) {
                    ForEach(stops.prefix(30)) { eta in
                      stopRow(eta, text: text, now: context.date)
                      if eta.id != stops.prefix(30).last?.id { Divider() }
                    }
                  }
                }
                .listRowInsets(EdgeInsets())
              }
            }
          }
          .listStyle(.plain)
        }
        .navigationBarHidden(true)
      } else {
        ContentUnavailableView {
          Label("This bus is no longer reporting", systemImage: "bus")
        } actions: {
          Button("Close") { model.clearSelection() }
        }
      }
    }
  }

  private func header(_ vehicle: VehicleSample) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        RouteBadge(routeID: vehicle.routeID)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.headsign(of: vehicle.tripID).prettyHeadsign).font(.title3.weight(.semibold)).lineLimit(2)
          HStack(spacing: 6) {
            Text("Bus \(vehicle.vehicleID)")
            if let age = positionAge(vehicle) { Text("· \(age)") }
          }
          .font(.footnote).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button { model.clearSelection() } label: {
          Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).frame(width: 36, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
      }
      if let stopID = model.returnStopID, let stop = model.schedule?.stops[stopID] {
        Button {
          model.selectStop(stopID)
        } label: {
          Label("Back to \(stop.name)", systemImage: "chevron.backward").font(.footnote.weight(.medium))
        }
      }
    }
    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
  }

  private func positionAge(_ vehicle: VehicleSample) -> String? {
    guard let timestamp = vehicle.timestamp else { return nil }
    let seconds = max(0, Int(Date().timeIntervalSince(timestamp)))
    return String(localized: "position \(seconds) s old")
  }

  private func stopRow(_ eta: TripStopEta, text: TimeText, now: Date) -> some View {
    let stop = model.schedule?.stops[eta.stopID]
    let delay = eta.predicted.map { Int($0.timeIntervalSince(eta.scheduled).rounded()) }
    return Button {
      model.selectStop(eta.stopID)
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(stop?.name ?? eta.stopID).font(.body).lineLimit(1)
          if model.settings.values.showDelayDetails, let label = TimeText.delay(delay) {
            Text(label).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Text(text.clock(eta.expected)).font(.body.weight(.medium)).monospacedDigit()
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
