# Headway

An iPhone app that shows Madison, WI buses live on an offline map, with every route, stop and timetable at a glance.
Workspace rules are in `~/Developer/AGENTS.md`; this file adds what is specific to this project.

## Product

- Purpose: replace the habit of opening Google Maps as a timetable. Existing apps are slow, show timetables as plain
  lists, do not show all stops on the map, and need a connection for map tiles.
- Intended users: Madison bus riders, first the author. Later other cities (GTFS is a standard).
- Core user journey: open the app, see the map at once, see where the buses are, tap a stop, see when the next bus
  really arrives.
- Out of scope for now: trip planning, fares, other cities, Android, iPad, notifications, widgets.
- UX is the main goal: it must feel instant and smooth. Live data comes first, the timetable is a fallback.

## Technical context

- Stack (planned): SwiftUI, MapLibre Native (iOS), SQLite for the imported GTFS, SwiftProtobuf for GTFS-Realtime.
  UI strings in English with a maintained Japanese String Catalog.
- Data: see `docs/data-sources.md`. Static GTFS is imported on the device; vehicle positions are polled every 10-15
  seconds and interpolated between polls; trip updates (about 250 KB) are fetched only while a stop is open.
- Offline map: Madison-area OSM vector tiles in one PMTiles file that the app bundles (MapLibre Native reads
  `pmtiles://file://...` itself; verified in the simulator). PMTiles do not take part in MapLibre's offline-pack cache,
  so the app owns the whole file. Any download needs the user's approval (file, source, size, destination).
