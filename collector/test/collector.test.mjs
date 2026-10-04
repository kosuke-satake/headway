// Runs the Worker in Cloudflare's own runtime (workerd, through `wrangler dev`) with a local database and a fake city.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { after, before, test } from "node:test";

const TOKEN = "test-token";
const auth = { Authorization: `Bearer ${TOKEN}` };

/** A fake city: serves whatever `feeds` holds, or an error. */
const feeds = { vehicles: Buffer.alloc(100, 1), trips: Buffer.alloc(60_000, 2), alerts: Buffer.alloc(50, 3) };
let failing = false;
let server, base, collector;
const cleanups = [];

/** Starts `wrangler dev` on a free port with a database of its own, and waits until it answers. */
async function startWorker(vars) {
  const port = await freePort();
  const persist = mkdtempSync(join(tmpdir(), "headway-collector-"));
  const args = ["wrangler", "dev", "--port", String(port), "--test-scheduled", "--persist-to", persist, "--log-level", "error"];
  for (const [name, value] of Object.entries(vars)) args.push("--var", `${name}:${value}`);
  const child = spawn("npx", args, { stdio: "ignore", env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, detached: true });
  cleanups.push(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {}
    rmSync(persist, { recursive: true, force: true });
  });
  const url = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 120; attempt++) {
    try {
      if ((await fetch(`${url}/`)).ok) return url;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error("wrangler dev did not start");
}

function freePort() {
  return new Promise((resolve) => {
    const probe = createServer().listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

before(async () => {
  server = createServer((request, response) => {
    const name = request.url.slice(1);
    if (failing || !(name in feeds)) {
      response.writeHead(failing ? 500 : 404).end();
      return;
    }
    response.writeHead(200, { "Content-Type": "application/x-protobuf" }).end(feeds[name]);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  collector = await startWorker({ EXPORT_TOKEN: TOKEN, FEED_BASE: base, LOOK_GAP_MS: "5" });
});

after(() => {
  for (const cleanup of cleanups) cleanup();
  server.close();
});

/** Runs the cron trigger as if at `minute` minutes past the hour. */
async function run(minute) {
  const time = Date.UTC(2026, 9, 4, 12, minute); // `wrangler dev` takes milliseconds
  const response = await fetch(`${collector}/cdn-cgi/handler/scheduled?cron=*+*+*+*+*&time=${time}`);
  assert.equal(response.status, 200, await response.text());
}

const get = (path, headers = auth) => fetch(`${collector}${path}`, { headers });
const send = (path, method, headers = auth) => fetch(`${collector}${path}`, { method, headers });

async function list() {
  return (await (await get("/list?limit=500")).json()).items;
}

test("the front page is public and says nothing", async () => {
  const response = await fetch(`${collector}/`);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "headway-collector\n");
});

test("the export needs the token", async () => {
  assert.equal((await get("/status", {})).status, 401);
  assert.equal((await get("/status", { Authorization: "Bearer wrong" })).status, 401);
  assert.equal((await get("/status", { Authorization: TOKEN })).status, 401);
  assert.equal((await get("/status")).status, 200);
});

test("without a configured token every export route refuses", async () => {
  const bare = await startWorker({});
  assert.equal((await fetch(`${bare}/status`, { headers: auth })).status, 503);
  assert.equal((await fetch(`${bare}/`)).status, 200);
});

test("a minute with nothing slow stores the vehicles once, however often they are looked at", async () => {
  await run(3);
  const items = await list();
  assert.deepEqual(items.map((item) => item.feed), ["vehicles"]);
  assert.equal(items[0].encoding, "raw");
});

test("trips every 5 minutes and alerts every 10; large snapshots are gzipped and come back intact", async () => {
  await run(5);
  assert.deepEqual((await list()).map((item) => item.feed), ["vehicles", "trips"]);
  await run(10);
  const items = await list();
  assert.deepEqual(items.map((item) => item.feed), ["vehicles", "trips", "alerts"]);

  const trips = items.find((item) => item.feed === "trips");
  assert.equal(trips.encoding, "gzip");
  assert.ok(trips.bytes < 1_000, "60 kB of one byte value should compress to almost nothing");
  const response = await get(`/snapshot/${trips.id}`);
  assert.equal(response.headers.get("X-Encoding"), "gzip");
  assert.equal(response.headers.get("X-Feed"), "trips");
  assert.ok(Number(response.headers.get("X-Timestamp")) > 0);
  assert.deepEqual(gunzipSync(Buffer.from(await response.arrayBuffer())), feeds.trips);

  const vehicles = items.find((item) => item.feed === "vehicles");
  const raw = await get(`/snapshot/${vehicles.id}`);
  assert.deepEqual(Buffer.from(await raw.arrayBuffer()), feeds.vehicles);
});

test("a changed feed is stored again", async () => {
  const before = (await list()).length;
  feeds.vehicles = Buffer.alloc(100, 9);
  await run(1);
  const items = await list();
  assert.equal(items.length, before + 1);
  assert.deepEqual(Buffer.from(await (await get(`/snapshot/${items.at(-1).id}`)).arrayBuffer()), feeds.vehicles);
});

test("the city being down or sending nothing is recorded, not stored", async () => {
  const before = (await list()).length;
  failing = true;
  await run(2);
  failing = false;
  feeds.vehicles = Buffer.alloc(5, 1);
  await run(2);
  assert.equal((await list()).length, before);
  const status = await (await get("/status")).json();
  assert.match(status.lastError, /vehicles: only 5 bytes/);
  assert.ok(status.lastRun > 0);
  feeds.vehicles = Buffer.alloc(100, 1);
});

test("list pages by id, and ack deletes what has been pulled", async () => {
  const items = await list();
  const page = await (await get(`/list?after=${items[1].id}&limit=1`)).json();
  assert.equal(page.items.length, 1);
  assert.equal(page.items[0].id, items[2].id);

  const deleted = await (await send(`/ack?upto=${items[1].id}`, "POST")).json();
  assert.equal(deleted.deleted, 2);
  assert.equal((await list()).length, items.length - 2);
  assert.equal((await get(`/snapshot/${items[0].id}`)).status, 404);
  assert.equal((await send("/ack?upto=abc", "POST")).status, 400);
  assert.equal((await send("/ack?upto=5", "GET")).status, 404);
});

test("tools/pull_feeds.py writes the files the analysis reads and empties the collector", async () => {
  feeds.trips = Buffer.alloc(60_000, 7); // all three feeds changed since the last look
  feeds.alerts = Buffer.alloc(50, 8);
  feeds.vehicles = Buffer.alloc(100, 6);
  await run(10);
  const waiting = (await list()).length;
  assert.ok(waiting >= 3);

  const root = mkdtempSync(join(tmpdir(), "headway-feeds-"));
  cleanups.push(() => rmSync(root, { recursive: true, force: true }));
  const script = new URL("../../tools/pull_feeds.py", import.meta.url).pathname;
  const output = execFileSync("python3", [script, "--root", root, "--no-static"], {
    env: { ...process.env, HEADWAY_COLLECTOR_URL: collector, HEADWAY_COLLECTOR_TOKEN: TOKEN },
  }).toString();
  assert.match(output, new RegExp(`pulled ${waiting} snapshots`));

  const days = readdirSync(root);
  assert.equal(days.length, 1);
  assert.match(days[0], /^\d{4}-\d{2}-\d{2}$/);
  const files = readdirSync(join(root, days[0]));
  assert.ok(files.every((name) => /^\d{8}T\d{6}[+-]\d{4}_(vehicles|trips|alerts)\.pb\.gz$/.test(name)), files.join(", "));
  const trips = files.find((name) => name.endsWith("_trips.pb.gz"));
  assert.ok(existsSync(join(root, days[0], trips)));
  const { gunzipSync: gunzip } = await import("node:zlib");
  const { readFileSync } = await import("node:fs");
  assert.deepEqual(gunzip(readFileSync(join(root, days[0], trips))), feeds.trips);

  assert.equal((await list()).length, 0, "the collector forgets what has been pulled");
});
