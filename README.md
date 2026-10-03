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
  buses into account, shows them step by step and draws them on the map.
- **Follow a bus.** Tap a bus to see its next stops with predicted times.
- **Focus.** Tap a route to see only that route and its stops; hide routes you never use.
- **Search** by stop name or sign number; favourites, recents and nearby stops.
- **Customization.** Light, dark or system theme; three colour palettes (Metro Transit, colour-blind-safe,
  quiet); line thickness; bus marker size; when to show stops; update interval (5-30 s); smooth bus movement;
  12/24-hour clock; minutes or clock times; delay details; haptics.
- Honest about data: a clock icon marks times that come only from the timetable.

Status: working prototype, tested in the iOS Simulator. Not yet run on a physical iPhone.

## Getting started

Needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [pmtiles](https://github.com/protomaps/go-pmtiles),
and Node (for the map style). With Homebrew: `brew install xcodegen pmtiles node`.

```bash
tools/fetch_basemap.sh      # map tiles (18 MB) and label glyphs
tools/fetch_timetable.sh    # timetable bundled for the first launch (7 MB)
xcodegen generate           # creates Headway.xcodeproj
open Headway.xcodeproj      # run on a simulator or your iPhone
```

To run on your own iPhone, select your Apple ID team under Signing & Capabilities. A free account works; the app
must be re-signed every 7 days.

## Data

| What | Source |
|---|---|
| Timetable (GTFS) and live positions, predictions, alerts (GTFS-Realtime) | City of Madison, WI, Metro Transit. See `docs/data-sources.md` for URLs and terms |
| Map | © OpenStreetMap contributors, via a Protomaps build |

## Architecture

- `Sources/HeadwayCore`: GTFS and GTFS-Realtime parsing, arrivals logic. No UI; tested with `swift test`.
- `App/`: SwiftUI app with MapLibre Native. See `AGENTS.md` for the file-by-file map.
- `tools/`: feed recorder, analysis, map and icon generation.
- `docs/`: data sources and findings.

## Quality checks

```bash
swift test                                                       # data layer (55 tests)
xcodebuild test -project Headway.xcodeproj -scheme Headway \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO   # app tests (16)
```
