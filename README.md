# Headway

A fast, live bus map for Madison, WI: every route and stop on an offline map, with buses moving in real time.

Status: early. Nothing runs yet except the feed recorder.

## Features (planned)

- Offline map of the Madison area; only the live bus data needs a connection.
- All routes and all stops always visible, decluttered by zoom.
- Live bus positions that move smoothly between updates.
- Tap a stop for live arrivals ("scheduled vs actual") and the full timetable.
- Clear distinction between live data and timetable-only trips.

## Getting started

Record the live feeds (standard library only, no setup):

```bash
caffeinate -i python3 tools/record_feeds.py --hours 24
```

Recordings are written to `data/feeds/<date>/` and are not committed.

## Architecture

See `AGENTS.md` for the plan and `docs/data-sources.md` for the feeds.

## Quality checks

Not set up yet.
