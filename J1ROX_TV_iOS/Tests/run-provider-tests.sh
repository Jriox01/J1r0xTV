#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
swiftc -D DEBUG -target "$(uname -m)-apple-macos13.0" -swift-version 5 -parse-as-library \
  J1ROXTV/Models/JSONValue.swift \
  J1ROXTV/Models/MediaModels.swift \
  J1ROXTV/Networking/APIConfig.swift \
  J1ROXTV/Networking/APIClient.swift \
  J1ROXTV/Providers/*.swift \
  J1ROXTV/ViewModels/PlayerSession.swift \
  J1ROXTV/ViewModels/PlaybackSession.swift \
  Tests/Research/*.swift \
  Tests/PlaybackTests.swift \
  Tests/ProviderTests.swift \
  -o build/provider-tests 2>&1 | tee build/logs/provider-tests-compile.log
build/provider-tests 2>&1 | tee build/logs/provider-tests.log
