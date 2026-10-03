import Foundation
import HeadwayCore

/// Turns times and delays into the short strings shown to riders.
struct TimeText {
  let timeZone: TimeZone
  let clockFormat: ClockFormat
  let arrivalStyle: ArrivalStyle

  func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    switch clockFormat {
    case .system:
      formatter.locale = .autoupdatingCurrent
      formatter.setLocalizedDateFormatFromTemplate("jmm")
    case .twelveHour:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "h:mm a"
    case .twentyFourHour:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "HH:mm"
    }
    return formatter.string(from: date)
  }

  /// "Now", "4 min", or a clock time for buses far away or when the user prefers clock times.
  func arrival(_ arrival: Arrival, now: Date) -> String {
    let minutes = arrival.minutes(from: now)
    if arrivalStyle == .clock || minutes >= 60 { return clock(arrival.expected) }
    if minutes <= 0 { return String(localized: "Now") }
    return String(localized: "\(minutes) min")
  }

  /// A short, honest description of how the live time compares with the timetable.
  static func delay(_ seconds: Int?) -> String? {
    guard let seconds else { return nil }
    let minutes = Int((Double(abs(seconds)) / 60).rounded())
    if minutes < 1 { return String(localized: "On time") }
    return seconds > 0 ? String(localized: "\(minutes) min late") : String(localized: "\(minutes) min early")
  }

  static func distance(_ meters: Double) -> String {
    let measurement = Measurement(value: meters, unit: UnitLength.meters)
    let formatter = MeasurementFormatter()
    formatter.unitOptions = .naturalScale
    formatter.numberFormatter.maximumFractionDigits = meters < 1000 ? 0 : 1
    // Round small distances to 10 m so the number does not flicker.
    let rounded = meters < 1000 ? (meters / 10).rounded() * 10 : meters
    return formatter.string(from: Measurement(value: rounded, unit: UnitLength.meters).converted(to: measurement.unit))
  }
}

extension String {
  /// Feed headsigns are SHOUTED ("UW HOSPITAL VIA REGENT"). Short words (E, W, UW, VA) stay upper case, "via"
  /// becomes lower case, and the rest is capitalised.
  var prettyHeadsign: String {
    split(separator: " ").map { word -> String in
      let text = String(word)
      if text.uppercased() == "VIA" { return "via" }
      if text.count <= 3 { return text.uppercased() }
      return text.capitalized
    }.joined(separator: " ")
  }
}

extension TimeText {
  /// The hour column of a timetable: "8 PM" or "20".
  func hourLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    switch clockFormat {
    case .system:
      formatter.locale = .autoupdatingCurrent
      formatter.setLocalizedDateFormatFromTemplate("j")
    case .twelveHour:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "h a"
    case .twentyFourHour:
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "HH"
    }
    return formatter.string(from: date)
  }

  func minuteLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "mm"
    return formatter.string(from: date)
  }
}
