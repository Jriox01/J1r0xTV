#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
# Exercise production conditions as well as debug-only diagnostics.
for configuration in Debug Release; do
flags=(-O)
if [[ "$configuration" == Debug ]]; then flags=(-D DEBUG); fi
swiftc "${flags[@]}" -target "$(uname -m)-apple-macos13.0" -swift-version 5 -parse-as-library \
  J1ROXTV/Models/JSONValue.swift \
  J1ROXTV/Models/MediaModels.swift \
  J1ROXTV/Models/DownloadModels.swift \
  J1ROXTV/Persistence/DownloadStore.swift \
  J1ROXTV/Services/SourceAPIClient.swift \
  J1ROXTV/Networking/APIConfig.swift \
  J1ROXTV/Networking/APIClient.swift \
  J1ROXTV/Providers/*.swift \
  J1ROXTV/ViewModels/PlayerSession.swift \
  J1ROXTV/ViewModels/PlaybackSession.swift \
  Tests/Research/*.swift \
  Tests/PlaybackTests.swift \
  Tests/DownloadTests.swift \
  Tests/ProviderTests.swift \
  -o "build/provider-tests-$configuration" 2>&1 | tee "build/logs/provider-tests-$configuration-compile.log"
"build/provider-tests-$configuration" 2>&1 | tee "build/logs/provider-tests-$configuration.log"
done
