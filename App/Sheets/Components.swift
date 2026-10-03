import HeadwayCore
import SwiftUI

/// The route's name on its colour, like the sign on the front of the bus.
struct RouteBadge: View {
  @Environment(AppModel.self) private var model
  let routeID: String
  var compact = false

  var body: some View {
    let look = style()
    Text(model.route(routeID)?.shortName ?? routeID)
      .font((compact ? Font.caption : Font.subheadline).weight(.bold))
      .foregroundStyle(look.text)
      .padding(.horizontal, compact ? 6 : 9)
      .frame(minWidth: compact ? 24 : 34, minHeight: compact ? 20 : 28)
      .background(look.fill, in: RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
      .accessibilityLabel(Text("Route \(model.route(routeID)?.shortName ?? routeID)"))
  }

  private func style() -> (fill: Color, text: Color) {
    guard let route = model.route(routeID) else { return (.gray, .white) }
    let routes = model.orderedRoutes
    let palette = model.settings.values.routePalette
    // The quiet palette greys map lines; badges keep the agency colour so that routes stay recognisable.
    let fill = RouteColors.fill(for: route, palette: palette == .quiet ? .agency : palette, among: routes)
    return (Color(fill), Color(RouteColors.text(on: fill)))
  }
}

/// A small dot-and-label that says whether a time is live or only from the timetable.
struct LiveStatus: View {
  let arrival: Arrival
  let showDelay: Bool

  var body: some View {
    HStack(spacing: 4) {
      if arrival.status == .live {
        Image(systemName: "dot.radiowaves.left.and.right")
          .foregroundStyle(.green)
          .symbolRenderingMode(.hierarchical)
        Text(liveText).foregroundStyle(delayColor)
      } else {
        Image(systemName: "clock").foregroundStyle(.secondary)
        Text("Scheduled").foregroundStyle(.secondary)
      }
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
  }

  private var liveText: String {
    if showDelay, let text = TimeText.delay(arrival.delay) { return text }
    return String(localized: "Live")
  }

  private var delayColor: Color {
    guard showDelay, let delay = arrival.delay else { return .secondary }
    if delay > 300 { return .red }
    if delay > 90 { return .orange }
    return .secondary
  }
}

struct CircleButton: View {
  let systemName: String
  let label: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 17, weight: .medium))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .background(.regularMaterial, in: Circle())
    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    .accessibilityLabel(label)
  }
}
