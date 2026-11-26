# Depth Studio iOS update — 2026-11-26

## Version

- App version: `1.0.3`
- Build number: `4`
- Feature baseline: user-supplied Web Preview V8.18

## Changes

- Audited the supplied V8.18 web project and aligned the native app's fifteen HUD item IDs, default positions, default visibility and identity choices.
- Kept the web app's 15 independently movable/scalable/rotatable HUD elements, 2% centre snap, opacity/font-size/vertical-offset controls, show/hide controls, identity group, seven flags, six dive types and persisted appearance settings.
- Added direct iPhone Photos video selection with PhotosPicker and CoreTransferable file copying; retained Files-app import as fallback.
- Retained Garmin FIT, ATMOS UDDF and XML import paths. FIT continues using the pinned Garmin native SDK; UDDF continues using the original parser.
- Added a 9:16 preview stage with live telemetry, depth graph, metre labels, three equal time divisions and a moving playhead.
- Retained -120 to +120 second sync offset, dive summary and native 4K MP4 export.
- Strengthened MP4 verification with container box checks, video sample counting, codec identification, first-frame decode, output size and source-audio track verification.
- Native delivery saves completed MP4 to Photos and provides ShareLink fallback; this is the iOS counterpart to V8.18 web direct download.
- Selected the supplied white/silver logo variant for dark-ocean contrast. The logo is small in the 2.7-second launch animation and main-screen header; the static launch screen uses a modest 112 × 93 pt logo.
- Added `HUDSettings.swift` to the XcodeGen target sources and added `NSPhotoLibraryAddUsageDescription` for saving exported videos.
- Added a native `LaunchScreen.storyboard` with the small white/silver Jiaoliu logo; Codemagic and the IPA packager now require the compiled storyboard to be present. This addresses the 2:3 legacy letterboxing visible in the supplied iPhone recording; real-device bounds still require confirmation after install.
- Fixed the native export call site to pass the required maximum-depth argument to `DiveVideoExporter`.
- Updated app version to `1.0.3` / build `4`.
- Preserved the successful AltStore IPA packaging layout via `scripts/package_ipa.py`; did not switch back to Windows re-compression or `ditto` packaging.

## Preserved

- Garmin FIT SDK dependency and parser.
- ATMOS UDDF parser.
- Existing `DiveDataInterpolator`, `TimelineSync`, preview and video exporter modules.
- Web V8.18 `index.html`, `fit-import.js`, `sw.js` and `tests/fit-import.test.mjs` files in this iOS repository are copied byte-for-byte from the supplied archive. The separate web repository is not modified.

## Validation completed in this environment

- Python unit tests: native wiring, V8.18 parity, and IPA packaging tests.
- Web FIT JavaScript tests: all 9 tests.
- Swift frontend syntax parse for all Swift files.
- Python bytecode compile for the IPA packaging script.
- YAML parsing, Codemagic shell syntax checks and asset catalog JSON checks (run by the final packaging validation).
- Logo and flag PNG dimension/alpha checks.
- IPA package structure simulation using the same root `Payload/` layout as the previously successful AltStore installation.

## Not verified here

This environment does not contain Apple Xcode/iOS SDK. Therefore, the following still require Codemagic and iPhone confirmation: iOS SDK type-check/build, PhotosPicker provider interaction with actual iPhone videos, physical screen layout and animation rendering, real FIT/UDDF selection, and long 4K MP4 export/save-to-Photos behaviour.
