import Foundation
import HeadwayCore

struct RecordedFile {
  let url: URL
  let feed: RealtimeFeed
  let recordedAt: Date
}

/// The `<stamp>_<feed>.pb.gz` files written by `tools/record_feeds.py`.
struct Recordings {
  private let all: [RecordedFile]

  /// Day folders (`yyyy-MM-dd`) found under a recordings root, oldest first. A day folder passed directly counts as one.
  static func dayFolders(in directory: URL) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let days = entries.filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
    return days.isEmpty ? [directory] : days.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// The newest timetable zip under `directory` (a root or a day folder).
  static func latestSchedule(in directory: URL) -> URL? {
    for folder in dayFolders(in: directory).reversed() {
      let zip = folder.appendingPathComponent("mmt_gtfs.zip")
      if FileManager.default.fileExists(atPath: zip.path) { return zip }
    }
    return nil
  }

  init(directory: URL) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd'T'HHmmssZ"
    var names: [URL] = []
    for folder in Self.dayFolders(in: directory) {
      names += try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }
    var files: [RecordedFile] = []
    for url in names where url.lastPathComponent.hasSuffix(".pb.gz") {
      let parts = url.lastPathComponent.dropLast(".pb.gz".count).split(separator: "_")
      guard parts.count == 2, let feed = RealtimeFeed(rawValue: String(parts[1])),
        let date = formatter.date(from: String(parts[0]))
      else { continue }
      files.append(RecordedFile(url: url, feed: feed, recordedAt: date))
    }
    all = files.sorted { $0.recordedAt < $1.recordedAt }
  }

  func files(of feed: RealtimeFeed) -> [RecordedFile] { all.filter { $0.feed == feed } }
}

struct GzipError: Error {}

/// Decompresses a gzip stream written by Python's `gzip.compress` (no optional header fields).
func gunzip(_ data: Data) throws -> Data {
  guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8, data[3] == 0 else { throw GzipError() }
  let raw = data.subdata(in: 10..<(data.count - 8))
  return try (raw as NSData).decompressed(using: .zlib) as Data
}
