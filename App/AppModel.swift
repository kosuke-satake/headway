import Foundation
import HeadwayCore
import Observation

/// App-wide state: the static timetable and the live bus positions.
@MainActor @Observable
final class AppModel {
  enum Phase {
    case loading
    case ready
    case failed(String)
  }

  private(set) var phase: Phase = .loading
  private(set) var schedule: Schedule?
  private(set) var vehicles: [VehicleSample] = []
  /// When the feed last answered successfully.
  private(set) var lastLiveUpdate: Date?
  /// True when the most recent poll failed.
  private(set) var liveFailing = false

  private let client = RealtimeClient()
  private let pollInterval: Duration = .seconds(10)
  private var started = false

  static let scheduleURL = URL(string: "https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip")!

  func start() async {
    guard !started else { return }
    started = true
    // Live buses do not depend on the timetable, so start them first.
    async let live: Void = pollLoop()
    await loadSchedule()
    await live
  }

  func retry() async {
    phase = .loading
    await loadSchedule()
  }

  // MARK: Timetable

  private func loadSchedule() async {
    do {
      let url = try await cachedScheduleZip()
      let loaded = try await Task.detached(priority: .userInitiated) { try Schedule.load(zipAt: url) }.value
      schedule = loaded
      phase = .ready
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// The timetable zip in Application Support. It is downloaded once; a cached copy is used when offline.
  private func cachedScheduleZip() async throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let cached = directory.appendingPathComponent("mmt_gtfs.zip")
    let age = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      .map { Date().timeIntervalSince($0) }
    // Refresh at most once a day; a failed refresh falls back to the cached copy.
    if age == nil || age! > 86_400 {
      do {
        let (temporary, response) = try await URLSession.shared.download(from: Self.scheduleURL)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
          try? FileManager.default.removeItem(at: cached)
          try FileManager.default.moveItem(at: temporary, to: cached)
        }
      } catch {
        if age == nil { throw error }
      }
    }
    return cached
  }

  // MARK: Live positions

  private func pollLoop() async {
    while !Task.isCancelled {
      do {
        let snapshot = try await client.fetch(.vehicles)
        vehicles = snapshot.vehicles
        lastLiveUpdate = Date()
        liveFailing = false
      } catch {
        liveFailing = true
      }
      try? await Task.sleep(for: pollInterval)
    }
  }
}
