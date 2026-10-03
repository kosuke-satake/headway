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

  init(directory: URL) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd'T'HHmmssZ"
    let names = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
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