- Live vs scheduled: the UI must show clearly which times are live and which come only from the timetable.
- Layout: the root `Package.swift` holds the data layer and a tool; `App/` is the iOS app on top of it, generated
  into `Headway.xcodeproj` by XcodeGen from `project.yml` (the project file is not committed).
  - `App/AppModel.swift`: observable app state. Loads the timetable (cache in Application Support, else the bundled
    seed, else a download; refreshes at most daily and swaps only when the feed version changes), polls vehicles
    (interval from settings), fetches service alerts once a minute, fetches trip predictions only while a stop or bus sheet
    is open, recomputes the stop
    board, and holds selection (`ActiveSheet`), route focus and camera requests.
  - `App/Settings/`: `Preferences.swift` (all user options as one tolerant Codable value, decoding falls back to
    defaults per key), `AppSettings.swift` (observable store in UserDefaults, favourites, recents, reset).
  - `App/Map/`: `MapContainer.swift` (UIViewRepresentable and `MapCoordinator`: applies `MapState` diffs, camera,
    taps), `MapLayers.swift` (sources and layers; routes and stops under basemap labels, buses on top),
    `MapState.swift` (state snapshot, `MapPreferences` subset, `RouteLook`), `BusAnimator.swift` (glide between
    reports).
  - `App/Sheets/`: `StopSheet`, `BusSheet`, `TimetableView`, `RoutesSheet`, `SearchSheet`, `SettingsView`,
    `Components` (route badge, live status, circle button).
  - `App/Support/`: `Formatting.swift` (times, delays, headsigns), `Theme.swift` (map theme, route palettes, colour
    helpers), `LocationController.swift` (permission asked only when the user taps the location button), `Haptics`.
  - `App/Menu/MenuDrawer.swift`: hamburger button and the left drawer (modes Map / Service info / Plan a trip, plus
    shortcuts to routes, search and settings). `AppModel.mode` switches the content; the map stays alive underneath.
  - `App/Info/InfoView.swift`: the service board. `App/Plan/`: `PlanModel` (inputs, results), `PlanView` (inputs, result
    cards, journey detail and steps), `PlacePicker` (stops, favourites, MapKit place search), and
    `App/Sheets/JourneySheet.swift` (summary over the map; the journey is drawn by `MapLayers.setJourney`).
  - Map long-press drops a pin and offers directions to or from it; a stop's sheet has a Directions button.
  - `App/RootView.swift`: map, status pill, controls, focus chip, sheet routing (stop and bus share one sheet
    identity so selecting another does not re-present it).
  - `App/Resources/`: `Localizable.xcstrings` (English keys, Japanese values; add both when adding UI text),
    `ja.lproj`/`en.lproj` InfoPlist strings, `Assets.xcassets` (icon), basemap styles and glyphs.
  - `AppTests/`: Swift Testing for preferences, settings, formatting and colours.
  - Offline basemap: `tools/fetch_basemap.sh` cuts `data/maps/madison.pmtiles` (17 MB, Protomaps build 2026-10-03,
    zoom 0-15, bbox -89.62,42.93,-89.20,43.20) and fetches Noto Sans glyphs into `App/Resources/glyphs/` (committed,
    0.8 MB). `tools/style/generate.mjs` (Node, `@protomaps/basemaps`; flavors `white` and `dark`, points of interest removed)
    writes both style JSON files; rerun it after changing a flavor. The style has no remote URLs, so the map needs no network. Tiles are bundled into the
    app by `project.yml`, so run `tools/fetch_basemap.sh` before building. Attribution: (c) OpenStreetMap contributors.
  - `Sources/HeadwayCore/Static/`: `CSV.swift` (byte-level CSV scanner), `Models.swift` (Route, Stop, Trip, StopTime,
    ServiceDate), `Schedule.swift` (in-memory static GTFS from a zip or folder; service calendar; trips in progress).
  - `Sources/HeadwayCore/Planning/`: `TripPlanner.swift` (round-based connection scan: for each number of buses the
    earliest arrival, with walking access and footpath transfers, live delays applied to buses that report; a second
    scan finds the buses after the first journey's), `Journey.swift` (journey, legs, polylines along the route shape).
  - `Sources/HeadwayCore/ServiceStatus.swift` (per-route delays, cancelled trips, trips without a position),
    `Geometry.swift` (distances, nearest point on a line, bus-to-route distance), `Arrivals.swift` (stop board, remaining
    stops of a trip).
  - `Sources/HeadwayCore/Realtime/`: `RealtimeDecoder.swift` (protobuf to plain structs), `RealtimeModels.swift`,
    `RealtimeClient.swift` (async fetch of the three feeds).
  - `Sources/HeadwayCore/Generated/gtfs-realtime.pb.swift`: generated from `proto/gtfs-realtime.proto`; do not edit.
  - `Sources/feedanalysis/`: command-line tool that compares recordings with the timetable (`Report.swift`).
  - `Tests/HeadwayCoreTests/`: Swift Testing. `RealFeedTests` runs only when a downloaded feed exists in `data/feeds/`.
- Important directories: `tools/` (recorder), `docs/`, `proto/`, `data/` (recorded feeds, logs, launchd plist; outside Git).
- Findings that shape the design are in `docs/data-sources.md`: predictions carry no delay, so delay is computed
  against the timetable; positions can be stale by more than a minute.
- Constraint: free stack only; no paid services. A free personal Apple ID is enough for installing on the user's own
  iPhone (re-signing every 7 days); the paid Developer Program is only needed to distribute (TestFlight, App Store).
- Signing: the Mac utilities use one shared self-signed certificate (see `mac-utilities/AGENTS.md`); iOS rejects
  self-signed certificates, so Headway uses the Apple Development certificate of the user's free Personal Team; the team
  id is kept in the uncommitted `Config/Local.xcconfig`. `docs/run-on-iphone.md` has the steps and the TestFlight note.

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
  (also `schedule <zip>`, `sample <dir>`, `shape <dir>`, `deviation <dir>` (how far buses stray from route lines) and
  `plan <dir> <from> <to> [HH:mm | yyyy-MM-ddTHH:mm]` to try the planner on the real timetable).
- Regenerate protobuf code: `protoc --swift_out=Sources/HeadwayCore/Generated --swift_opt=Visibility=Public -I proto proto/gtfs-realtime.proto`
  (needs `brew install protobuf swift-protobuf`).
- Tools installed with Homebrew for this project: protobuf, swift-protobuf, pmtiles, xcodegen.
- App: `xcodegen generate`, then
  `xcodebuild -project Headway.xcodeproj -scheme Headway -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO`.
- Tests: `swift test` (data layer, 84) and
  `xcodebuild test -project Headway.xcodeproj -scheme Headway -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO`
  (app, 26).
- Before building the app: `tools/fetch_basemap.sh` and `tools/fetch_timetable.sh` (both outputs are bundled by
  `project.yml` and not committed), then `xcodegen generate`.
- Icon: `swift tools/make_icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset` (light, dark, tinted).
- Simulator notes: `simctl ... booted` can point at the wrong device when two are booted; use the UDID. Typing into
  a search field through the control tool is slow; wait before the next tap.
- The 24 h feed report is written by a launchd job (`data/launchd/dev.kosuke.headway.report.plist`) to
  `docs/feed-analysis-2026-10-03.md` at 2026-10-04 17:10 CDT.
- Recordings run continuously (launchd job `dev.kosuke.headway.recorder`, `tools/record_feeds.py`, one folder per day in
  `data/feeds/`, a snapshot saved only when it changed, about 15 MB a day). A nightly job (04:30) runs
  `tools/build_punctuality.sh`, which turns recorded bus positions into observed arrival times (SQLite,
  `data/punctuality/observations.sqlite`) and exports `data/punctuality/punctuality.json`, which the app bundles.
  `feedanalysis freshness|accuracy|punctuality` explain the feed's real latency, prediction accuracy and punctuality.
- Format, lint: not set up yet.

## Known limits and next steps

- Not yet run on a physical iPhone; Dynamic Type, VoiceOver on the map, and low-power behaviour are unchecked.
- Predictions come from the city's trip-updates feed, which has no delay field and covers only trips with a bus;
  the board therefore shows the timetable for the rest. Whether predictions are biased is unverified (see
  `docs/data-sources.md`).
- Live latency (measured on 2026-10-03, see `docs/data-sources.md`): a bus reports every 30 s, the feed is rebuilt every
  30 s, positions are about 25 s old on arrival. The app times its requests from the server's `Date` header, dead-reckons
  buses along their route at their last speed (up to 50 s), and veils buses silent for over 75 s. Predictions are
  accurate to about +/-40 s (median) within 5 minutes and barely better than the timetable beyond 20 minutes.
- Punctuality statistics need weeks of recordings to be reliable; the app says how many days they cover and shows
  nothing for a route and time of week with too few observations.
- Detour paths are not published by the city (the alerts have text, a link to its detour page, and a period). Buses on
  routes with an alert were mostly on their normal line in the first recording, so inferring detour paths from live
  positions is not reliable yet; the app dashes affected routes and rings buses that are off their line.
- Trip planner: walking is a straight line scaled by 1.3 (no street network offline); places by name need Apple Maps
  (online); "arrive by" is not implemented; the search looks 4 hours ahead.
- Bus markers trail the real bus by up to one update interval plus the feed's own latency.
- Publishing: the data terms contain an indemnification clause (see `docs/data-sources.md`); the App Store needs the
  paid Developer Program; map tiles need the OSM attribution (already in Settings and the map's info button).
- Ideas not started: notifications when a bus is near, widgets, other cities (GTFS is generic, the feed URLs and
  basemap box are the Madison-specific parts), iPad layout.

## Definition of done

- The requested behaviour is complete, including loading, empty, offline and error states.
- Formatting, linting, tests and builds pass where configured.
- UI is checked in the iOS Simulator at representative sizes and in light and dark mode.
- Accessibility (Dynamic Type, VoiceOver, contrast) is checked.
- Documentation matches what was delivered.
