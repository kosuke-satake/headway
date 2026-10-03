import UIKit

enum Haptics {
  @MainActor static func selection(enabled: Bool) {
    guard enabled else { return }
    UISelectionFeedbackGenerator().selectionChanged()
  }
}
