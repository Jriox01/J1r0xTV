#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
summary=build/logs/regression-summary.txt
printf 'Application Debug and Release build stages completed before these tests.\n' > "$summary"
failed=0
run_suite() {
  local name="$1"
  local script="$2"
  local result=0
  printf '\n=== TEST SUITE: %s ===\n' "$name"
  if bash "$script" 2>&1 | tee "build/logs/$name.log"; then
    printf 'PASS %s\n' "$name" | tee -a "$summary"
  else
    result=$?
    printf 'FAIL %s (exit %s); see %s.log\n' "$name" "$result" "$name" | tee -a "$summary"
    failed=1
  fi
}

# Keep suites independent: a test compilation/runtime failure must not hide
# the other suite results or be confused with an application build failure.
run_suite provider-and-series Tests/run-provider-tests.sh
run_suite hls-simulator Tests/run-hls-simulator.sh
run_suite download-simulator Tests/run-download-simulator.sh
bash Tests/run-zona-smoke.sh || printf "Zona live diagnostic could not run\n"
cat "$summary"
exit "$failed"
