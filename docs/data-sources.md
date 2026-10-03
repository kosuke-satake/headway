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

## Alerts

Nine alerts on 2026-10-03, all with effect `DETOUR`, a description, a link to a city detour page and a coarse active
period (whole days; the text has the real hours). They name routes, not stops, even when the text says a stop is
closed. There is no geometry. Moving buses were within a few metres of their route line on almost every route, including
routes with alerts (the detours are limited in time), so a detour path cannot yet be recovered from positions.

## Open questions

- Do the preliminary numbers above hold over a full day, and do they differ by hour and route?
- Are predictions biased late? Compare predicted and observed arrival times (needs positions near stops).
