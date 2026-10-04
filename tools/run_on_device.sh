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
  # A real device is any device that is not a simulator (simulators say "simulated"; real ones leave it empty).
  LIST="$(mktemp)"
  xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
  FOUND=$(python3 - "$LIST" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
real = [d for d in devices if d["hardwareProperties"].get("reality") != "simulated"]
# Prefer a device that is connected right now over one that is only paired.
real.sort(key=lambda d: d["connectionProperties"].get("tunnelState") != "connected")
for d in real[:1]:
    print(d["hardwareProperties"]["udid"], d["deviceProperties"].get("name", "iPhone"), d["connectionProperties"].get("tunnelState", ""), sep="|")
PY
)
  rm -f "$LIST"
  if [ -z "$FOUND" ]; then
    echo "This Mac has not paired with any iPhone. Connect it with a cable, unlock it, and tap Trust."
    exit 1
  fi
  DEVICE="${FOUND%%|*}"
  NAME=$(echo "$FOUND" | cut -d'|' -f2)
  STATE="${FOUND##*|}"
  if [ "$STATE" != "connected" ]; then
    echo "$NAME is paired but not connected right now (state: ${STATE:-unknown})."
    echo "Plug it in with the cable (or turn on Wi-Fi sync in Finder), unlock it, and run this again."
    [ "${CHECK_ONLY:-}" = "1" ] || exit 1
  fi
  echo "Found $NAME"
fi
[ "${CHECK_ONLY:-}" = "1" ] && exit 0
echo "Device: $DEVICE"

xcodebuild -project Headway.xcodeproj -scheme Headway -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/Device -allowProvisioningUpdates build | tail -n 5
APP="build/Device/Build/Products/Debug-iphoneos/Headway.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" dev.kosuke.headway
