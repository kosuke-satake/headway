import SwiftUI

struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  /// Height of the stop and bus sheets in their resting position.
  private static let detailHeight: CGFloat = 320
  /// The smallest position of the journey sheet: just its header, so the map is nearly free and the sheet is still
  /// there to pull back up.
  private static let peekHeight: CGFloat = 128

  var body: some View {
    @Bindable var model = model
    ZStack(alignment: .top) {
      MapContainer(bottomInset: model.sheet?.isDetail == true ? (model.sheet == .journey ? Self.peekHeight : Self.detailHeight) : 0)
        .ignoresSafeArea()
        .accessibilityHidden(model.mode != .map)
      if model.mode == .map {
        VStack(spacing: 8) {
          StatusPill()
          if model.focus.isActive { FocusChip() }
          if case .failed(let message) = model.phase { FailureBanner(message: message) }
        }
        .padding(.top, 8)
        .padding(.horizontal, 64)

        MenuButton()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 2)
          .padding(.leading, 12)

        Controls()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.top, 54)
          .padding(.trailing, 12)

        // A journey stays on the map after its sheet is gone; this is the way back to it.
        if model.mapJourney != nil, model.sheet == nil {
          JourneyBar()
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
      }
      if model.mode == .info {
        InfoView().background(Color(.systemGroupedBackground).ignoresSafeArea())
      }
      if model.mode == .plan {
        PlanView().background(Color(.systemGroupedBackground).ignoresSafeArea())
      }
      MenuDrawer()
    }
    .sheet(item: $model.sheet) { sheet in
      switch sheet {
      case .stop(let id):
        StopSheet(stopID: id).modifier(DetailSheetStyle(height: Self.detailHeight))
      case .bus(let id):
        BusSheet(vehicleID: id).modifier(DetailSheetStyle(height: Self.detailHeight))
      case .journey:
        JourneySheet().modifier(DetailSheetStyle(height: Self.detailHeight, peek: Self.peekHeight))
      case .settings:
        // Half height with the map still usable, so a change (colours, marker size) can be watched on the map.
        SettingsView()
          .presentationDetents([.medium, .large])
          .presentationBackgroundInteraction(.enabled(upThrough: .medium))
          .presentationBackground(Color(.systemGroupedBackground))
      case .routes:
        RoutesSheet().presentationDetents([.medium, .large])
      case .search:
        SearchSheet().presentationDetents([.medium, .large])
      }
    }
    .confirmationDialog(
      model.droppedPin?.name ?? "", isPresented: Binding(get: { model.droppedPin != nil }, set: { if !$0 { model.droppedPin = nil } }),
      titleVisibility: .visible
    ) {
      Button("Directions to here") {
        if let pin = model.droppedPin { model.startDirections(to: pin) }
      }
      Button("Directions from here") {
        if let pin = model.droppedPin { model.startDirections(from: pin) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .preferredColorScheme(colorScheme)
    .onChange(of: scenePhase) { _, phase in
      model.setActive(phase == .active)
      if phase == .background { WatchBackground.schedule(enabled: model.settings.values.watchEnabled && !model.settings.values.watchedRoutes.isEmpty) }
    }
  }

  private var colorScheme: ColorScheme? {
    switch model.settings.values.appearance {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

/// A bottom sheet that leaves the map usable above it.
private struct DetailSheetStyle: ViewModifier {
  let height: CGFloat
  /// When set, the sheet can be lowered to this height but not swiped away.
  var peek: CGFloat?

  func body(content: Content) -> some View {
    content
      .presentationDetents(peek.map { [.height($0), .height(height), .large] } ?? [.height(height), .large])
      .interactiveDismissDisabled(peek != nil)
      .presentationBackgroundInteraction(.enabled(upThrough: .height(height)))
      .presentationDragIndicator(.visible)
      .presentationContentInteraction(.scrolls)
      .presentationBackground(Color(.systemBackground))
  }
}

private struct Controls: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 10) {
      CircleButton(systemName: "magnifyingglass", label: "Find a stop") { model.sheet = .search }
      CircleButton(systemName: "line.3.horizontal.decrease", label: "Routes") { model.sheet = .routes }
      CircleButton(systemName: model.location.isAuthorized ? "location.fill" : "location", label: "My location") {
        model.locateMe()
      }
    }
  }
}

/// One line that says how current the buses on the map are. "Live" is only true to a point: positions are about
/// half a minute old when they arrive, so the line reports their age, not the time of the last request.
private struct StatusPill: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = model.positionAge(at: context.date)
      let late = model.liveFailing || (age ?? 0) > 90
      HStack(spacing: 8) {
        Circle().fill(model.lastLiveUpdate == nil ? Color.gray : (late ? Color.orange : Color.green)).frame(width: 8, height: 8)
        Text(text(age: age, late: late)).font(.footnote.weight(.medium)).monospacedDigit()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.regularMaterial, in: Capsule())
      .accessibilityElement(children: .combine)
    }
  }

  private func text(age: TimeInterval?, late: Bool) -> String {
    guard let age else { return String(localized: "Connecting…") }
    let seconds = Int(age.rounded())
    if model.liveFailing {
      return String(localized: "No connection · positions \(seconds) s old")
    }
    if late { return String(localized: "Delayed · positions \(seconds) s old") }
    return String(localized: "Live · \(model.vehicles.count) buses · positions \(seconds) s old")
  }
}

