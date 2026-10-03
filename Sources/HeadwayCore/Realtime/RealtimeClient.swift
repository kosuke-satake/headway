import Foundation

public enum RealtimeFeed: String, CaseIterable, Sendable {
  case vehicles
  case trips
  case alerts
}

public enum RealtimeError: Error {
  case badStatus(Int)
}

/// Fetches and decodes the Madison Metro GTFS-Realtime feeds. No API key is needed.
public struct RealtimeClient: Sendable {
  public static let madisonBaseURL = URL(string: "https://metromap.cityofmadison.com/gtfsrt")!

  private let baseURL: URL
  private let session: URLSession

  public init(baseURL: URL = RealtimeClient.madisonBaseURL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
  }

  public func fetch(_ feed: RealtimeFeed) async throws -> RealtimeSnapshot {
    var request = URLRequest(url: baseURL.appendingPathComponent(feed.rawValue))
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw RealtimeError.badStatus(http.statusCode)
    }
    return try RealtimeDecoder.decode(data)
  }
}
