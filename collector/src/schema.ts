import type { Env } from "./index";

/**
 * One row per distinct snapshot of a feed. `payload` is the feed exactly as the city sent it (protobuf), gzipped when it
 * is large. Rows are deleted when the Mac has pulled them (see tools/pull_feeds.py) or after 14 days, whichever is first.
 *
 * `state` holds small facts: the hash of the last snapshot of each feed (to skip repeats), when the last run happened,
 * and the last error.
 */
const STATEMENTS = [
  `CREATE TABLE IF NOT EXISTS snapshots (
     id       INTEGER PRIMARY KEY AUTOINCREMENT,
     feed     TEXT    NOT NULL,
     ts       INTEGER NOT NULL,
     hash     TEXT    NOT NULL,
     encoding TEXT    NOT NULL,
     bytes    INTEGER NOT NULL,
     payload  BLOB    NOT NULL
   )`,
  `CREATE INDEX IF NOT EXISTS snapshots_ts ON snapshots (ts)`,
  `CREATE TABLE IF NOT EXISTS state (
     key   TEXT PRIMARY KEY,
     value TEXT NOT NULL
   )`,
];

let ready: Promise<unknown> | undefined;

/** Creates the tables on the first request of each isolate, so that there is no separate setup step. */
export function ensureSchema(env: Env): Promise<unknown> {
  ready ??= env.DB.batch(STATEMENTS.map((sql) => env.DB.prepare(sql))).catch((error) => {
    ready = undefined;
    throw error;
  });
  return ready;
}
