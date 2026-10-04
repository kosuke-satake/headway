# Data sources: Madison Metro Transit

Checked on 2026-10-03 by fetching the feeds and decoding them with `HeadwayCore`.

| Data | URL | Notes |
|---|---|---|
| Static GTFS | `https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip` | 7.3 MB, feed `S072_202608240858`, valid 2026-08-16 to 2026-12-05, no key |
| Vehicle positions (GTFS-RT) | `https://metromap.cityofmadison.com/gtfsrt/vehicles` | about 3 KB, no key |
| Trip updates (GTFS-RT) | `https://metromap.cityofmadison.com/gtfsrt/trips` | about 250 KB, no key |
| Alerts (GTFS-RT) | `https://metromap.cityofmadison.com/gtfsrt/alerts` | about 3 KB, no key |

Developer page: <https://www.cityofmadison.com/metro/business/information-for-developers>.
The older `transitdata.cityofmadison.com/{Vehicle,TripUpdate,Alert}/*.pb` URLs return 13-byte empty files.

## Terms of use (`terms_of_use.txt` inside the feed)

Read on 2026-10-03; this is a summary, not legal advice.

- The license is non-exclusive, limited and revocable. Use, reproduction and redistribution are allowed, limited to
  uses that assist transit riders or promote public transportation.
- Crediting the city is optional. The wording if used: "Data provided under license granted by City of Madison, WI,
  Metro Transit."
- The data is provided as is, with no warranty of accuracy or availability.
- The licensee indemnifies the city against claims arising from its use of the data or products derived from it.
  Think about this before publishing the app on the App Store.
- The city may modify, terminate or revoke the agreement at any time.

## What the static feed contains

29 routes (with brand colours), 1,681 stops, 14,199 trips, 603,662 stop times, 184 shapes (about 180,000 points), and
12 service calendars with exceptions. `stop_times.txt` alone is 38 MB of text. Parsing the whole feed in memory
takes about 2 s in a debug build, so the app will import it into SQLite once instead of parsing on every launch.

## What the realtime feeds contain (one snapshot, 2026-10-03 17:01 CDT)

- Vehicles: every vehicle has `trip_id`, `route_id` and `vehicle_id`; none has `stop_id` or `current_stop_sequence`,
  and `direction_id` and `start_date` are empty. Position timestamps were 11 to 85 s older than the feed timestamp.
- Trip updates: 126 of 130 entities have a `trip_id`; 68 have a `vehicle_id` (trips with a bus already assigned).
  All are `SCHEDULED`. `delay` fields are never set, only absolute predicted times, so delay has to be computed
  as predicted time minus timetable time.
- Alerts: detours such as "L - Aberg RR Detour" and "80 - Randall Detour", with route ids.

## Preliminary findings (35 minutes, Saturday afternoon; not conclusive)

From `feedanalysis report` on the first 35 minutes of the recording:

- About 95% of scheduled trips in progress had a bus position; about 5% had none (route R and 80 stood out, on very
  few samples). No trip was found with an assigned bus but no position.
- About 2% of bus-minutes came from vehicles reporting no trip id.
- Positions older than 60 s: about 1%.
- Predicted arrival at the next stop minus the timetable: median +92 s, p95 +655 s, about 23% more than 5 minutes
  late, none more than 5 minutes early. This may be real lateness or a systematic offset in how predictions are
  built; it is not verified. The 24 h report (`docs/feed-analysis-2026-10-03.md`, written automatically) is the
  better basis.

## How live the feed really is (measured 2026-10-03 from 728 fetches)

| | median | p90 |
|---|---:|---:|
| a bus reports every | 30 s | 36 s |
| the server rebuilds the feed every | 30 s | 41 s |
| age of a position inside the feed | 11 s | 20 s |
| age of the feed when fetched at random | 15 s | 31 s |

So a position on screen is about 25 s old on average and can be nearly a minute old. About half of the fetches of a
10-second poll returned the same data. The response has a `Date` header (the server's clock), which the app uses to
fetch right after each rebuild.

## How good the live predictions are (first 3 hours of recordings, Saturday evening)

Predicted arrival at a stop compared with the arrival observed afterwards from bus positions (error in seconds, median
absolute / 90th percentile, by how far ahead the prediction was made):

| ahead | live prediction | timetable |
|---|---|---|
| 0-2 min | 21 / 73 | 117 / 429 |
| 2-5 min | 42 / 132 | 120 / 431 |
| 5-10 min | 65 / 193 | 121 / 429 |
| 10-20 min | 93 / 270 | 123 / 429 |
| 20-30 min | 112 / 335 | 130 / 435 |

The timetable runs about 100 s earlier than reality on average (bias -100 s); live predictions have almost no bias
close in. Observed punctuality over the same hours: about 11% of arrivals more than a minute early, 70% on time,
19% more than five minutes late. Regenerate with `feedanalysis accuracy data/feeds`.

No public history of on-time performance by stop was found (the city publishes ridership and annual reports), so the
statistics are built from the project's own recordings.

## Alerts

Nine alerts on 2026-10-03, all with effect `DETOUR`, a description, a link to a city detour page and a coarse active
period (whole days; the text has the real hours). They name routes, not stops, even when the text says a stop is
closed. There is no geometry. Moving buses were within a few metres of their route line on almost every route, including
routes with alerts (the detours are limited in time), so a detour path cannot yet be recovered from positions.

## Open questions

- Do the preliminary numbers above hold over a full day, and do they differ by hour and route?
- Are predictions biased late? Compare predicted and observed arrival times (needs positions near stops).
