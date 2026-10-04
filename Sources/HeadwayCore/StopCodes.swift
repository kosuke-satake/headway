import Foundation

/// Finds the stop codes an alert's text talks about ("Stop 7253 and Stop7351 closed", "Brooks St Stop #0269").
///
/// The feed's alerts name routes, not stops, even when the text says a stop is closed, so the codes are read out of the
/// words. Only numbers that follow the word "stop" count, so that dates and years are not mistaken for codes.
public enum StopCodes {
  private static let pattern = try! NSRegularExpression(
    pattern: #"\bstops?\b\s*#?\s*(\d{3,5}(?:\s*(?:,|and|&)\s*(?:stops?\s*)?#?\d{3,5})*)"#, options: [.caseInsensitive])
  private static let number = try! NSRegularExpression(pattern: #"\d{3,5}"#)

  /// Codes in the order they appear, without repeats. A code keeps its leading zeros.
  public static func find(in text: String) -> [String] {
    let whole = NSRange(text.startIndex..., in: text)
    var result: [String] = []
    for match in pattern.matches(in: text, range: whole) {
      guard let range = Range(match.range(at: 1), in: text) else { continue }
      let list = String(text[range])
      for hit in number.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
        guard let codeRange = Range(hit.range, in: list) else { continue }
        let code = String(list[codeRange])
        if !result.contains(code) { result.append(code) }
      }
    }
    return result
  }
}
