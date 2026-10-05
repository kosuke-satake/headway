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

  /// "10 min", "1 h", "1 h 30 min".
  static func minutesLabel(_ minutes: Int) -> String {
    if minutes < 60 { return String(localized: "\(minutes) min") }
    return minutes % 60 == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(minutes % 60) min")
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

extension TimeText {
  /// "28 min" or "1 h 5 min".
  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    if minutes < 60 { return String(localized: "\(minutes) min") }
    let hours = minutes / 60, rest = minutes % 60
    return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest) min")
  }

  /// "230 m" below a kilometre, otherwise "1.4 km" (or the locale's units).
  static func walking(_ meters: Double) -> String { distance(meters) }
}

extension TimeText {
  /// "3–6 min" for a bus expected between `earliest` and `latest`, or `nil` when the range is no wider than a minute
  /// (a range that narrow adds nothing to the single number).
  static func minuteRange(earliest: Date, latest: Date, now: Date) -> String? {
    let low = max(0, Int((earliest.timeIntervalSince(now) / 60).rounded(.down)))
    let high = max(0, Int((latest.timeIntervalSince(now) / 60).rounded(.up)))
    guard high - low >= 2 else { return nil }
    return String(localized: "\(low)–\(high) min")
  }

  func clockRange(earliest: Date, latest: Date) -> String? {
    let a = clock(earliest), b = clock(latest)
    return a == b ? nil : "\(a)–\(b)"
  }
}

/// Which way buses go at a stop, from the feed's `cardinal_direction` (the bearing the stop faces).
enum Compass {
  /// "Southbound" for 180 degrees (to the nearest quarter).
  static func bound(_ degrees: Int?) -> String? {
    guard let degrees else { return nil }
    switch ((degrees % 360 + 360) % 360 + 45) / 90 % 4 {
    case 0: return String(localized: "Northbound")
    case 1: return String(localized: "Eastbound")
    case 2: return String(localized: "Southbound")
    default: return String(localized: "Westbound")
    }
  }

  /// An arrow pointing the same way.
  static func symbol(_ degrees: Int?) -> String {
    guard let degrees else { return "mappin" }
    switch ((degrees % 360 + 360) % 360 + 45) / 90 % 4 {
    case 0: return "arrow.up"
    case 1: return "arrow.right"
    case 2: return "arrow.down"
    default: return "arrow.left"
    }
  }
}