/// Says what the map is limited to, and lets the rider change the direction or go back to all routes.
/// The journey drawn on the map, as a bar at the bottom: tap it to bring the steps back, or close the journey.
private struct JourneyBar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let journey = model.mapJourney {
      let text = model.timeText()
      HStack(spacing: 12) {
        Button { model.sheet = .journey } label: {
          HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
              Text("\(text.clock(journey.departure)) → \(text.clock(journey.arrival))").font(.subheadline.weight(.semibold)).monospacedDigit()
              Text("Show journey steps").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Button { model.clearJourney() } label: {
          Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).frame(width: 36, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 4)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }
}

private struct FocusChip: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let focus = model.focus
    let single = focus.routes.count == 1 ? focus.routes.first : nil
    HStack(spacing: 8) {
      if let single { RouteBadge(routeID: single, compact: true) }
      Text(title(focus, single: single)).font(.footnote.weight(.medium)).lineLimit(1)
      if let single, focus.label == nil, model.variants(of: single).count > 1 {
        Menu {
          Button { model.setFocusDirection(nil) } label: { Label("Both directions", systemImage: focus.direction == nil ? "checkmark" : "arrow.left.arrow.right") }
          ForEach(model.variants(of: single), id: \.direction) { variant in
            Button { model.setFocusDirection(variant.direction) } label: {
              Label(model.directionTitle(route: single, direction: variant.direction), systemImage: focus.direction == variant.direction ? "checkmark" : model.directionSymbol(route: single, direction: variant.direction))
            }
          }
        } label: {
          Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(.blue)
        }
        .accessibilityLabel(Text("Change direction"))
      }
      Button { model.clearFocus() } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
      }
      .accessibilityLabel(Text("Show all routes"))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: Capsule())
  }

  private func title(_ focus: MapFocus, single: String?) -> String {
    if let label = focus.label { return label }
    guard let single else { return String(localized: "Showing only these routes") }
    if let direction = focus.direction { return model.directionTitle(route: single, direction: direction) }
    return String(localized: "Both directions")
  }
}

private struct FailureBanner: View {
  @Environment(AppModel.self) private var model
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("The timetable could not be loaded").font(.footnote.weight(.semibold))
      Text(message).font(.caption).foregroundStyle(.secondary)
      Button("Try again") { Task { await model.retry() } }.font(.footnote.weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}
