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
      VStack(spacing: 8) {
        StatusPill()
        if let focus = model.focusedRouteID { FocusChip(routeID: focus) }
        if case .failed(let message) = model.phase { FailureBanner(message: message) }
      }
      .padding(.top, 8)
      .padding(.horizontal, 16)

      Controls()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 54)
        .padding(.trailing, 12)
    }
    .sheet(item: $model.sheet) { sheet in
      switch sheet {
      case .stop(let id):
        StopSheet(stopID: id).modifier(DetailSheetStyle(height: Self.detailHeight))
      case .bus(let id):
        BusSheet(vehicleID: id).modifier(DetailSheetStyle(height: Self.detailHeight))
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
    .preferredColorScheme(colorScheme)
    .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
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
      CircleButton(systemName: "gearshape", label: "Settings") { model.sheet = .settings }
    }
  }
}

/// One line that says whether the buses on the map are live.
private struct StatusPill: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 8) {
        Circle().fill(color(at: context.date)).frame(width: 8, height: 8)
        Text(text(at: context.date)).font(.footnote.weight(.medium)).monospacedDigit()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.regularMaterial, in: Capsule())
      .accessibilityElement(children: .combine)
    }
  }

  private func age(at now: Date) -> TimeInterval? { model.lastLiveUpdate.map { now.timeIntervalSince($0) } }

  private func color(at now: Date) -> Color {
    guard let age = age(at: now) else { return .gray }
    let limit = Double(max(30, model.settings.values.updateInterval * 3))
    return model.liveFailing || age > limit ? .orange : .green
  }

  private func text(at now: Date) -> String {
    guard let age = age(at: now) else { return String(localized: "Connecting…") }
    let seconds = Int(age)
    let limit = max(30, model.settings.values.updateInterval * 3)
    if model.liveFailing || seconds > limit {
      return String(localized: "No live data · last update \(seconds) s ago")
    }
    return String(localized: "Live · \(model.vehicles.count) buses · \(seconds) s ago")
  }
}

private struct FocusChip: View {
  @Environment(AppModel.self) private var model
  let routeID: String

  var body: some View {
    HStack(spacing: 8) {
      RouteBadge(routeID: routeID, compact: true)
      Text("Showing only this route").font(.footnote.weight(.medium))
      Button { model.focusedRouteID = nil } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
      }
      .accessibilityLabel(Text("Show all routes"))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: Capsule())
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
