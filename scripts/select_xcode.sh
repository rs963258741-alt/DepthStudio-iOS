#!/usr/bin/env bash
# Selects the newest release Xcode installed on a GitHub macOS runner (Xcode_<version>.app,
# not betas), so GitHub builds and tests use the same Xcode generation as Codemagic
# (Xcode 26). Falls back to the runner's default Xcode when none is found.
set -uo pipefail
latest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -E '/Xcode_[0-9]+(\.[0-9]+)*\.app$' | sort -V | tail -n 1)"
if [[ -n "$latest" ]]; then
  sudo xcode-select -s "$latest/Contents/Developer"
  echo "Selected $latest"
else
  echo "No Xcode_<version>.app found; using the default Xcode."
fi
xcodebuild -version
xcrun simctl list runtimes | grep -i ios || true
