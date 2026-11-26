#!/usr/bin/env bash
# Run the XCTest unit/integration tests and the UI tests on an iPhone simulator.
#
# Outputs (collected as CI artifacts):
#   build/test-artifacts/*.png        preview-vs-export comparison images written by the tests
#   build/test-artifacts/*.ips        crash reports of the app or test runner, if any
#   build/test-artifacts/*-results.json  per-test results from the xcresult bundles
#   build/test-summary.txt            passed / failed test cases
#   build/xcodebuild-test.log
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build"
ARTIFACTS="$BUILD_DIR/test-artifacts"
LOG="$BUILD_DIR/xcodebuild-test.log"
mkdir -p "$ARTIFACTS"
: > "$LOG"
STARTED_AT="$(date +%s)"
xcodebuild -version

if ! command -v xcodegen >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
fi
xcodegen generate --spec project.yml || exit 1

DEVICE_ID="$(xcrun simctl list devices available -j | python3 scripts/pick_simulator.py)" || exit 1
echo "Simulator: $(xcrun simctl list devices available | grep "$DEVICE_ID" | head -n1)"
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
# UI tests time out ("AX loaded notification") if the simulator is still booting.
xcrun simctl bootstatus "$DEVICE_ID" -b || true

COMMON=(-project DepthStudio.xcodeproj -scheme DepthStudio -destination "id=$DEVICE_ID"
        -derivedDataPath "$BUILD_DIR/TestDerivedData" CODE_SIGNING_ALLOWED=NO)

run_tests() {  # name, extra xcodebuild args...
  local name="$1"; shift
  local bundle="$BUILD_DIR/$name.xcresult"
  rm -rf "$bundle"
  echo "==== $name ====" | tee -a "$LOG"
  xcodebuild "$@" "${COMMON[@]}" -resultBundlePath "$bundle" 2>&1 \
    | tee -a "$LOG" | grep --line-buffered -E "Test Case .*(passed|failed|skipped)|: error: |Restarting after|\[export-test\]|^\*\* [A-Z ]+ \*\*"
  local status=${PIPESTATUS[0]}
  xcrun xcresulttool get test-results tests --path "$bundle" > "$ARTIFACTS/$name-results.json" 2>/dev/null || true
  return "$status"
}

# Build once, then run the unit/integration tests and the UI tests separately.
xcodebuild build-for-testing "${COMMON[@]}" 2>&1 | tee -a "$LOG" | grep --line-buffered -E ": error: |^\*\* [A-Z ]+ \*\*"
BUILD_STATUS=${PIPESTATUS[0]}
UNIT_STATUS=1
UI_STATUS=1
if [[ "$BUILD_STATUS" -eq 0 ]]; then
  run_tests unit-tests test-without-building -only-testing:DepthStudioTests
  UNIT_STATUS=$?
  run_tests ui-tests test-without-building -only-testing:DepthStudioUITests
  UI_STATUS=$?
  if [[ "$UI_STATUS" -ne 0 ]] && grep -q "failed to initialize for UI testing" "$LOG"; then
    echo "UI test runner failed to start; restarting the simulator and retrying once." | tee -a "$LOG"
    xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$DEVICE_ID" -b || true
    run_tests ui-tests-retry test-without-building -only-testing:DepthStudioUITests
    UI_STATUS=$?
  fi
fi

# Crash reports of the app or the test runners written during this run.
find "$HOME/Library/Logs/DiagnosticReports" -name "*.ips" -newermt "@$STARTED_AT" 2>/dev/null \
  | grep -E "Depth|xctest|Runner" | while read -r report; do cp "$report" "$ARTIFACTS/" ; done

{
  echo "build-for-testing: $BUILD_STATUS   unit tests: $UNIT_STATUS   UI tests: $UI_STATUS"
  echo "passed: $(grep -cE "Test Case .* passed" "$LOG" || true)"
  echo "failed: $(grep -cE "Test Case .* failed" "$LOG" || true)"
  echo "---- failures ----"
  grep -E ": error: |Test Case .* failed|Restarting after|failed to initialize" "$LOG" | sort -u | head -100 || true
} > "$BUILD_DIR/test-summary.txt"
echo
echo "================ TEST SUMMARY ================"
cat "$BUILD_DIR/test-summary.txt"
echo "=============================================="
ls -l "$ARTIFACTS" || true
[[ "$BUILD_STATUS" -eq 0 && "$UNIT_STATUS" -eq 0 && "$UI_STATUS" -eq 0 ]]
