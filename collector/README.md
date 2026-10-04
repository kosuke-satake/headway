# Collector

Records the City of Madison's GTFS-Realtime feeds around the clock on Cloudflare's free plan, so that the punctuality
statistics (see `docs/data-sources.md`) do not depend on a Mac being awake.

```
city feeds ──every minute──> Worker ──> D1 (small database) <──pull──  Mac: tools/pull_feeds.py ──> data/feeds/
```

- A cron trigger runs every minute. Each run looks at the vehicle feed three times (20 s apart, because the city rebuilds
  it every 30 s) and at the trip-update and alert feeds every 5 and 10 minutes. A snapshot is stored only when it differs
  from the last one; large ones are gzipped.
- `tools/pull_feeds.py` fetches the snapshots, writes them in the layout `tools/record_feeds.py` uses (so `feedanalysis`
  needs no changes) and then asks the collector to delete them. The collector also deletes anything older than 14 days.
- Nothing here is public except the front page. Every other route needs the secret token (`EXPORT_TOKEN`).

## What it costs

Nothing, on the free plans. Checked against Cloudflare's documentation on 2026-10-04:

| Limit (free) | Value | This collector |
|---|---|---|
| Worker requests | 100,000 / day | about 1,440 cron runs plus the Mac's pulls (a few thousand) |
| CPU time per run | 10 ms (cron runs: 10 ms) | waiting for the city and the database is not CPU time; gzip of a 180 kB feed is the largest cost |
| Cron triggers | 5 per account | 1 |
| Cron run duration | 15 minutes | about 45 seconds |
| D1 rows written | 100,000 / day | about 15,000 (estimate: each snapshot touches its row, an index entry and a state row, and old rows are deleted) |
| D1 rows read | 5 million / day | a few thousand |
| D1 size | 500 MB per database, 5 GB total | about 14 MB a day of snapshots, so 14 days is about 200 MB |

When a daily limit is exceeded, Cloudflare's documentation says further operations fail with an error; it does not say you
are charged. Pages Functions count against the same Workers request allowance, so a Pages site that uses Functions shares
the 100,000 a day. The pages fetched did not say whether a card is needed for the free plan.

Measured on 2026-10-03/04 from the Mac recorder: about 1,200 vehicle snapshots (1.5 MB), 240 trip snapshots (12 MB) and 65
alert snapshots a day, all gzipped. The CPU time of gzip in Cloudflare's runtime has not been measured (the tests run
locally), so the first days should be watched with `tools/pull_feeds.py --status` and the dashboard's error counts.

## Setup

You need a Cloudflare account (the free plan is enough) and Node.js. Everything installs into `collector/node_modules`
(about 240 MB; `rm -rf collector/node_modules` removes it).

```bash
cd collector
npm install
npx wrangler login                      # opens the browser; you approve once
npm run deploy                          # creates the database and the Worker; registers a workers.dev name the first time
mkdir -p ../data/collector
openssl rand -hex 32 > ../data/collector/token
npx wrangler secret put EXPORT_TOKEN < ../data/collector/token
```

Then tell the Mac where the collector is (use the `https://headway-collector.<your-name>.workers.dev` address that
`npm run deploy` printed):

```bash
printf '{"url": "%s", "token": "%s"}\n' "https://headway-collector.<your-name>.workers.dev" "$(cat ../data/collector/token)" > ../data/collector/config.json
python3 ../tools/pull_feeds.py --status     # shows the last run once the first minute has passed
python3 ../tools/pull_feeds.py              # pulls what is there
```

`data/` is outside Git, so the token never leaves the Mac. The Worker address is not secret but is not useful without the
token either.

To pull every hour without thinking about it, load the launchd job (`data/launchd/dev.kosuke.headway.pull.plist`):

```bash
launchctl bootstrap gui/$(id -u) data/launchd/dev.kosuke.headway.pull.plist
```

When the collector is working, stop the Mac recorder so that the two do not record the same thing:

```bash
launchctl bootout gui/$(id -u)/dev.kosuke.headway.recorder
```

## Tests

```bash
cd collector
npm run typecheck
npm test        # runs the Worker in Cloudflare's runtime (workerd) with a fake city and a local database, and the pull script
```

## Taking it down

```bash
cd collector
npx wrangler delete headway-collector       # the Worker
npx wrangler d1 delete headway-collector    # its database
```

## Limits worth knowing

- Cron triggers on the free plan can start a few seconds late, so the three looks are not exactly 20 s apart.
- A snapshot is the feed as the city sent it; when the city's server is down, nothing is stored and the error is kept for
  `tools/pull_feeds.py --status`.
- If the Mac does not pull for more than two weeks, the oldest snapshots are deleted to keep the database small.
