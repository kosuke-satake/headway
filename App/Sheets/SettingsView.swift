import HeadwayCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var confirmReset = false
  @State private var refreshing = false
  @State private var refreshMessage: LocalizedStringKey?

  var body: some View {
    @Bindable var settings = model.settings
    NavigationStack {
      Form {
        Section {
          Picker("Theme", selection: $settings.values.appearance) {
            Text("System").tag(AppearanceMode.system)
            Text("Light").tag(AppearanceMode.light)
            Text("Dark").tag(AppearanceMode.dark)
          }
          Picker("Route colors", selection: $settings.values.routePalette) {
            Text("Metro Transit").tag(RoutePalette.agency)
            Text("High contrast").tag(RoutePalette.distinct)
            Text("Quiet").tag(RoutePalette.quiet)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Route line thickness")
            Slider(value: $settings.values.routeLineWidth, in: 0.6...1.6, step: 0.1)
              .accessibilityLabel(Text("Route line thickness"))
          }
          Picker("Bus marker size", selection: $settings.values.markerSize) {
            Text("Small").tag(MarkerSize.small)
            Text("Medium").tag(MarkerSize.medium)
            Text("Large").tag(MarkerSize.large)
          }
          Toggle("Show route name on buses", isOn: $settings.values.showRouteNameOnBuses)
        } header: {
          Text("Appearance")
        } footer: {
          Text("High contrast uses a colour-blind-safe palette. Quiet greys the route lines; the route you look at stays coloured.")
        }

        Section("Map") {
          Picker("Bus stops", selection: $settings.values.stopVisibility) {
            Text("When zoomed in").tag(StopVisibility.zoomed)
            Text("Always").tag(StopVisibility.always)
            Text("Hidden").tag(StopVisibility.hidden)
          }
          Toggle("Show stop names", isOn: $settings.values.showStopNames)
          Toggle("Remember map position", isOn: $settings.values.rememberMapPosition)
          LabeledContent("Map data", value: String(localized: "Madison area, on this device"))
        }

        Section {
          Picker("Refresh", selection: $settings.values.updateInterval) {
            Text("Automatic").tag(0)
            Text("Every 30 seconds").tag(30)
            Text("Every minute").tag(60)
          }
          Toggle("Estimate positions between reports", isOn: $settings.values.estimateBusPositions)
          Toggle("Smooth bus movement", isOn: $settings.values.smoothBusMovement)
          Toggle("Pause in the background", isOn: $settings.values.pauseLiveInBackground)
        } header: {
          Text("Live buses")
        } footer: {
          Text("The city's feed is rebuilt every 30 seconds and each bus reports every 30 seconds, so a position is about 25 seconds old when you see it. Automatic refresh asks right after each rebuild. Estimating moves each bus along its route at its last speed; a veiled bus has not reported for over a minute. Predicted arrival times are fetched only while a stop or bus is open.")
        }

        Section("Times") {
          Picker("Clock", selection: $settings.values.clockFormat) {
            Text("System").tag(ClockFormat.system)
            Text("12-hour").tag(ClockFormat.twelveHour)
            Text("24-hour").tag(ClockFormat.twentyFourHour)
          }
          Picker("Arrivals", selection: $settings.values.arrivalStyle) {
            Text("Minutes").tag(ArrivalStyle.countdown)
            Text("Clock times").tag(ArrivalStyle.clock)
          }
          Toggle("Show how late or early", isOn: $settings.values.showDelayDetails)
        }

        Section("Behavior") {
          Toggle("Haptic feedback", isOn: $settings.values.hapticFeedback)
          if let url = URL(string: UIApplication.openSettingsURLString) {
            Link(destination: url) { Label("Language and location", systemImage: "gear") }
          }
        }

        Section("Trip planner") {
          NavigationLink("Trip options") { PlanOptionsForm().navigationTitle("Trip options").navigationBarTitleDisplayMode(.inline) }
          NavigationLink("Saved places") { SavedPlacesView() }
        }

        Section("Favorites") {
          NavigationLink("Favorite stops") { FavoriteStopsView() }
          LabeledContent("Favorite routes", value: "\(settings.values.favoriteRoutes.count)")
        }

        Section {
          if let schedule = model.schedule {
            LabeledContent("Timetable", value: schedule.feedVersion)
            if let end = schedule.feedEnd {
              LabeledContent("Valid until", value: Self.formatted(end))
            }
          }
          Button {
            Task {
              refreshing = true
              switch await model.refreshTimetable() {
              case .updated: refreshMessage = "Timetable updated."
              case .upToDate: refreshMessage = "The timetable is up to date."
              case .failed: refreshMessage = "Could not reach the server."
              }
              refreshing = false
            }
          } label: {
            HStack {
              Text("Refresh timetable now")
              if refreshing { Spacer(); ProgressView() }
            }
          }
          .disabled(refreshing)
          if let refreshMessage { Text(refreshMessage).font(.footnote).foregroundStyle(.secondary) }
        } header: {
          Text("Data")
        } footer: {
          Text("Timetables and live positions: Data provided under license granted by City of Madison, WI, Metro Transit. Map: © OpenStreetMap contributors, Protomaps.")
        }

        Section {
          LabeledContent("Version", value: Self.version)
          Button("Reset settings", role: .destructive) { confirmReset = true }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
      .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
        Button("Reset settings", role: .destructive) { model.settings.reset() }
      } message: {
        Text("Favorites and recent stops are kept.")
      }
    }
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
  }

  private static func formatted(_ date: ServiceDate) -> String {
    let components = DateComponents(year: date.value / 10_000, month: date.value / 100 % 100, day: date.value % 100)
    guard let value = Calendar(identifier: .gregorian).date(from: components) else { return "\(date.value)" }
    return value.formatted(date: .abbreviated, time: .omitted)
  }
}

struct FavoriteStopsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let stops = model.settings.values.favoriteStops
    List {
      if stops.isEmpty {
        Text("Tap the star on a stop to add it here.").foregroundStyle(.secondary)
      }
      ForEach(stops, id: \.self) { id in
        HStack {
          Text(model.schedule?.stops[id]?.name ?? id)
          Spacer()
          Text(model.schedule?.stops[id]?.code ?? "").font(.caption).foregroundStyle(.secondary)
        }
      }
      .onDelete { model.settings.values.favoriteStops.remove(atOffsets: $0) }
      .onMove { model.settings.values.favoriteStops.move(fromOffsets: $0, toOffset: $1) }
    }
    .navigationTitle("Favorite stops")
    .toolbar { EditButton() }
  }
}
