import SwiftUI

struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack(alignment: .top) {
      MapContainer()
        .ignoresSafeArea()
      VStack(spacing: 8) {
        StatusPill()
        if case .failed(let message) = model.phase {
          FailureBanner(message: message)
        }
      }
      .padding(.top, 8)
      .padding(.horizontal, 16)
    }
  }
}

/// One line that says whether the buses on the map are live.
private struct StatusPill: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 8) {
        Circle()
          .fill(color(at: context.date))
          .frame(width: 8, height: 8)
        Text(text(at: context.date))
          .font(.footnote.weight(.medium))
          .monospacedDigit()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.regularMaterial, in: Capsule())
      .accessibilityElement(children: .combine)
    }
  }

  private func age(at now: Date) -> TimeInterval? {
    model.lastLiveUpdate.map { now.timeIntervalSince($0) }
  }

  private func color(at now: Date) -> Color {
    guard let age = age(at: now) else { return .gray }
    if model.liveFailing || age > 30 { return .orange }
    return .green
  }

  private func text(at now: Date) -> String {
    guard let age = age(at: now) else { return String(localized: "Connecting…") }
    let seconds = Int(age)
    if model.liveFailing || seconds > 30 {
      return String(localized: "No live data · last update \(seconds) s ago")
    }
    return String(localized: "Live · \(model.vehicles.count) buses · \(seconds) s ago")
  }
}

private struct FailureBanner: View {
  @Environment(AppModel.self) private var model
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("The timetable could not be loaded")
        .font(.footnote.weight(.semibold))
      Text(message).font(.caption).foregroundStyle(.secondary)
      Button("Try again") { Task { await model.retry() } }
        .font(.footnote.weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}
