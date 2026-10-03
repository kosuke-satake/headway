import Foundation

/// A GTFS CSV file scanned straight from its UTF-8 bytes.
///
/// `stop_times.txt` has about 600,000 rows, so rows are exposed as views over the original buffer instead of being
/// turned into arrays of strings up front.
public struct CSVFile {
  /// Column name to column index.
  public let header: [String: Int]
  private let data: Data
  private let bodyStart: Int

  public init(data: Data) {
    self.data = data
    var start = 0
    // Skip a UTF-8 byte order mark.
    if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { start = 3 }
    var names: [String: Int] = [:]
    var next = start
    data.withUnsafeBytes { raw in
      var fields: [Range<Int>] = []
      next = CSVFile.scanRow(raw, from: start, fields: &fields)
      for (index, range) in fields.enumerated() {
        let name = CSVRow.decode(raw, range)
        names[name.trimmingCharacters(in: .whitespaces)] = index
      }
    }
    self.header = names
    self.bodyStart = next
  }

  /// Calls `body` for every non-empty data row. The row is only valid during the call.
  public func forEachRow(_ body: (CSVRow) -> Void) {
    data.withUnsafeBytes { raw in
      var position = bodyStart
      var fields: [Range<Int>] = []
      fields.reserveCapacity(header.count)
      while position < raw.count {
        fields.removeAll(keepingCapacity: true)
        position = CSVFile.scanRow(raw, from: position, fields: &fields)
        if fields.count == 1, fields[0].isEmpty { continue }  // blank line
        body(CSVRow(raw: raw, fields: fields))
      }
    }
  }

  /// Scans one record starting at `from`, appends its field ranges, and returns the index after its line ending.
  private static func scanRow(_ raw: UnsafeRawBufferPointer, from: Int, fields: inout [Range<Int>]) -> Int {
    let end = raw.count
    var i = from
    while true {
      if i < end, raw[i] == UInt8(ascii: "\"") {
        // Quoted field: runs to the closing quote; a doubled quote is an escaped quote.
        let begin = i
        i += 1
        while i < end {
          if raw[i] == UInt8(ascii: "\"") {
            if i + 1 < end, raw[i + 1] == UInt8(ascii: "\"") { i += 2; continue }
            i += 1
            break
          }
          i += 1
        }
        fields.append(begin..<i)
      } else {
        let begin = i
        while i < end, raw[i] != UInt8(ascii: ","), raw[i] != UInt8(ascii: "\n"), raw[i] != UInt8(ascii: "\r") { i += 1 }
        fields.append(begin..<i)
      }
      if i >= end { return end }
      let byte = raw[i]
      if byte == UInt8(ascii: ",") { i += 1; continue }
      // End of record: consume "\r\n", "\n" or "\r".
      if byte == UInt8(ascii: "\r"), i + 1 < end, raw[i + 1] == UInt8(ascii: "\n") { return i + 2 }
      return i + 1
    }
  }
}

/// One CSV record, valid only inside `CSVFile.forEachRow`.
public struct CSVRow {
  fileprivate let raw: UnsafeRawBufferPointer
  fileprivate let fields: [Range<Int>]

  /// The field at `index`, or an empty string if the row is shorter.
  public func string(_ index: Int?) -> String {
    guard let index, index < fields.count else { return "" }
    return CSVRow.decode(raw, fields[index])
  }

  public func int(_ index: Int?) -> Int? {
    guard let index, index < fields.count else { return nil }
    let range = fields[index]
    guard !range.isEmpty else { return nil }
    var value = 0
    var negative = false
    var i = range.lowerBound
    if raw[i] == UInt8(ascii: "-") { negative = true; i += 1 }
    guard i < range.upperBound else { return nil }
    while i < range.upperBound {
      let digit = Int(raw[i]) - 48
      guard digit >= 0, digit <= 9 else { return nil }
      value = value * 10 + digit
      i += 1
    }
    return negative ? -value : value
  }

  public func double(_ index: Int?) -> Double? {
    guard let index, index < fields.count, !fields[index].isEmpty else { return nil }
    return Double(CSVRow.decode(raw, fields[index]))
  }

  fileprivate static func decode(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> String {
    guard !range.isEmpty else { return "" }
    var slice = UnsafeRawBufferPointer(rebasing: raw[range])
    var unescape = false
    if slice.first == UInt8(ascii: "\""), slice.count >= 2, slice.last == UInt8(ascii: "\"") {
      slice = UnsafeRawBufferPointer(rebasing: slice[1..<(slice.count - 1)])
      unescape = true
    }
    let text = String(decoding: slice, as: UTF8.self)
    return unescape ? text.replacingOccurrences(of: "\"\"", with: "\"") : text
  }
}
