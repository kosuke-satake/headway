import HeadwayCore
import SwiftUI

private enum PickTarget: Identifiable, Equatable {
  case from, to, home, work, place
  /// A stop on the way (identified by the stop's id in `PlanModel.vias`).
  case via(UUID)

  var id: String {
    switch self {
    case .from: "from"
    case .to: "to"
    case .home: "home"
    case .work: "work"
    case .place: "place"
    case .via(let id): "via-\(id)"
    }
  }
}

private enum DepartMode: String, CaseIterable, Identifiable {
  case now, at, arriveBy
  var id: String { rawValue }
}

/// Where do you want to go? Pick two places, get journeys with transfers that account for live delays.
struct PlanView: View {
  @Environment(AppModel.self) private var model
  @State private var picking: PickTarget?
  @State private var showOptions = false
  @State private var showSavedPlaces = false
  @State private var showAllRecents = false
  @State private var path: [Journey] = []
  @State private var mode: DepartMode = .now
  @State private var date = Date().addingTimeInterval(900)

  var body: some View {
    let plan = model.plan
    NavigationStack(path: $path) {
      List {
        savedPlaces
        savedTrips
        Section {
          placeRows(plan)
          departureRow(plan)
          findRow(plan)
        }
        content(plan)
      }
      .navigationTitle("Plan a trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { MenuButton(plain: true) }
        ToolbarItem(placement: .topBarTrailing) {
          Button { showOptions = true } label: { Image(systemName: "slider.horizontal.3") }
            .accessibilityLabel(Text("Trip options"))
        }
      }
      .navigationDestination(for: Journey.self) { JourneyDetailView(journey: $0) }
      .onChange(of: path.count) { _, count in model.planPushed = count > 0 }
      .sheet(item: $picking) { target in
        PlacePicker(allowsMyLocation: target == .from || target == .to, title: title(for: target)) { choice in
          apply(choice, to: target)
        }
      }
      .sheet(isPresented: $showOptions) { PlanOptionsView() }
      .sheet(isPresented: $showSavedPlaces) {
        NavigationStack {
          SavedPlacesView()
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { showSavedPlaces = false } } }
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

  private func title(for target: PickTarget) -> LocalizedStringKey {
    switch target {
    case .from: "Start"
    case .to: "Destination"
    case .home: "Home"
    case .work: "Work"
    case .place: "Save a place"
    case .via: "Stop on the way"
    }
  }

  private func apply(_ choice: PlaceChoice, to target: PickTarget) {
    let plan = model.plan
    switch target {
    case .from, .to:
      if target == .from { plan.from = choice } else { plan.to = choice }
      plan.clearResults()
      if plan.canSearch { Task { await model.searchJourneys() } }
    case .via(let id):
      if let index = plan.vias.firstIndex(where: { $0.id == id }) { plan.vias[index].place = choice }
      plan.clearResults()
      if plan.canSearch { Task { await model.searchJourneys() } }
    case .home, .work, .place:
      guard case .point(let point) = choice else { return }
      model.settings.save(place: point, as: target == .home ? .home : target == .work ? .work : .other)
    }
  }

  // MARK: Saved places

  @ViewBuilder private var savedPlaces: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          placeChip(kind: .home, title: "Home", pick: .home)
          placeChip(kind: .work, title: "Work", pick: .work)
          ForEach(model.settings.values.savedPlaces.filter { $0.kind == .other }) { place in
            Button { go(to: place.point) } label: { ChipLabel(symbol: place.kind.symbol, text: place.name, filled: true) }
              .buttonStyle(.plain)
              .contextMenu {
                Button("Directions from here", systemImage: "figure.walk.departure") { setStart(place.point) }
                Button("Edit", systemImage: "pencil") { showSavedPlaces = true }
                Button("Remove", systemImage: "trash", role: .destructive) { model.settings.removePlace(place.id) }
              }
          }
          Button { picking = .place } label: { ChipLabel(symbol: "plus", text: String(localized: "Add place"), filled: false) }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
      }
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
    } header: {
      HStack {
        Text("Saved places")
        Spacer()
        Button("Edit") { showSavedPlaces = true }.textCase(nil)
      }
    }
  }

  @ViewBuilder private func placeChip(kind: PlaceKind, title: LocalizedStringKey, pick: PickTarget) -> some View {
    if let place = model.settings.place(of: kind) {
      Button { go(to: place.point) } label: { ChipLabel(symbol: kind.symbol, text: place.name, filled: true) }
        .buttonStyle(.plain)
        .contextMenu {
          Button("Directions from here", systemImage: "figure.walk.departure") { setStart(place.point) }
          Button("Change", systemImage: "pencil") { picking = pick }
          Button("Edit", systemImage: "slider.horizontal.3") { showSavedPlaces = true }
          Button("Remove", systemImage: "trash", role: .destructive) { model.settings.removePlace(place.id) }
        }
    } else {
      Button { picking = pick } label: { ChipLabel(symbol: kind.symbol, text: String(localized: "Set \(String(localized: kind == .home ? "Home" : "Work"))"), filled: false) }
        .buttonStyle(.plain)
    }
  }

  private func go(to point: PlanPoint) {
    let plan = model.plan
    plan.to = .point(point)
    if plan.from == nil || plan.from == plan.to { plan.from = .myLocation }
    plan.clearResults()
    model.location.start()
    Task { await model.searchJourneys() }
  }

  private func setStart(_ point: PlanPoint) {
    let plan = model.plan
    plan.from = .point(point)
    if plan.to == plan.from { plan.to = nil }
    plan.clearResults()
    if plan.canSearch { Task { await model.searchJourneys() } }
  }

  // MARK: Inputs

  private func placeRows(_ plan: PlanModel) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 12) {
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(.blue).frame(width: 16)
            placeButton(title: "From", choice: plan.from) { picking = .from }
          }
          ForEach(plan.vias) { via in
            Divider().padding(.leading, 28)
            viaRow(via, plan: plan)
          }
          Divider().padding(.leading, 28)
          HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill").font(.system(size: 16)).foregroundStyle(.red).frame(width: 16)
            placeButton(title: "To", choice: plan.to) { picking = .to }
          }
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
      if plan.vias.count < PlanModel.maxVias {
        Button {
          plan.addVia()
          plan.clearResults()
        } label: {
          Label("Add a stop", systemImage: "plus.circle").font(.subheadline)
        }
        .buttonStyle(.borderless)
        .padding(.leading, 28)
      }
    }
    .padding(.vertical, 4)
  }

  /// A stop on the way: where, how long to stay, and a button to take it out.
  private func viaRow(_ via: PlanVia, plan: PlanModel) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "circle").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 16)
      VStack(alignment: .leading, spacing: 0) {
        placeButton(title: "Stop on the way", choice: via.place) { picking = .via(via.id) }
        Menu {
          ForEach(PlanVia.dwellChoices, id: \.self) { minutes in
            Button(TimeText.minutesLabel(minutes)) {
              if let index = plan.vias.firstIndex(where: { $0.id == via.id }) { plan.vias[index].dwellMinutes = minutes }
              plan.clearResults()
            }
          }
        } label: {
          Label("Stay \(TimeText.minutesLabel(via.dwellMinutes))", systemImage: "clock").font(.caption)
        }
        .padding(.bottom, 6)
      }
      Button {
        plan.removeVia(via.id)
        plan.clearResults()
      } label: {
        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).font(.title3)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Remove this stop"))
    }
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
    .contextMenu {
      if case .point(let point)? = choice {
        Button("Save as Home", systemImage: "house") { model.settings.save(place: point, as: .home) }
        Button("Save as Work", systemImage: "briefcase") { model.settings.save(place: point, as: .work) }
        Button("Save place", systemImage: "star") { model.settings.save(place: point, as: .other) }
      }
    }
  }

  private func departureRow(_ plan: PlanModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Leave", selection: Binding(
        get: { mode },
        set: { value in
          mode = value
          plan.departure = departure(for: value)
          plan.clearResults()
          if plan.canSearch, value == .now { Task { await model.searchJourneys() } }
        })
      ) {
        Text("Leave now").tag(DepartMode.now)
        Text("Depart at").tag(DepartMode.at)
        Text("Arrive by").tag(DepartMode.arriveBy)
      }
      .pickerStyle(.segmented)
      if mode != .now {
        DatePicker("Time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
          .onChange(of: date) { _, _ in
            plan.departure = departure(for: mode)
            plan.clearResults()
          }
      }
    }
    .listRowSeparator(.hidden)
    .padding(.vertical, 2)
  }

  private func departure(for mode: DepartMode) -> PlanModel.Departure {
    switch mode {
    case .now: .now
    case .at: .at(date)
    case .arriveBy: .arriveBy(date)
    }
  }

  private func findRow(_ plan: PlanModel) -> some View {
    HStack(spacing: 10) {
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

      if let from = plan.from, let to = plan.to, plan.canSearch {
        let saved = model.settings.isSaved(from: from, to: to, vias: plan.storedVias)
        Button { model.settings.toggleSaved(from: from, to: to, vias: plan.storedVias) } label: {
          Image(systemName: saved ? "star.fill" : "star").font(.title3).foregroundStyle(saved ? Color.orange : .secondary).frame(width: 40, height: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(saved ? Text("Remove saved trip") : Text("Save this trip"))
      }
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
  }

  // MARK: Content

  @ViewBuilder private func content(_ plan: PlanModel) -> some View {
    switch plan.phase {
    case .idle:
      shortcuts(plan)
    case .searching:
      Section { HStack { ProgressView(); Text("Finding routes…").foregroundStyle(.secondary) } }
    case .failed(let message):
      Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
    case .done:
      results(plan)
    }
  }

  /// Trips kept with the star, right under the saved places so that they are one tap away.
  @ViewBuilder private var savedTrips: some View {
    let saved = model.settings.values.savedTrips
    if !saved.isEmpty {
      Section("Saved trips") {
        ForEach(saved) { trip in tripRow(trip, symbol: "star.fill", tint: .orange) }
          .onDelete { model.settings.values.savedTrips.remove(atOffsets: $0) }
          .onMove { model.settings.values.savedTrips.move(fromOffsets: $0, toOffset: $1) }
      }
    }
  }

  @ViewBuilder private func shortcuts(_ plan: PlanModel) -> some View {
    let saved = model.settings.values.savedTrips
    let recents = model.settings.values.recentTrips.filter { recent in
      !saved.contains { $0.matches(from: recent.from, to: recent.to, vias: recent.stops) }
    }
    if saved.isEmpty, recents.isEmpty {
      Section {
        Text("Choose where you are going. Journeys take live delays into account for buses that are reporting.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    if !recents.isEmpty {
      Section("Recent trips") {
        ForEach(showAllRecents ? recents : Array(recents.prefix(8))) { trip in tripRow(trip, symbol: "clock.arrow.circlepath", tint: .secondary) }
        if recents.count > 8 {
          Button(showAllRecents ? "Show fewer" : "Show all \(recents.count)") { withAnimation { showAllRecents.toggle() } }
            .font(.footnote)
        }
      }
    }
  }

  private func tripRow(_ trip: SavedTrip, symbol: String, tint: Color) -> some View {
    Button {
      let plan = model.plan
      plan.from = trip.from.choice
      plan.to = trip.to.choice
      plan.vias = trip.stops.map { PlanVia(place: $0.end.choice, dwellMinutes: $0.dwellMinutes) }
      plan.clearResults()
      model.location.start()
      Task { await model.searchJourneys() }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: symbol).foregroundStyle(tint).frame(width: 24)
        Text(trip.title).foregroundStyle(.primary).lineLimit(2)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private func results(_ plan: PlanModel) -> some View {
    if plan.results.isEmpty {
      Section {
        Label("No bus journey found. The stops may be too far apart, or no buses run in the next few hours.", systemImage: "bus")
          .foregroundStyle(.secondary)
        if model.settings.values.accessibleOnly || model.settings.values.maxTransfers < 3 {
          Button("Review trip options") { showOptions = true }
        }
      }
    } else {
      let sort = model.settings.values.journeySort
      let sorted = PlanModel.sorted(plan.results, by: sort)
      let highlights = PlanModel.highlights(plan.results)
      Section {
        if !plan.noEarlier {
          Button { Task { await model.loadEarlierJourneys() } } label: {
            HStack { Spacer(); if plan.isLoadingMore { ProgressView() }; Label("Earlier", systemImage: "arrow.up"); Spacer() }
          }
          .disabled(plan.isLoadingMore)
        }
        ForEach(sorted) { journey in
          NavigationLink(value: journey) { JourneyCard(journey: journey, highlights: highlights[journey.id] ?? []) }
        }
        if !plan.noLater {
          Button { Task { await model.loadLaterJourneys() } } label: {
            HStack { Spacer(); if plan.isLoadingMore { ProgressView() }; Label("Later", systemImage: "arrow.down"); Spacer() }
          }
          .disabled(plan.isLoadingMore)
        }
      } header: {
        HStack {
          Text("Routes")
          Spacer()
          Menu {
            Picker("Sort by", selection: Bindable(model.settings).values.journeySort) {
              Text("Departure").tag(JourneySort.departure)
              Text("Arrival").tag(JourneySort.arrival)
              Text("Fewest transfers").tag(JourneySort.fewestTransfers)
              Text("Least walking").tag(JourneySort.leastWalking)
            }
          } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down.circle").font(.footnote).textCase(nil)
          }
        }
      } footer: {
        Text("Walking times are estimated from straight-line distance. Times marked live use each bus's predicted arrival.")
      }
    }
  }
}

private struct ChipLabel: View {
  let symbol: String
  let text: String
  let filled: Bool

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.subheadline.weight(.medium))
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(filled ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
      .overlay(Capsule().strokeBorder(filled ? .clear : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
      .foregroundStyle(filled ? Color.accentColor : .secondary)
  }
}

// MARK: - Cards

struct JourneyCard: View {
  @Environment(AppModel.self) private var model
  let journey: Journey
  var highlights: [PlanModel.Highlight] = []

  var body: some View {
    let text = model.timeText()
    VStack(alignment: .leading, spacing: 8) {
      if !highlights.isEmpty {
        HStack(spacing: 6) {
          ForEach(Array(highlights.enumerated()), id: \.offset) { _, highlight in
            Text(label(highlight)).font(.caption2.weight(.bold)).foregroundStyle(.white)
              .padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor, in: Capsule())
          }
        }
      }
      HStack(alignment: .firstTextBaseline) {
        Text("\(text.clock(journey.departure)) → \(text.clock(journey.arrival))")
          .font(.headline).monospacedDigit()
        Spacer()
        Text(TimeText.duration(journey.duration)).font(.headline).foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
          if index > 0 {
            if journey.stopovers.contains(where: { $0.afterLeg == index - 1 }) {
              Image(systemName: "mappin.circle.fill").font(.caption).foregroundStyle(.purple)
            } else {
              Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
          }
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
      if !journey.stopovers.isEmpty {
        Text("Stops: \(journey.stopovers.map(\.place.name).joined(separator: ", "))").font(.caption).foregroundStyle(.purple)
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

  private func label(_ highlight: PlanModel.Highlight) -> String {
    switch highlight {
    case .fastest: String(localized: "Fastest")
    case .fewestTransfers: String(localized: "Fewest transfers")
    case .leastWalking: String(localized: "Least walking")
    }
  }
}

// MARK: - Detail

struct JourneyDetailView: View {
  @Environment(AppModel.self) private var model
  let journey: Journey
  @State private var reminder: ReminderState = .unknown

  enum ReminderState: Equatable {
    case unknown, off, on(Date), denied, tooLate
  }

  var body: some View {
    let summary = JourneySummary(text: model.timeText(), routeName: { model.route($0)?.shortName ?? $0 })
    List {
      Section { JourneySteps(journey: journey) }
      Section {
        Button { model.showOnMap(journey) } label: {
          Label("Show on map", systemImage: "map").font(.body.weight(.semibold))
        }
        reminderRow(summary)
      } footer: {
        Text("Walking times are estimated from straight-line distance. A reminder uses the times known now.")
      }
    }
    .navigationTitle("\(TimeText.duration(journey.duration))")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        ShareLink(item: summary.lines(for: journey, from: model.plan.from?.title ?? "", to: model.plan.to?.title ?? "").joined(separator: "\n")) {
          Image(systemName: "square.and.arrow.up")
        }
      }
    }
    .task { reminder = (await Reminders.isScheduled(journey)) ? .on(journey.departure) : .off }
  }

  @ViewBuilder private func reminderRow(_ summary: JourneySummary) -> some View {
    let lead = model.settings.values.reminderLeadMinutes
    switch reminder {
    case .on:
      Button {
        Reminders.cancel(journey)
        reminder = .off
      } label: {
        Label("Reminder set · tap to cancel", systemImage: "bell.fill").foregroundStyle(.orange)
      }
    case .denied:
      Label("Notifications are turned off for Headway. You can turn them on in Settings.", systemImage: "bell.slash").foregroundStyle(.secondary).font(.footnote)
    case .tooLate:
      Label("It is too late for a reminder: this journey starts very soon.", systemImage: "bell.slash").foregroundStyle(.secondary).font(.footnote)
    case .unknown, .off:
      Button {
        Task {
          switch await Reminders.schedule(journey, leadMinutes: lead, body: summary.reminder(for: journey)) {
          case .scheduled: reminder = .on(journey.departure)
          case .denied: reminder = .denied
          case .tooLate: reminder = .tooLate
          }
        }
      } label: {
        Label("Remind me \(lead) min before leaving", systemImage: "bell")
      }
    }
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
              habit(ride)
            }
          }
        }
        if let stay = journey.stopovers.first(where: { $0.afterLeg == index }) {
          StepRow(symbol: "mappin.circle.fill", tint: .purple) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Stay at \(stay.place.name)").font(.subheadline.weight(.semibold))
              Text("\(text.clock(stay.arrive))–\(text.clock(stay.leave)) · \(TimeText.duration(stay.duration))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  /// What this route is usually like at the stop where the rider boards.
  @ViewBuilder private func habit(_ ride: RideLeg) -> some View {
    if let match = model.reliability(route: ride.routeID, stop: ride.fromStop.stopID, at: ride.depart) {
      let late = Int((match.cell.lateShare * 100).rounded()), early = Int((match.cell.earlyShare * 100).rounded())
      if match.cell.lateShare >= 0.25 {
        Label("Often late here (\(late)%)", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
      } else if match.cell.earlyShare >= 0.2 {
        Label("Sometimes leaves early (\(early)%)", systemImage: "hare").font(.caption).foregroundStyle(.blue)
      }
    }
  }

  /// Time between arriving by one bus and the next bus leaving, for the transfer into `legs[index]`.
  private func buffer(before index: Int) -> TimeInterval? {
    guard case .ride(let next) = journey.legs[index] else { return nil }
    let previousEnd = journey.legs[index - 1].end
    // A stay on the way is not a connection: only rides since the last stay count.
    let from = (journey.stopovers.map(\.afterLeg).filter { $0 < index }.max() ?? -1) + 1
    guard from < index, journey.legs[from..<index].contains(where: { if case .ride = $0 { return true } else { return false } }) else { return nil }
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

// MARK: - Options

/// Walking speed, how far to walk, how many transfers, and accessibility: the same settings in the planner and in Settings.
struct PlanOptionsForm: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section("Walking") {
        Picker("Walking speed", selection: $settings.values.walkSpeed) {
          Text("Slow").tag(WalkSpeed.slow)
          Text("Normal").tag(WalkSpeed.normal)
          Text("Fast").tag(WalkSpeed.fast)
        }
        Picker("Farthest walk to a stop", selection: $settings.values.maxWalkMeters) {
          ForEach([400, 800, 1200, 2000], id: \.self) { Text(TimeText.walking(Double($0))).tag($0) }
        }
      }
      Section("Transfers") {
        Picker("Most transfers", selection: $settings.values.maxTransfers) {
          Text("Direct only").tag(0)
          Text("1").tag(1)
          Text("2").tag(2)
          Text("3").tag(3)
        }
        Picker("Time to change buses", selection: $settings.values.transferSeconds) {
          Text("1 minute").tag(60)
          Text("3 minutes").tag(180)
          Text("5 minutes").tag(300)
        }
      }
      Section {
        Toggle("Wheelchair accessible only", isOn: $settings.values.accessibleOnly)
      } footer: {
        Text("Leaves out trips and stops that the city marks as not accessible. Where the city gives no information, they are kept.")
      }
      Section("Reminders") {
        Picker("Remind me before leaving", selection: $settings.values.reminderLeadMinutes) {
          ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
        }
      }
    }
  }
}

/// The options as a sheet from the planner. Closing it plans again if results are showing.
struct PlanOptionsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      PlanOptionsForm()
        .navigationTitle("Trip options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done") {
              dismiss()
              if model.plan.canSearch, model.plan.phase == .done { Task { await model.searchJourneys() } }
            }
          }
        }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Saved places and saved trips: see, rename and remove them.
struct SavedPlacesView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    List {
      Section("Saved places") {
        if settings.values.savedPlaces.isEmpty {
          Text("Long-press a place in the trip planner, or a search result, to save it as Home, Work or a favourite place.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(settings.values.savedPlaces) { place in
          NavigationLink {
            SavedPlaceEditor(placeID: place.id)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: place.kind.symbol).foregroundStyle(Color.accentColor).frame(width: 24)
              VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                if place.stopID != nil { Text("Bus stop").font(.caption).foregroundStyle(.secondary) }
              }
            }
          }
        }
        .onDelete { settings.values.savedPlaces.remove(atOffsets: $0) }
      }
      Section("Saved trips") {
        if settings.values.savedTrips.isEmpty {
          Text("Tap the star next to Find routes to keep a trip.").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(settings.values.savedTrips) { Text($0.title) }
          .onDelete { settings.values.savedTrips.remove(atOffsets: $0) }
          .onMove { settings.values.savedTrips.move(fromOffsets: $0, toOffset: $1) }
      }
      Section {
        Button("Clear recent trips", role: .destructive) { settings.values.recentTrips = [] }
          .disabled(settings.values.recentTrips.isEmpty)
      }
    }
    .navigationTitle("Saved places")
    .toolbar { EditButton() }
  }
}

/// Change a saved place: its name, what it is, and where it is.
struct SavedPlaceEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let placeID: String
  @State private var choosingLocation = false

  var body: some View {
    if let place = model.settings.values.savedPlaces.first(where: { $0.id == placeID }) {
      Form {
        Section {
          TextField("Name", text: Binding(get: { place.name }, set: { model.settings.update(place: placeID, name: $0) }))
          Picker("Kind", selection: Binding(get: { place.kind }, set: { model.settings.update(place: placeID, kind: $0) })) {
            Label("Home", systemImage: PlaceKind.home.symbol).tag(PlaceKind.home)
            Label("Work", systemImage: PlaceKind.work.symbol).tag(PlaceKind.work)
            Label("Place", systemImage: PlaceKind.other.symbol).tag(PlaceKind.other)
          }
        } footer: {
          Text("There is one Home and one Work. Choosing one that is already taken turns the other into an ordinary place.")
        }
        Section {
          Button { choosingLocation = true } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text("Change location")
              Text(place.stopID == nil ? String(localized: "A point on the map") : String(localized: "A bus stop"))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        } footer: {
          Text("A saved bus stop also lets the planner use the stops next to it, such as the one across the street.")
        }
        Section {
          Button("Delete place", role: .destructive) {
            model.settings.removePlace(placeID)
            dismiss()
          }
        }
      }
      .navigationTitle(place.name)
      .navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $choosingLocation) {
        PlacePicker(allowsMyLocation: false, title: "Location") { choice in
          if case .point(let point) = choice { model.settings.update(place: placeID, point: point) }
        }
      }
    } else {
      ContentUnavailableView("Place not found", systemImage: "mappin.slash")
    }
  }
}
