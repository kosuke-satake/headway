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
- Planned layout: a Swift package for the data layer (GTFS and GTFS-Realtime parsing, no UI, tested with
  `swift test`), and the app target on top of it. Not created yet.
- Important directories: `tools/` (recorder and analysis scripts), `docs/`, `data/` (recorded feeds, outside Git).
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

- Record feeds: `caffeinate -i python3 tools/record_feeds.py --hours 24` (writes `data/feeds/<date>/`).
- Smoke test of the recorder: `python3 tools/record_feeds.py --once --no-static`.
- Xcode is installed but the active developer directory is the Command Line Tools. Without `sudo`, prefix commands
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Format, lint, type-check, test, build: not set up yet.

## Definition of done

- The requested behaviour is complete, including loading, empty, offline and error states.
- Formatting, linting, tests and builds pass where configured.
- UI is checked in the iOS Simulator at representative sizes and in light and dark mode.
- Accessibility (Dynamic Type, VoiceOver, contrast) is checked.
- Documentation matches what was delivered.
