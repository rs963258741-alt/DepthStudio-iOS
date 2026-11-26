#!/usr/bin/env bash
# Run the XCTest unit/integration tests and the UI tests on an iPhone simulator.
#
# Outputs:
#   build/xcodebuild-test.log
#   build/test-artifacts/*.png   preview-vs-export comparison images written by the tests
#   build/test-summary.txt       passed / failed test cases
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build"
LOG="$BUILD_DIR/xcodebuild-test.log"
mkdir -p "$BUILD_DIR/test-artifacts"
xcodebuild -version

if ! command -v xcodegen >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
fi
xcodegen generate --spec project.yml

DEVICE_ID="$(xcrun simctl list devices available -j | python3 scripts/pick_simulator.py)"
echo "Simulator: $(xcrun simctl list devices available | grep "$DEVICE_ID" | head -n1)"
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true

set +e +o pipefail
xcodebuild test \
  -project DepthStudio.xcodeproj \
  -scheme DepthStudio \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$BUILD_DIR/TestDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$LOG" | grep --line-buffered -E "Test Case .*(passed|failed)|: error: |^\*\* [A-Z ]+ \*\*"
STATUS=${PIPESTATUS[0]}
set -e -o pipefail

{
  echo "xcodebuild test exit status: $STATUS"
  echo "passed: $(grep -cE "Test Case .* passed" "$LOG" || true)"
  echo "failed: $(grep -cE "Test Case .* failed" "$LOG" || true)"
  echo "---- failures ----"
  grep -E ": error: |Test Case .* failed" "$LOG" | sort -u | head -100 || true
} > "$BUILD_DIR/test-summary.txt"
echo
echo "================ TEST SUMMARY ================"
cat "$BUILD_DIR/test-summary.txt"
echo "=============================================="
ls -l "$BUILD_DIR/test-artifacts" || true
exit "$STATUS"
