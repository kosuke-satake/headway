#!/usr/bin/env bash
# Build Headway and install it on a connected iPhone.
#
#   tools/run_on_device.sh              # picks the connected iPhone (asks if there are several)
#   tools/run_on_device.sh <device id>
#
# Needs Config/Local.xcconfig with your DEVELOPMENT_TEAM (see docs/run-on-iphone.md). Xcode creates the signing
# certificate and provisioning profile itself (-allowProvisioningUpdates), so you must be signed in to your Apple ID in
# Xcode > Settings > Accounts once.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Config/Local.xcconfig ] || { echo "Missing Config/Local.xcconfig (see Config/Local.xcconfig.example)"; exit 1; }
[ -f data/maps/madison.pmtiles ] || tools/fetch_basemap.sh
[ -f data/seed/mmt_gtfs.zip ] || tools/fetch_timetable.sh
[ -f data/punctuality/punctuality.json ] || tools/build_punctuality.sh
xcodegen generate >/dev/null

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  # The first physical (not simulated) device that is reachable.
  LIST="$(mktemp)"
  xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
  DEVICE=$(python3 - "$LIST" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    if d["hardwareProperties"].get("reality") == "physical" and d["connectionProperties"].get("tunnelState") != "unavailable":
        print(d["hardwareProperties"]["udid"])
        break
PY
)
  rm -f "$LIST"
fi
[ -n "$DEVICE" ] || { echo "No iPhone found. Connect it with a cable, unlock it, and tap Trust."; exit 1; }
echo "Device: $DEVICE"

xcodebuild -project Headway.xcodeproj -scheme Headway -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/Device -allowProvisioningUpdates build | tail -n 5
APP="build/Device/Build/Products/Debug-iphoneos/Headway.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" dev.kosuke.headway
