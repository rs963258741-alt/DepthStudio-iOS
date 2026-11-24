# Depth Studio native APP migration

## Current checkpoint: Phase 1 — FIT + UDDF import

### What is included
- Native iOS app remains SwiftUI / AVFoundation based.
- FIT and UDDF / XML are selected from a single dive-log picker.
- FIT is decoded by Garmin's official native Objective-C / C++ FIT SDK with SwiftFIT listener support.
- FIT and UDDF normalize into the existing `DiveRecord` / `DiveSample` model.
- Existing `DiveDataInterpolator`, `TimelineSync`, and `DiveVideoPreview` remain in place.
- Parsing runs on a background queue so file decoding does not block the SwiftUI interface.

### Files changed in this checkpoint
- `project.yml`: add the pinned Garmin FIT package and register the new Swift source.
- `ContentView.swift`: add FIT / UDDF / XML import routing, progress state, and source metadata.
- `GarminFITParser.swift`: new native FIT decoder / normalizer.
- `README.md`: record native migration status.
- `fit-import.test.mjs`: moved to `tests/` to match the existing documented test command and import path.

### Deliberately not changed
- `index.html` and the validated V8.18 website FIT / UDDF and export pipeline.
- `AtmosUDDFParser.swift`.
- `DiveDataInterpolator.swift`.
- `TimelineSync.swift`.
- `DiveHUDOverlay.swift`.
- `DiveVideoPreview.swift`.
- `DiveVideoExporter.swift`.
- `DepthStudioApp.swift`.

### Known remaining migration work
1. Port the website HUD layout and every independent edit control to native SwiftUI.
2. Port identity controls (name default `name`, country flag, dive type), per-item visibility, drag, scale, rotation snapping, and alignment guides.
3. Port time synchronization controls and graph presentation to match V8.18.
4. Replace / complete the native video-export draft so it matches V8.18 output requirements (4K target, frame-by-frame telemetry, source audio retention, MP4 validation, progress, and save-to-files/photos).
5. Compare native APP outputs with the already verified website outputs for both FIT and UDDF sample logs.

## Build procedure
1. Upload the updated project files to the existing GitHub `DepthStudio` repository, preserving the website files.
2. Run the existing Codemagic `depth-studio-unsigned-ios` workflow.
3. Confirm that XcodeGen resolves the pinned `FIT` package and the iOS target builds.
4. Install the test build on the iPhone and verify importing one known Garmin FIT file and one known ATMOS UDDF file.
5. Only after both import tests pass should Phase 2 change the HUD UI.

## Validation boundary
This archive was checked for Swift syntax, project YAML structure, FIT parser API-shape, and the existing website FIT normalizer tests. It was not built with Xcode or run on an iPhone in this environment. The app is not yet at full V8.18 feature parity.
