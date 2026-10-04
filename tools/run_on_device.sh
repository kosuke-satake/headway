#!/usr/bin/env bash
# Build Headway (an optimised Release build: the timetable loads several times faster than in a Debug build) and
# install it on a connected iPhone.
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
  # A paired device often reports "disconnected" until something connects to it (that is normal for wireless use), so
  # try to reach it instead of trusting the state.
  if ! xcrun devicectl device info details --device "$DEVICE" >/dev/null 2>&1; then
    echo "$NAME is paired but cannot be reached. Plug it in with the cable (or enable \"Connect via network\" in Xcode >"
    echo "Window > Devices and Simulators), unlock it, and run this again."
    [ "${CHECK_ONLY:-}" = "1" ] || exit 1
  fi
  echo "Found $NAME"
fi
[ "${CHECK_ONLY:-}" = "1" ] && exit 0
echo "Device: $DEVICE"

LOG="build/device-build.log"
mkdir -p build
if ! xcodebuild -project Headway.xcodeproj -scheme Headway -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath build/Device -allowProvisioningUpdates build > "$LOG" 2>&1; then
  echo "Build failed. Errors:"
  grep -E "error:" "$LOG" | sort -u | head -n 10
  echo "(full log: $LOG; the first build after adding an Apple ID sometimes fails while Xcode creates the signing profile, so try once more)"
  exit 1
fi
APP="build/Device/Build/Products/Release-iphoneos/Headway.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
if ! xcrun devicectl device process launch --device "$DEVICE" dev.kosuke.headway; then
  echo
  echo "Installed, but it could not start. On the first install the iPhone must trust you as a developer:"
  echo "  Settings > General > VPN & Device Management > your Apple ID > Trust."
  echo "Then open Headway from the Home screen."
fi
