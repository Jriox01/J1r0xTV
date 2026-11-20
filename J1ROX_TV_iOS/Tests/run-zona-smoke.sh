#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; ds=[d for runtime,v in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in v if d.get("isAvailable") and d["name"].startswith("iPhone")]; print(next((d["udid"] for d in ds if d["state"] == "Booted"), ds[0]["udid"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
open -a Simulator --args -CurrentDeviceUDID "$DEVICE"
APP=build/DerivedData-debug/Build/Products/Debug-iphonesimulator/J1ROXTV.app
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console "$DEVICE" com.jirox.jiroxtv --zona-smoke-test --zona-mutiny-smoke-test >build/logs/zona-app.log 2>&1 &
LAUNCH_PID=$!
trap 'xcrun simctl terminate "$DEVICE" com.jirox.jiroxtv >/dev/null 2>&1 || true' EXIT
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.jirox.jiroxtv data)
for i in {1..60}; do
  test -f "$CONTAINER/Documents/zona-smoke-results.json" && break
  kill -0 "$LAUNCH_PID" 2>/dev/null || break
  sleep 2
done
if test -f "$CONTAINER/Documents/zona-smoke-results.json"; then
  cp "$CONTAINER/Documents/zona-smoke-results.json" build/logs/zona-smoke-results.json
  cat build/logs/zona-smoke-results.json
else
  printf '{"result":"FAIL","error":"Simulator produced no result"}\n' >build/logs/zona-smoke-results.json
fi
xcrun simctl io "$DEVICE" screenshot build/logs/zona-smoke.png
# Live CDN/SDK reachability is diagnostic, not a replacement for regression tests.
