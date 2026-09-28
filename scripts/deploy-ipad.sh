#!/bin/zsh
# Builds Inkwell (Release) and installs it on the connected iPad.
#   scripts/deploy-ipad.sh            build + install + launch
#
# Prereqs (one time): iPad plugged in (or on the same Wi-Fi after pairing) → "Trust This
# Computer", and Settings › Privacy & Security › Developer Mode ON (the iPad restarts).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
read -r DEVICE_ID UDID NAME <<< "$(python3 - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPad" and hw.get("platform") == "iOS":
        print(dev["identifier"], hw.get("udid", ""), dev.get("deviceProperties", {}).get("name", "iPad").replace(" ", "_"))
        break
PY
)"
rm -f "$JSON"
if [[ -z "${DEVICE_ID:-}" ]]; then
  echo "No iPad found. Plug it in, tap Trust, and turn on Developer Mode (Settings › Privacy & Security)." >&2
  exit 1
fi
echo "→ Building for ${NAME//_/ } ($UDID)"

cd Inkwell
xcodegen generate >/dev/null
LOG="$(mktemp)"
if ! xcodebuild -project Inkwell.xcodeproj -scheme Inkwell -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/DeviceData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >"$LOG" 2>&1; then
  grep -E "error:|Developer Mode" "$LOG" | head -5 >&2
  if grep -q "Developer Mode disabled" "$LOG"; then
    echo "→ Turn on Settings › Privacy & Security › Developer Mode on the iPad (it restarts), then run this again." >&2
  fi
  exit 1
fi
rm -f "$LOG"
APP="build/DeviceData/Build/Products/Release-iphoneos/Inkwell.app"

echo "→ Installing"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null

echo "→ Launching"
# Accounts (Phase 4): the app signs in with Neon Auth, so no token is handed over any more.
# (Pre-accounts builds received a shared token here; the iPad keeps it only until the first
# sign-in claims that old backup.) A locked iPad can't launch apps; the install still stands.
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing studio.persimmons.inkwell >/dev/null \
  || echo "  (Couldn’t launch — unlock the iPad and open Inkwell.)"
echo "✓ Inkwell is on ${NAME//_/ }."
