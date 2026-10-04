import SwiftUI

struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  /// Height of the stop and bus sheets in their resting position.
  private static let detailHeight: CGFloat = 320

  var body: some View {
    @Bindable var model = model
    ZStack(alignment: .top) {
      MapContainer(bottomInset: model.sheet?.isDetail == true ? Self.detailHeight : 0)
        .ignoresSafeArea()
        .accessibilityHidden(model.mode != .map)
      if model.mode == .map {
        VStack(spacing: 8) {
          StatusPill()
          if model.focus.isActive { FocusChip() }
          if !model.routeChoices.isEmpty { RouteChooser() }
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
      if !model.menuOpen, model.mode == .map || !model.planPushed {
        EdgeSwipeArea()
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
        // Dragged all the way down, the journey goes into the bar at the bottom of the map.
        JourneySheet().modifier(DetailSheetStyle(height: Self.detailHeight))
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

  func body(content: Content) -> some View {
    content
      .presentationDetents([.height(height), .large])
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
/// A thin strip along the left edge: swiping right from it opens the menu, like the hamburger button.
private struct EdgeSwipeArea: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Color.clear
      .frame(width: 16)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 10)
          .onEnded { value in
            if value.translation.width > 50, abs(value.translation.height) < value.translation.width {
              withAnimation(.snappy(duration: 0.28)) { model.menuOpen = true }
            }
          }
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .ignoresSafeArea()
      .accessibilityHidden(true)
  }
}

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
      // Swiping the bar up brings the steps back, like pulling up a sheet.
      .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < -30 { model.sheet = .journey } })
    }
  }
}

/// Which route did you mean? Shown when a tap lands on lines of several routes.
private struct RouteChooser: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Which route?").font(.footnote.weight(.semibold))
        Spacer()
        Button { model.routeChoices = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
          .accessibilityLabel(Text("Close"))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(model.routeChoices, id: \.self) { id in
            Button { model.focusRoute(id, direction: nil, fit: false) } label: {
              HStack(spacing: 6) {
                RouteBadge(routeID: id)
                let count = model.busCount(route: id, direction: nil)
                Text("\(count)").font(.footnote.weight(.medium)).foregroundStyle(count > 0 ? Color.green : Color.secondary).monospacedDigit()
                  .accessibilityLabel(Text("\(count) buses now"))
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

private struct FocusChip: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let focus = model.focus
    let single = focus.routes.count == 1 ? focus.routes.first : nil
    HStack(spacing: 8) {
      if let single { RouteBadge(routeID: single, compact: true) }
      VStack(alignment: .leading, spacing: 1) {
        Text(title(focus, single: single)).font(.footnote.weight(.medium)).lineLimit(1)
        if let single, focus.label == nil {
          let status = model.liveStatus(route: single, direction: focus.direction)
          Text(status.text).font(.caption2).foregroundStyle(status.isRunning ? Color.green : Color.secondary).lineLimit(2)
        }
        if focus.isAlert {
          // The dashes are the only sign of a detour on the map: say what they mean, and what is not known.
          Text("Dashed line: the route has an alert. The city does not publish which streets a detour uses; see the details link.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
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
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
