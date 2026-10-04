#!/usr/bin/env bash
# Fetch the offline basemap pieces for Madison, WI.
#
#   data/maps/madison.pmtiles          vector tiles cut from a Protomaps build (OpenStreetMap data, about 18 MB)
#   App/Resources/glyphs/<font>/*.pbf  label glyphs from protomaps/basemaps-assets (about 0.8 MB, committed)
#
# Needs `brew install pmtiles`. Basemap data: (c) OpenStreetMap contributors, ODbL.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-20261003}"
BBOX="-89.62,42.93,-89.20,43.20" # lon/lat box around the Metro service area
mkdir -p data/maps
if [ ! -f data/maps/madison.pmtiles ]; then
  pmtiles extract "https://build.protomaps.com/${BUILD}.pmtiles" data/maps/madison.pmtiles --bbox="$BBOX" --maxzoom=15
fi

# Latin text, accented letters and general punctuation are enough for English labels in Madison.
ASSETS="https://raw.githubusercontent.com/protomaps/basemaps-assets/main/fonts"
for font in "Noto Sans Regular" "Noto Sans Medium" "Noto Sans Italic"; do
  mkdir -p "App/Resources/glyphs/$font"
  for range in 0-255 256-511 8192-8447; do
    target="App/Resources/glyphs/$font/$range.pbf"
    [ -f "$target" ] || curl -sfL "${ASSETS}/${font// /%20}/$range.pbf" -o "$target"
  done
done
# The fonts are under the SIL Open Font License, whose text must travel with them.
[ -f App/Resources/glyphs/OFL.txt ] || curl -sfL "${ASSETS}/OFL.txt" -o App/Resources/glyphs/OFL.txt
echo "basemap ready"
