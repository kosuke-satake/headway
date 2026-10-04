# Third-party material

Headway's own code has no licence file yet (the author is still choosing one). The material below belongs to others and
keeps its own terms.

| What | Where | Licence |
|---|---|---|
| Noto Sans glyphs (label fonts, as `.pbf` files) | `App/Resources/glyphs/`, fetched by `tools/fetch_basemap.sh` from [protomaps/basemaps-assets](https://github.com/protomaps/basemaps-assets) | SIL Open Font License; the licence text is `App/Resources/glyphs/OFL.txt` and is bundled with the fonts |
| `gtfs-realtime.proto` and the Swift code generated from it | `proto/`, `Sources/HeadwayCore/Generated/` | Apache License 2.0, Copyright The GTFS Specifications Authors |
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | Swift package dependency | Apache License 2.0 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | Swift package dependency | MIT |
| [MapLibre Native](https://github.com/maplibre/maplibre-native) | Swift package dependency (via maplibre-gl-native-distribution) | BSD 2-Clause |
| [@protomaps/basemaps](https://github.com/protomaps/basemaps) | `tools/style/` (Node, generates the map style; not shipped) | BSD 3-Clause |
| Map data | `data/maps/madison.pmtiles` (not in the repository; built by `tools/fetch_basemap.sh`) | © OpenStreetMap contributors, Open Database Licence 1.0; tiles from a Protomaps build |
| Timetable and live feeds | City of Madison, WI, Metro Transit | Terms in the feed's `terms_of_use.txt`, summarised in `docs/data-sources.md` |

The app shows the OpenStreetMap and City of Madison credits in Settings and on the map.

Checked on 2026-10-04 against the licence files of the checked-out packages (SwiftProtobuf, ZIPFoundation, MapLibre), the
`license` field of `@protomaps/basemaps`, and the licence section of the basemaps-assets README.
