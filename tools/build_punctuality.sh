#!/usr/bin/env bash
# Build data/punctuality/punctuality.json (how punctual each route and stop is, and how accurate live predictions are)
# from the recordings in data/feeds/. The app bundles this file. With no recordings it writes an empty table, so the
# app still builds and simply shows no statistics.
#
#   tools/build_punctuality.sh            # add new days to the observation database and export
#   tools/build_punctuality.sh --force    # redo every day
#
# A launchd job (data/launchd/dev.kosuke.headway.punctuality.plist) runs this every night at 04:30.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data/punctuality
if ls data/feeds/*/mmt_gtfs.zip >/dev/null 2>&1; then
  swift build -c release --product feedanalysis 2>&1 | tail -n 1
  .build/release/feedanalysis punctuality data/feeds data/punctuality/punctuality.json ${1:+"$1"}
else
  echo '{"generated":"1970-01-01T00:00:00Z","firstDay":"","lastDay":"","days":0,"observations":0,"routeCells":{},"stopCells":{},"predictionBins":[]}' > data/punctuality/punctuality.json
  echo "no recordings yet: wrote an empty table"
fi
