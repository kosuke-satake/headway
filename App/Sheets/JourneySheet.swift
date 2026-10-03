import HeadwayCore
import SwiftUI

/// The journey on the map, as a bottom sheet with its steps.
struct JourneySheet: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let journey = model.mapJourney {
      let text = model.timeText()
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text("\(text.clock(journey.departure)) → \(text.clock(journey.arrival))").font(.title3.weight(.semibold)).monospacedDigit()
              Text("\(TimeText.duration(journey.duration)) · \(journey.transfers == 0 ? String(localized: "Direct") : String(localized: "\(journey.transfers) transfers"))")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.clearJourney() } label: {
              Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
          }
          Button { model.mode = .plan } label: {
            Label("Back to results", systemImage: "chevron.backward").font(.footnote.weight(.medium))
          }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        Divider()
        ScrollView { JourneySteps(journey: journey).padding(.horizontal, 16) }
      }
    } else {
      ContentUnavailableView("No journey", systemImage: "arrow.triangle.turn.up.right.diamond")
    }
  }
}
