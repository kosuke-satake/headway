import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ObservationRow {
  let day: Int  // service date as yyyymmdd
  let trip: String
  let route: String
  let stop: String
  let sequence: Int
  let dayType: Int  // of the calendar date of the scheduled time
  let hour: Int  // local hour of the scheduled time
  let scheduled: Int  // epoch seconds
  let delay: Int  // seconds, positive when late
}

/// Every arrival observation ever made, in one SQLite file, so a new day's recording can be added without redoing
/// the old ones.
final class ObservationStore {
  private var db: OpaquePointer?

  init(path: String) throws {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError.open(path) }
    try exec("""
      CREATE TABLE IF NOT EXISTS obs (
        day INTEGER, trip TEXT, route TEXT, stop TEXT, seq INTEGER, dt INTEGER, hour INTEGER, sched INTEGER, delay INTEGER);
      CREATE INDEX IF NOT EXISTS obs_route ON obs (route, dt, hour);
      CREATE INDEX IF NOT EXISTS obs_stop ON obs (route, stop, dt, hour);
      CREATE INDEX IF NOT EXISTS obs_day ON obs (day);
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
      """)
  }

  deinit { sqlite3_close(db) }

  enum StoreError: Error { case open(String), sql(String) }

  func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(error)
      throw StoreError.sql(message)
    }
  }

  func meta(_ key: String) -> String? {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil)
    sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
  }

  func setMeta(_ key: String, _ value: String) throws {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", -1, &statement, nil)
    sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sql("meta") }
  }

  /// Replaces everything observed for one service day.
  func replace(day: Int, with rows: [ObservationRow]) throws {
    try exec("BEGIN; DELETE FROM obs WHERE day = \(day);")
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    sqlite3_prepare_v2(db, "INSERT INTO obs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil)
    for row in rows {
      sqlite3_bind_int(statement, 1, Int32(row.day))
      sqlite3_bind_text(statement, 2, row.trip, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(statement, 3, row.route, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(statement, 4, row.stop, -1, SQLITE_TRANSIENT)
      sqlite3_bind_int(statement, 5, Int32(row.sequence))
      sqlite3_bind_int(statement, 6, Int32(row.dayType))
      sqlite3_bind_int(statement, 7, Int32(row.hour))
      sqlite3_bind_int64(statement, 8, Int64(row.scheduled))
      sqlite3_bind_int(statement, 9, Int32(row.delay))
      guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sql("insert") }
      sqlite3_reset(statement)
    }
    try exec("COMMIT;")
  }

  /// Runs `sql` and calls `body` for each row with its columns read as text, integers or doubles by `columns`.
  func rows(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.sql(sql) }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
  }

  static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }

  static func int(_ statement: OpaquePointer, _ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
}
