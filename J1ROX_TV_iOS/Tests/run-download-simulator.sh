#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs build/download-fixtures
# Build the app first, or reuse the Debug simulator compile from ios-check.
APP=build/DerivedData-debug/Build/Products/Debug-iphonesimulator/J1ROXTV.app
if ! test -d "$APP"; then
  xcodebuild -project J1ROXTV.xcodeproj -scheme J1ROXTV -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData-debug CODE_SIGNING_ALLOWED=NO build >build/logs/download-build.log 2>&1
fi
swiftc -parse-as-library Tests/CreateDownloadFixture.swift -o build/create-download-fixture
FIXTURE="build/download-fixtures/$(uuidgen).mp4"
build/create-download-fixture "$FIXTURE"
python3 Tests/download-fixture-server.py "$FIXTURE" >build/logs/download-server.log 2>&1 &
SERVER_PID=$!
DEVICE=""
cleanup() {
  if test -n "$SERVER_PID"; then kill "$SERVER_PID" 2>/dev/null || true; fi
  if test -n "$DEVICE"; then
    xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
    xcrun simctl delete "$DEVICE" 2>/dev/null || true
  fi
}
trap cleanup EXIT
for i in {1..30}; do
  if curl -fsS http://127.0.0.1:18766/metadata >build/download-fixtures/metadata.json; then break; fi
  kill -0 "$SERVER_PID"
  sleep 1
done
test -s build/download-fixtures/metadata.json
xcrun simctl list -j >build/download-fixtures/simulators.json
read -r TYPE RUNTIME < <(python3 - <<'PY'
import json
data = json.load(open('build/download-fixtures/simulators.json'))
runtime, device = next((runtime, device) for runtime, devices in data['devices'].items()
                       if 'iOS' in runtime for device in devices
                       if device.get('isAvailable') and device['name'].startswith('iPhone'))
print(device['deviceTypeIdentifier'], runtime)
PY
)
DEVICE=$(xcrun simctl create "J1ROX Downloads Smoke" "$TYPE" "$RUNTIME")
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
# Exception is applied only to the built simulator app, never to production Info.plist.
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$APP/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Set :NSAppTransportSecurity:NSAllowsLocalNetworking true' "$APP/Info.plist"
xcrun simctl install "$DEVICE" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.jirox.jiroxtv data)
run_phase() {
  local phase="$1"
  shift
  xcrun simctl launch "$DEVICE" com.jirox.jiroxtv --download-smoke-test "$@"
  for i in {1..180}; do
    if test -f "$CONTAINER/Documents/download-$phase.json"; then break; fi
    sleep 2
  done
  cp "$CONTAINER/Documents/download-$phase.json" "build/logs/download-$phase.json"
  python3 - "$phase" <<'PY'
import json, sys
result = json.load(open(f'build/logs/download-{sys.argv[1]}.json'))
print(result)
assert result['status'] == 'PASS', result
PY
  xcrun simctl terminate "$DEVICE" com.jirox.jiroxtv
}
run_phase prepare
run_phase restore --restore
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
# The only video source is now unavailable. Playback must use the saved file.
run_phase offline --offline
echo "PASS download queue, pause/resume, cancellation, HTTP errors, relaunch and local AVPlayer playback"
