import HeadwayCore
import SwiftUI

private enum PickTarget: String, Identifiable {
  case from, to
  var id: String { rawValue }
}

/// Where do you want to go? Pick two places, get journeys with transfers that account for live delays.
struct PlanView: View {
  @Environment(AppModel.self) private var model
  @State private var picking: PickTarget?
  @State private var departNow = true
  @State private var departDate = Date().addingTimeInterval(600)

  var body: some View {
    let plan = model.plan
    NavigationStack {
      List {
        Section {
          placeRows(plan)
          departureRow(plan)
          Button {
            Task { await model.searchJourneys() }
          } label: {
            HStack {
              Spacer()
              if plan.phase == .searching { ProgressView().padding(.trailing, 6) }
              Text("Find routes").font(.body.weight(.semibold))
              Spacer()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!plan.canSearch || plan.phase == .searching)
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        resultsSection(plan)
      }
      .navigationTitle("Plan a trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarLeading) { MenuButton(plain: true) } }
      .navigationDestination(for: Journey.self) { JourneyDetailView(journey: $0) }
      .sheet(item: $picking) { target in
        PlacePicker(allowsMyLocation: true, title: target == .from ? "Start" : "Destination") { choice in
          if target == .from { plan.from = choice } else { plan.to = choice }
          plan.clearResults()
          if plan.canSearch { Task { await model.searchJourneys() } }
        }
      }
    }
    .task {
      // Arriving with both places filled in (from "Directions") plans straight away.
      if plan.phase == .idle, plan.canSearch { await model.searchJourneys() }
    }
    .onChange(of: model.location.location?.coordinate.latitude) { _, _ in
      // The location can arrive after the screen: retry once if the first attempt had no position.
      if case .failed = plan.phase, plan.canSearch { Task { await model.searchJourneys() } }
    }
  }

  // MARK: Inputs

  private func placeRows(_ plan: PlanModel) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(spacing: 4) {
        Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(.blue)
        ForEach(0..<3, id: \.self) { _ in Circle().fill(.secondary.opacity(0.5)).frame(width: 3, height: 3) }
        Image(systemName: "mappin.circle.fill").font(.system(size: 16)).foregroundStyle(.red)
      }
      VStack(spacing: 0) {
        placeButton(title: "From", choice: plan.from) { picking = .from }
        Divider()
        placeButton(title: "To", choice: plan.to) { picking = .to }
      }
      Button {
        plan.swap()
        plan.clearResults()
        if plan.canSearch { Task { await model.searchJourneys() } }
      } label: {
        Image(systemName: "arrow.up.arrow.down").font(.body.weight(.semibold)).frame(width: 38, height: 38)
      }
      .buttonStyle(.bordered)
      .clipShape(Circle())
      .accessibilityLabel(Text("Swap start and destination"))
    }
    .padding(.vertical, 4)
  }

  private func placeButton(title: LocalizedStringKey, choice: PlaceChoice?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.caption).foregroundStyle(.secondary)
          Text(choice?.title ?? String(localized: "Choose a place")).font(.body)
            .foregroundStyle(choice == nil ? .secondary : .primary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func departureRow(_ plan: PlanModel) -> some View {
    HStack {
      Picker("Leave", selection: Binding(
        get: { departNow },
        set: { value in
          departNow = value
          plan.departure = value ? .now : .at(departDate)
          plan.clearResults()
        })
      ) {
        Text("Leave now").tag(true)
        Text("Depart at").tag(false)
      }
      .pickerStyle(.segmented)
    }
    .overlay(alignment: .bottom) { Color.clear.frame(height: 0) }
    .listRowSeparator(.hidden)
    .padding(.vertical, 2)
    .modifier(DepartureDate(departNow: departNow, date: $departDate) { date in
      plan.departure = .at(date)
      plan.clearResults()
    })
  }

  // MARK: Results

  @ViewBuilder private func resultsSection(_ plan: PlanModel) -> some View {
    switch plan.phase {
    case .idle:
      Section {
        Text("Choose where you are going. Journeys take live delays into account for buses that are reporting.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    case .searching:
      Section { HStack { ProgressView(); Text("Finding routes…").foregroundStyle(.secondary) } }
    case .failed(let message):
      Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
    case .done:
      if plan.results.isEmpty {
        Section {
          Label("No bus journey found. The stops may be too far apart, or no buses run in the next few hours.", systemImage: "bus")
            .foregroundStyle(.secondary)
        }
      } else {
        Section {
          ForEach(plan.results) { journey in
            NavigationLink(value: journey) { JourneyCard(journey: journey) }
          }
        } header: {
          Text("Routes")
        } footer: {
          Text("Walking times are estimated from straight-line distance. Times marked live use each bus's predicted arrival.")
        }
      }
    }
  }
}

/// Shows a date picker under the "Depart at" choice.
private struct DepartureDate: ViewModifier {
  let departNow: Bool
  @Binding var date: Date
  let onChange: (Date) -> Void

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content
      if !departNow {
        DatePicker("Time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
          .onChange(of: date) { _, value in onChange(value) }
      }
    }
  }
}

// MARK: - Cards

struct JourneyCard: View {
  @Environment(AppModel.self) private var model
  let journey: Journey

  var body: some View {
    let text = model.timeText()
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("\(text.clock(journey.departure)) → \(text.clock(journey.arrival))")
          .font(.headline).monospacedDigit()
        Spacer()
        Text(TimeText.duration(journey.duration)).font(.headline).foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
          if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
          switch leg {
          case .walk(let walk):
            HStack(spacing: 2) {
              Image(systemName: "figure.walk")
              Text("\(Int((walk.end.timeIntervalSince(walk.start) / 60).rounded(.up)))").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
          case .ride(let ride):
            RouteBadge(routeID: ride.routeID, compact: true)
          }
        }
      }
      HStack(spacing: 10) {
        Text(journey.transfers == 0 ? String(localized: "Direct") : String(localized: "\(journey.transfers) transfers"))
        if journey.walkingMeters > 0 { Text("· \(String(localized: "walk")) \(TimeText.walking(journey.walkingMeters))") }
        if journey.usesLiveData {
          Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green).labelStyle(.titleAndIcon)
        }
        if let buffer = journey.transferBuffers.min(), buffer < 180 {
          Label("Tight transfer", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      if let first = journey.rides.first {
        let minutes = Int(first.depart.timeIntervalSinceNow / 60)
        Text(minutes <= 0 ? String(localized: "First bus is leaving now") : String(localized: "First bus in \(minutes) min from \(first.fromStop.name)"))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Detail

struct JourneyDetailView: View {
  @Environment(AppModel.self) private var model
  let journey: Journey

  var body: some View {
    List {
      Section { JourneySteps(journey: journey) }
      Section {
        Button { model.showOnMap(journey) } label: {
          Label("Show on map", systemImage: "map").font(.body.weight(.semibold))
        }
      } footer: {
        Text("Walking times are estimated from straight-line distance.")
      }
    }
    .navigationTitle("\(TimeText.duration(journey.duration))")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// The step-by-step list for a journey, used in the detail screen and the map sheet.
struct JourneySteps: View {
  @Environment(AppModel.self) private var model
  let journey: Journey

  var body: some View {
    let text = model.timeText()
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
        if index > 0, case .ride = leg, let buffer = buffer(before: index) {
          TransferNote(seconds: buffer).padding(.vertical, 6)
        }
        switch leg {
        case .walk(let walk):
          StepRow(symbol: "figure.walk", tint: .secondary) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Walk \(TimeText.duration(walk.end.timeIntervalSince(walk.start))) to \(walk.to.name)").font(.subheadline)
              Text("\(TimeText.walking(walk.meters)) · \(text.clock(walk.start))–\(text.clock(walk.end))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
          }
        case .ride(let ride):
          StepRow(routeID: ride.routeID) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Route \(model.route(ride.routeID)?.shortName ?? ride.routeID) to \(ride.headsign.prettyHeadsign)")
                .font(.subheadline.weight(.semibold))
              Text("Board at \(ride.fromStop.name) · \(text.clock(ride.depart))").font(.footnote)
              Text("Get off at \(ride.toStop.name) · \(text.clock(ride.arrive))").font(.footnote)
              HStack(spacing: 8) {
                Text("\(ride.stopCount) stops").foregroundStyle(.secondary)
                if ride.isLive {
                  Label(TimeText.delay(ride.delay) ?? String(localized: "Live"), systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                } else {
                  Label("Scheduled", systemImage: "clock").foregroundStyle(.secondary)
                }
              }
              .font(.caption)
            }
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  /// Time between arriving by one bus and the next bus leaving, for the transfer into `legs[index]`.
  private func buffer(before index: Int) -> TimeInterval? {
    guard case .ride(let next) = journey.legs[index] else { return nil }
    let previousEnd = journey.legs[index - 1].end
    guard journey.legs[..<index].contains(where: { if case .ride = $0 { return true } else { return false } }) else { return nil }
    return next.depart.timeIntervalSince(previousEnd)
  }
}

private struct TransferNote: View {
  let seconds: TimeInterval

  var body: some View {
    let minutes = Int((seconds / 60).rounded())
    HStack(spacing: 6) {
      Image(systemName: "arrow.left.arrow.right").font(.caption)
      Text("Transfer · \(minutes) min to connect").font(.caption)
    }
    .foregroundStyle(seconds < 180 ? Color.orange : Color.secondary)
    .padding(.leading, 52)
  }
}

private struct StepRow<Content: View>: View {
  var symbol: String?
  var tint: Color = .primary
  var routeID: String?
  @ViewBuilder let content: Content

  init(symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
    self.symbol = symbol
    self.tint = tint
    self.content = content()
  }

  init(routeID: String, @ViewBuilder content: () -> Content) {
    self.routeID = routeID
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Group {
        if let routeID { RouteBadge(routeID: routeID, compact: true) } else if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
      }
      .frame(width: 40, alignment: .leading)
      content
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }
}
