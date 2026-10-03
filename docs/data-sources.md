# Data sources: Madison Metro Transit

Checked on 2026-10-03 (HTTP status and sizes observed directly; terms of use not yet read).

| Data | URL | Notes |
|---|---|---|
| Static GTFS | `https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip` | 7.3 MB, last modified 2026-08-24, no key |
| Vehicle positions (GTFS-RT) | `https://metromap.cityofmadison.com/gtfsrt/vehicles` | about 3 KB, no key |
| Trip updates (GTFS-RT) | `https://metromap.cityofmadison.com/gtfsrt/trips` | about 250 KB, no key |
| Alerts (GTFS-RT) | `https://metromap.cityofmadison.com/gtfsrt/alerts` | about 3 KB, no key |

Developer page: <https://www.cityofmadison.com/metro/business/information-for-developers>.
Use is subject to the city's Developer License Agreement and Terms of Use. Read it before any public release.

The older `transitdata.cityofmadison.com/{Vehicle,TripUpdate,Alert}/*.pb` URLs returned 13-byte empty files.

## Open questions

- Do all scheduled trips appear with a vehicle position while they run? A 2026-10-03 snapshot showed 52 vehicles and
  131 predicted trips, but many trip updates had an empty `trip_id`, so the two could not be joined. The 24-hour
  recording from `tools/record_feeds.py` is meant to settle this.
- Is a vehicle position without a `trip_id` common (a bus that reports GPS but is not linked to a run)?
