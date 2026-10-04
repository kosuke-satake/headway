# Headway

A fast, live bus map for Madison, WI (Metro Transit): every route and stop on an offline map, buses moving in real
time, and the next arrivals at any stop. English UI with a Japanese localization.

## Features

- **Offline map.** The Madison-area basemap is stored in the app; only the live bus positions need a connection
  (about 3 KB per update).
- **Everything visible at once.** All routes, all stops (names appear when zoomed in) and all buses, with the route
  name on each bus.
- **Live arrivals.** Tap a stop to see the next buses, live where a bus is reporting ("4 min · 1 min late") and from
  the timetable otherwise, plus the full timetable for any of the next 7 days.
- **Service alerts.** Detours and other alerts that affect a stop's routes appear at the top of its sheet. Routes with
  an alert in force are drawn dashed, and a bus far from its usual line is ringed in orange.
- **Modes** (hamburger menu, top left): the Map; **Service info** (alerts, delays per route, cancelled trips, trips
  that should be running but report no position, and the next buses at your favourite stops); and **Plan a trip**.
- **Trip planner.** From your location, a stop, a place found by name (Apple Maps, needs a connection) or a pin you
  long-press on the map, to anywhere. It finds journeys with walking and transfers, takes the live delay of reporting
  buses into account, shows them step by step and draws them on the map. Leave now, depart at, or **arrive by**; earlier
  and later buses; sort by departure, arrival, transfers or walking; badges for the fastest, fewest-transfer and
  least-walking journeys. Up to three **stops on the way**, each with a stay time. **Saved places** (Home, Work, others), **saved trips** (one tap to plan again), recent trips,
  walking speed, longest walk, most transfers, time to change buses, wheelchair-accessible only, a reminder before you
  have to leave, and sharing a journey as text.
- **How punctual, and how live.** The live line reports the age of the bus positions (they are about 25 s old; the city's
  feed is rebuilt every 30 s). Buses are moved along their route between reports. Stop sheets show, for the time of week,
  the share of buses that were early, on time or late at that stop, and live arrivals carry the range the bus has come in
  on 9 of 10 past occasions. These come from recordings the project makes itself (see `docs/data-sources.md`).
- **Follow a bus.** Tap a bus to see its next stops with predicted times.
- **Directions.** Many Madison streets are one-way, so the two directions of a route often differ. Routes are listed by
  direction ("Westbound to ..."), the favourite-stop cards say where their buses go, and arrows along a route show which
  way its buses run.
- **Overlapping routes.** Routes that share a street are drawn side by side in lanes, like a transit diagram; tapping
  lines of several routes asks which one you meant. Each route and direction says how many buses are running, or why
  there are none (not running today, between trips), with the next trip.
- **Focus.** Tap a route, or one direction of it, to see only that on the map (other routes are hidden or faded, as you
  choose in Settings); an alert's **Show on map** link does the same and rings the stops its text names; the delay rows
  of Service info show the late or early buses on the map. Hide routes you never use.
- **Notifications.** Watch routes (swipe a route) and be told when one is late, early or has an alert. Local
  notifications only: Headway checks while it is open and, when iOS allows, in the background, so they are best effort.
- **Search** by stop name or sign number; favourites, recents and nearby stops.
- **Customization.** Light, dark or system theme; three colour palettes (Metro Transit, colour-blind-safe,
  quiet); line thickness; bus marker size; when to show stops; update interval (5-30 s); smooth bus movement;
  12/24-hour clock; minutes or clock times; delay details; haptics.
- Honest about data: a clock icon marks times that come only from the timetable.

Status: working prototype. It runs on an iPhone 12 Pro (free Personal Team signing) and in the iOS Simulator.

## Getting started

Needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [pmtiles](https://github.com/protomaps/go-pmtiles),
and Node (for the map style). With Homebrew: `brew install xcodegen pmtiles node`.

```bash
tools/fetch_basemap.sh      # map tiles (18 MB) and label glyphs
tools/fetch_timetable.sh    # timetable bundled for the first launch (7 MB)
tools/build_punctuality.sh  # punctuality statistics from recordings (an empty table if there are none)
xcodegen generate           # creates Headway.xcodeproj
open Headway.xcodeproj      # run on a simulator or your iPhone
```

To run on your own iPhone, see `docs/run-on-iphone.md` (`tools/run_on_device.sh` builds an optimised Release build and
installs it). A free Apple ID works; the app must be re-signed every 7 days.

## Data

| What | Source |
|---|---|
| Timetable (GTFS) and live positions, predictions, alerts (GTFS-Realtime) | City of Madison, WI, Metro Transit. See `docs/data-sources.md` for URLs and terms |
| Map | © OpenStreetMap contributors, via a Protomaps build |

## Architecture

- `Sources/HeadwayCore`: GTFS and GTFS-Realtime parsing, arrivals logic. No UI; tested with `swift test`.
- `App/`: SwiftUI app with MapLibre Native. See `AGENTS.md` for the file-by-file map.
- `collector/`: a Cloudflare Worker (free plan) that records the city's feeds around the clock; `tools/pull_feeds.py`
  brings the recordings to the Mac. See `collector/README.md`.
- `tools/`: feed recorder, analysis, map and icon generation.
- `docs/`: data sources and findings.

## Quality checks

```bash
swift test                                                       # data layer (120 tests)
xcodebuild test -project Headway.xcodeproj -scheme Headway \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO   # app tests (42)
(cd collector && npm test)                                       # collector, in Cloudflare's runtime (9 tests)
```
