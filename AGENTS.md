# Headway

An iPhone app that shows Madison, WI buses live on an offline map, with every route, stop and timetable at a glance.
Workspace rules are in `~/Developer/AGENTS.md`; this file adds what is specific to this project.

## Product

- Purpose: replace the habit of opening Google Maps as a timetable. Existing apps are slow, show timetables as plain
  lists, do not show all stops on the map, and need a connection for map tiles.
- Intended users: Madison bus riders, first the author. Later other cities (GTFS is a standard).
- Core user journey: open the app, see the map at once, see where the buses are, tap a stop, see when the next bus
  really arrives.
- Out of scope for now: trip planning, fares, other cities, Android.
- UX is the main goal: it must feel instant and smooth. Live data comes first, the timetable is a fallback.

## Technical context

- Stack (planned): SwiftUI, MapLibre Native (iOS), SQLite for the imported GTFS, SwiftProtobuf for GTFS-Realtime.
  UI strings in English with a maintained Japanese String Catalog.
- Data: see `docs/data-sources.md`. Static GTFS is imported on the device; vehicle positions are polled every 10-15
  seconds and interpolated between polls; trip updates (about 250 KB) are fetched only while a stop is open.
- Offline map: Madison-area OSM vector tiles stored on the device. How MapLibre Native on iOS reads a local tile
  archive (PMTiles or MBTiles) is not verified yet; check it first. Any tile download needs the user's approval
  (file, source, size, destination).
- Live vs scheduled: the UI must show clearly which times are live and which come only from the timetable.
- Layout: the root `Package.swift` holds the data layer and a tool; the iOS app target will sit on top (not created
  yet).
  - `Sources/HeadwayCore/Static/`: `CSV.swift` (byte-level CSV scanner), `Models.swift` (Route, Stop, Trip, StopTime,
    ServiceDate), `Schedule.swift` (in-memory static GTFS from a zip or folder; service calendar; trips in progress).
  - `Sources/HeadwayCore/Realtime/`: `RealtimeDecoder.swift` (protobuf to plain structs), `RealtimeModels.swift`,
    `RealtimeClient.swift` (async fetch of the three feeds).
  - `Sources/HeadwayCore/Generated/gtfs-realtime.pb.swift`: generated from `proto/gtfs-realtime.proto`; do not edit.
  - `Sources/feedanalysis/`: command-line tool that compares recordings with the timetable (`Report.swift`).
  - `Tests/HeadwayCoreTests/`: Swift Testing. `RealFeedTests` runs only when a downloaded feed exists in `data/feeds/`.
- Important directories: `tools/` (recorder), `docs/`, `proto/`, `data/` (recorded feeds, logs, launchd plist; outside Git).
- Findings that shape the design are in `docs/data-sources.md`: predictions carry no delay, so delay is computed
  against the timetable; positions can be stale by more than a minute.
- Constraint: free stack only; no paid services. A free personal Apple ID is enough for installing on the user's own
  iPhone (re-signing every 7 days); the paid Developer Program is only needed to distribute.

## Plan

1. Data layer: parse GTFS and GTFS-Realtime, verify against real data, and analyse the 24-hour recording
   (which scheduled trips never get a position).
2. Offline map with all routes and stops.
3. Live bus positions on the map.
4. Stop sheet: live arrivals and timetable.
5. Polish (smoothness, accessibility) and Japanese localization.

## Commands

- Record feeds: `caffeinate -i python3 tools/record_feeds.py --hours 24` (writes `data/feeds/<date>/`). The
  2026-10-03 run was started as a launchd job from `data/launchd/dev.kosuke.headway.recorder.plist` so it survives
  the session; stop it with `launchctl bootout gui/$(id -u)/dev.kosuke.headway.recorder`.
- Smoke test of the recorder: `python3 tools/record_feeds.py --once --no-static`.
- Build: `swift build`; test: `swift test`.
- Analyse a recording: `swift build -c release && .build/release/feedanalysis report data/feeds/<date>`
  (also `schedule <zip>` and `sample <dir>` / `shape <dir>` to inspect the data).
- Regenerate protobuf code: `protoc --swift_out=Sources/HeadwayCore/Generated --swift_opt=Visibility=Public -I proto proto/gtfs-realtime.proto`
  (needs `brew install protobuf swift-protobuf`).
- Tools installed with Homebrew for this project: protobuf, swift-protobuf, pmtiles, xcodegen.
- Format, lint: not set up yet.

## Definition of done

- The requested behaviour is complete, including loading, empty, offline and error states.
- Formatting, linting, tests and builds pass where configured.
- UI is checked in the iOS Simulator at representative sizes and in light and dark mode.
- Accessibility (Dynamic Type, VoiceOver, contrast) is checked.
- Documentation matches what was delivered.
