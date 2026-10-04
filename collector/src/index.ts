/**
 * Records the City of Madison's GTFS-Realtime feeds around the clock, for free.
 *
 * Every minute a cron trigger looks at the vehicle feed three times, and at the trip-update and alert feeds every 5 and 10
 * minutes. A snapshot is stored only when it differs from the last one. The Mac pulls the snapshots with
 * `tools/pull_feeds.py` (which gzips them) and then asks for them to be deleted, so the database stays small (free D1
 * allows 500 MB).
 */

import { ensureSchema } from "./schema";

export interface Env {
  DB: D1Database;
  /** Secret. Without it the export routes refuse every request. */
  EXPORT_TOKEN?: string;
  /** Test hook: where the feeds live. Defaults to the city's server. */
  FEED_BASE?: string;
  /** Test hook: milliseconds to wait between the three looks at the vehicle feed. */
  LOOK_GAP_MS?: string;
}

export type Feed = "vehicles" | "trips" | "alerts";

const FEED_BASE = "https://metromap.cityofmadison.com/gtfsrt";
/**
 * Snapshots are stored as they come. Gzipping the 180 kB trip-update feed took about 15 ms of CPU, more than the free
 * plan's 10 ms a run, so the database holds more (about 60 MB a day) and keeps it for fewer days instead.
 */
const KEEP_DAYS = 6;

export default {
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(collect(env, controller.scheduledTime));
  },

  async fetch(request: Request, env: Env): Promise<Response> {
    return route(request, env);
  },
} satisfies ExportedHandler<Env>;

// MARK: Collecting

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** One run of the cron trigger. Exported for tests. */
export async function collect(env: Env, scheduledTime: number): Promise<void> {
  await ensureSchema(env);
  const minute = Math.floor(scheduledTime / 60_000);
  const gap = Number(env.LOOK_GAP_MS ?? 20_000);
  const slow: Feed[] = [];
  if (minute % 5 === 0) slow.push("trips");
  if (minute % 10 === 0) slow.push("alerts");

  const errors: string[] = [];
  const look = async (feed: Feed) => {
    try {
      await snapshot(env, feed);
    } catch (error) {
      errors.push(`${feed}: ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  // The slow feeds go in parallel with the first look at the vehicles.
  await Promise.all([look("vehicles"), ...slow.map(look)]);
  for (let index = 1; index < 3; index++) {
    await sleep(gap);
    await look("vehicles");
  }

  const statements = [
    env.DB.prepare("INSERT INTO state (key, value) VALUES ('last_run', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(
      String(Date.now()),
    ),
  ];
  if (errors.length > 0) {
    statements.push(
      env.DB.prepare("INSERT INTO state (key, value) VALUES ('last_error', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(
        `${new Date().toISOString()} ${errors.join("; ")}`,
      ),
    );
  }
  await env.DB.batch(statements);

  // Once an hour, forget what is old. This is a safety net for when the Mac has not pulled for a long time.
  if (minute % 60 === 7) {
    await env.DB.prepare("DELETE FROM snapshots WHERE ts < ?").bind(Date.now() - KEEP_DAYS * 86_400_000).run();
  }
}

/** Fetches a feed and stores it unless it is the same as the last one. Returns true when something was stored. */
export async function snapshot(env: Env, feed: Feed): Promise<boolean> {
  const response = await fetch(`${env.FEED_BASE ?? FEED_BASE}/${feed}`, { headers: { "User-Agent": "headway-collector/0.1" } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  // The city publishes an empty file while it rebuilds the feed; there is nothing to keep in that.
  if (bytes.length < 20) throw new Error(`only ${bytes.length} bytes`);
  const ts = Date.now();
  const hash = await sha256(bytes);

  const last = await env.DB.prepare("SELECT value FROM state WHERE key = ?").bind(`hash:${feed}`).first<{ value: string }>();
  if (last?.value === hash) return false;

  await env.DB.batch([
    env.DB.prepare("INSERT INTO snapshots (feed, ts, hash, encoding, bytes, payload) VALUES (?, ?, ?, ?, ?, ?)").bind(
      feed, ts, hash, "raw", bytes.length, bytes,
    ),
    env.DB.prepare("INSERT INTO state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(
      `hash:${feed}`, hash,
    ),
  ]);
  return true;
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

// MARK: Export

/** Compares two secrets without leaking, through timing, how much of them matched. */
async function sameSecret(given: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(a), right = new Uint8Array(b);
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index];
  return difference === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/** The HTTP side. Exported for tests. */
export async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/") return new Response("headway-collector\n", { headers: { "Content-Type": "text/plain" } });

  if (!env.EXPORT_TOKEN) return json({ error: "EXPORT_TOKEN is not set" }, 503);
  await ensureSchema(env);
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ") || !(await sameSecret(header.slice(7), env.EXPORT_TOKEN))) {
    return json({ error: "unauthorized" }, 401);
  }

  if (url.pathname === "/status" && request.method === "GET") {
    const rows = await env.DB.prepare(
      "SELECT feed, COUNT(*) AS snapshots, SUM(bytes) AS bytes, MIN(ts) AS first, MAX(ts) AS last FROM snapshots GROUP BY feed",
    ).all();
    const state = await env.DB.prepare("SELECT key, value FROM state WHERE key IN ('last_run', 'last_error')").all<{ key: string; value: string }>();
    const facts = Object.fromEntries(state.results.map((row) => [row.key, row.value]));
    return json({ feeds: rows.results, lastRun: facts.last_run ? Number(facts.last_run) : null, lastError: facts.last_error ?? null });
  }

  if (url.pathname === "/list" && request.method === "GET") {
    const after = Number(url.searchParams.get("after") ?? 0) || 0;
    const limit = Math.min(500, Math.max(1, Number(url.searchParams.get("limit") ?? 200) || 200));
    const rows = await env.DB.prepare("SELECT id, feed, ts, encoding, bytes FROM snapshots WHERE id > ? ORDER BY id LIMIT ?")
      .bind(after, limit)
      .all();
    return json({ items: rows.results });
  }

  const match = url.pathname.match(/^\/snapshot\/(\d+)$/);
  if (match && request.method === "GET") {
    const row = await env.DB.prepare("SELECT feed, ts, encoding, payload FROM snapshots WHERE id = ?")
      .bind(Number(match[1]))
      .first<{ feed: string; ts: number; encoding: string; payload: ArrayBuffer | number[] }>();
    if (!row) return json({ error: "not found" }, 404);
    // D1 hands a BLOB back as an array of byte values or as an ArrayBuffer, depending on the runtime.
    const body = new Uint8Array(row.payload);
    return new Response(body, {
      headers: {
        "Content-Type": "application/octet-stream",
        "X-Feed": row.feed,
        "X-Timestamp": String(row.ts),
        "X-Encoding": row.encoding,
      },
    });
  }

  if (url.pathname === "/ack" && request.method === "POST") {
    const upto = Number(url.searchParams.get("upto") ?? 0);
    if (!Number.isInteger(upto) || upto <= 0) return json({ error: "upto must be a positive integer" }, 400);
    const result = await env.DB.prepare("DELETE FROM snapshots WHERE id <= ?").bind(upto).run();
    return json({ deleted: result.meta.changes });
  }

  return json({ error: "not found" }, 404);
}
