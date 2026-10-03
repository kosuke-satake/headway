#!/usr/bin/env bash
# Download the Madison Metro timetable (static GTFS, about 7 MB) into data/seed/.
#
# The app bundles this file so that its first launch works without a connection; it refreshes itself from the same
# URL once a day. Data: City of Madison, WI, Metro Transit.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data/seed
curl -sfL --retry 2 -o data/seed/mmt_gtfs.zip.tmp "https://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip"
unzip -tq data/seed/mmt_gtfs.zip.tmp > /dev/null
mv data/seed/mmt_gtfs.zip.tmp data/seed/mmt_gtfs.zip
echo "timetable ready: $(du -h data/seed/mmt_gtfs.zip | cut -f1)"
