#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
python3 Tests/hls-fixture-server.py >build/logs/hls-fixture-server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for i in {1..60}; do
  test -f build/hls-fixtures/ready.json && break
  kill -0 "$SERVER_PID"
  sleep 1
done
test -f build/hls-fixtures/ready.json
xcrun simctl list devices available -j >build/simulator-devices.json
DEVICE=$(python3 - <<'PY'
import json
data=json.load(open('build/simulator-devices.json'))
devices=[d for runtime, values in data['devices'].items() if 'iOS' in runtime for d in values if d['name'].startswith('iPhone') and d.get('isAvailable')]
assert devices, 'No available iPhone Simulator'
print(devices[0]['udid'])
PY
)
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
open -a Simulator --args -CurrentDeviceUDID "$DEVICE"
APP=build/DerivedData-debug/Build/Products/Debug-iphonesimulator/J1ROXTV.app
# Local test networking exception applies only to the built simulator app, never source/Release.
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$APP/Info.plist"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.jirox.jiroxtv --hls-smoke-test
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.jirox.jiroxtv data)
for i in {1..150}; do
  if test -f "$CONTAINER/Documents/hls-smoke-results.json"; then break; fi
  sleep 3
done
cp "$CONTAINER/Documents/hls-smoke-results.json" build/logs/hls-smoke-results.json
xcrun simctl spawn "$DEVICE" log show --last 8m --style compact --predicate 'process == "mediaserverd" OR process == "J1ROXTV"' >build/logs/hls-system.log 2>&1 || true
xcrun simctl io "$DEVICE" screenshot build/logs/hls-smoke.png
xcrun simctl terminate "$DEVICE" com.jirox.jiroxtv || true
python3 - <<'PY'
import json
rows=json.load(open('build/logs/hls-smoke-results.json'))
for row in rows:
    print(row['status'], row['case'], row.get('error',''), 'playedTime=',row.get('playedTime'), 'resumedTime=',row.get('resumedTime'))
assert len(rows)==10 and all(row['status']=='PASS' for row in rows), 'HLS simulator tests failed; inspect hls-smoke-results.json'
PY
