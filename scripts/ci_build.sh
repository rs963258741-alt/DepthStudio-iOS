#!/usr/bin/env bash
# Build the unsigned iOS Release app and package build/DepthStudio.ipa for AltStore.
#
# Shared by .github/workflows/ios-build.yml and codemagic.yaml so both CI
# services build the same way. Runs on macOS with Xcode.
#
# Version numbers come from project.yml:
#   MARKETING_VERSION        -> CFBundleShortVersionString (bump this for a new release)
#   CURRENT_PROJECT_VERSION  -> CFBundleVersion, unless APP_BUILD_NUMBER is set
#
# Outputs:
#   build/DepthStudio.ipa
#   build/xcodebuild-release.log
#   build/build-info.env      (APP_VERSION, APP_BUILD_NUMBER, BUNDLE_ID, APP_NAME)
set -euo pipefail
cd "$(dirname "$0")/.."

read_setting() {
  sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$/\1/p" project.yml | head -n1
}

APP_VERSION="$(read_setting MARKETING_VERSION)"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-$(read_setting CURRENT_PROJECT_VERSION)}"
EXPECTED_BUNDLE_ID="$(read_setting PRODUCT_BUNDLE_IDENTIFIER)"
SCHEME="DepthStudio"
BUILD_DIR="build"
LOG="$BUILD_DIR/xcodebuild-release.log"

[[ -n "$APP_VERSION" && -n "$APP_BUILD_NUMBER" && -n "$EXPECTED_BUNDLE_ID" ]] || {
  echo "ERROR: could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION / PRODUCT_BUNDLE_IDENTIFIER from project.yml"
  exit 1
}
echo "Building $EXPECTED_BUNDLE_ID $APP_VERSION ($APP_BUILD_NUMBER)"
xcodebuild -version

mkdir -p "$BUILD_DIR"

# --- XcodeGen ---------------------------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
fi
xcodegen generate --spec project.yml
test -d DepthStudio.xcodeproj

# --- Swift packages -----------------------------------------------------------
xcodebuild -resolvePackageDependencies -project DepthStudio.xcodeproj -scheme "$SCHEME"

# --- Build --------------------------------------------------------------------
# The full log goes to $LOG; the console only shows errors and the result line,
# and a failure summary is printed last so it is at the end of the CI log.
set +e +o pipefail
xcodebuild \
  -project DepthStudio.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$APP_BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee "$LOG" | grep --line-buffered -E ': (fatal )?error: |^\*\* [A-Z ]+ \*\*'
BUILD_STATUS=${PIPESTATUS[0]}
set -e -o pipefail

WARNINGS=$(grep -E ': warning: ' "$LOG" | sort -u | wc -l | tr -d ' ')
echo "xcodebuild exit status: $BUILD_STATUS, unique warnings: $WARNINGS"

if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo
  echo "================ BUILD FAILURE SUMMARY ================"
  if grep -qE ': (fatal )?error: |^error: ' "$LOG"; then
    grep -E ': (fatal )?error: |^error: ' "$LOG" | sort -u | head -80
    echo "------- context around the first errors -------"
    grep -nE -B2 -A6 ': (fatal )?error: ' "$LOG" | head -150
  else
    echo "(no compiler error lines found; last 120 lines of the log follow)"
    tail -n 120 "$LOG"
  fi
  echo "======================================================="
  exit "$BUILD_STATUS"
fi

# --- Validate the app bundle --------------------------------------------------
APP_DIR="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos"
APP_PATH="$(find "$APP_DIR" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || { echo "ERROR: No .app bundle found in $APP_DIR"; exit 1; }

PLIST="$APP_PATH/Info.plist"
[[ -f "$PLIST" ]] || { echo "ERROR: Info.plist missing"; exit 1; }
/usr/bin/plutil -lint "$PLIST"

# Stamp the version again in case a build setting overrode it. The app is
# unsigned, so editing Info.plist after the build is safe.
stamp() {
  if /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"
  else
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
  fi
}
stamp CFBundleShortVersionString "$APP_VERSION"
stamp CFBundleVersion "$APP_BUILD_NUMBER"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
BUNDLE_ID="$(plist CFBundleIdentifier)"
EXECUTABLE="$(plist CFBundleExecutable)"
LAUNCH_STORYBOARD="$(plist UILaunchStoryboardName)"

[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || { echo "ERROR: Unexpected Bundle ID: $BUNDLE_ID"; exit 1; }
[[ "$LAUNCH_STORYBOARD" == "LaunchScreen" ]] || { echo "ERROR: Launch storyboard is not configured"; exit 1; }
[[ -d "$APP_PATH/LaunchScreen.storyboardc" || -d "$APP_PATH/Base.lproj/LaunchScreen.storyboardc" ]] || {
  echo "ERROR: LaunchScreen storyboard was not compiled into the app. Compiled storyboards found:"
  find "$APP_PATH" -maxdepth 2 -name '*.storyboardc' -print
  exit 1
}
[[ -s "$APP_PATH/$EXECUTABLE" ]] || { echo "ERROR: App executable missing or empty"; exit 1; }
[[ -s "$APP_PATH/Assets.car" ]] || { echo "ERROR: Assets.car missing or empty"; exit 1; }
[[ -d "$APP_PATH/FIT_cppfit.bundle" ]] || { echo "ERROR: FIT_cppfit.bundle missing"; exit 1; }

ARCHS="$(xcrun lipo -archs "$APP_PATH/$EXECUTABLE")"
echo "App executable architectures: $ARCHS"
[[ " $ARCHS " == *" arm64 "* ]] || { echo "ERROR: iPhone arm64 architecture missing"; exit 1; }

# --- Package ------------------------------------------------------------------
python3 scripts/package_ipa.py \
  --app "$APP_PATH" \
  --output "$BUILD_DIR/DepthStudio.ipa" \
  --expect-version "$APP_VERSION" \
  --expect-build "$APP_BUILD_NUMBER"

[[ -s "$BUILD_DIR/DepthStudio.ipa" ]] || { echo "ERROR: IPA output missing"; exit 1; }

cat > "$BUILD_DIR/build-info.env" <<EOF
APP_VERSION=$APP_VERSION
APP_BUILD_NUMBER=$APP_BUILD_NUMBER
BUNDLE_ID=$BUNDLE_ID
APP_NAME="$(basename "$APP_PATH" .app)"
EOF

echo "SUCCESS: $BUILD_DIR/DepthStudio.ipa ($BUNDLE_ID $APP_VERSION build $APP_BUILD_NUMBER)"
