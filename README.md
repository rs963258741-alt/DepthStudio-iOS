# Depth Studio Web Preview V8.18

## V8.18 basis
- Uses the complete V8.17 project supplied for this revision.
- Keeps the Garmin FIT importer in `fit-import.js` and the existing UDDF/XML import branch unchanged.
- Keeps the existing HUD, interpolation, editing controls, OPFS chunked MP4 writing, `Mp4OutputFormat({ fastStart: false })`, MP4 container checks, and video/audio track verification.
- Retains only the direct-file download route already confirmed by the user: `URL.createObjectURL(completedFile)` assigned to the download anchor with its `download` filename.
- The completed-file anchor is labelled **輸出影片**. The initial button labelled **輸出高畫質影片（至少 4K）** remains the action that starts video generation; it is not a second download route.
- Removes the Service Worker streaming download, iPhone share-sheet download option, and manual previous-export recovery button. Export no longer waits for a Service Worker before starting.
- Attempts to unregister the legacy Depth Studio `sw.js` worker when the page loads. `sw.js` is retained unchanged in this archive but is not registered or used by V8.18.
- The export error handler still attempts an automatic recovery of the current output if an error occurs after OPFS writing; any recovered result uses the same single **輸出影片** link.

## V8.17 changes retained
- Adds Garmin FIT import through a separate `fit-import.js` module; the FIT SDK is loaded only when a `.fit` file is selected.
- Uses Garmin’s official `@garmin/fitsdk` JavaScript decoder, pinned to version `21.222.0`.
- Validates the FIT header, total size and CRC with the SDK before decoding messages.
- Reads time-stamped `recordMesgs` depth samples and uses `diveSummaryMesgs` for Garmin-reported average / maximum depth when available.
- Keeps the existing UDDF XML parsing branch unchanged; `.uddf` and `.xml` continue through the original parser.
- Rejects FIT files without at least two valid time-stamped depth samples before replacing the active dive data.

## V8.16 MP4 validation retained
- Validates top-level ISO-BMFF/MP4 boxes (`ftyp`, `mdat`, `moov`) and their boundaries.
- Allows the valid `moov`-after-`mdat` layout used by `fastStart: false`.
- Reopens the finished MP4 with Mediabunny and checks the video track, codec decodability, output dimensions, sampled packet count, and audio-track retention when the source has audio.
- Compares OPFS final file size against the final written position.
- Does not expose an output file as complete when verification fails.

## Exporting a Garmin FIT file
- Garmin Connect website: open the specific dive activity, open its settings menu, then choose `Export File`.
- Garmin Dive app: open `You` → `Dive Logs` → the dive → the three-dot menu → `Export Dive as FIT File`.
- Use the single-dive `.FIT` file. ZIP archives, CSV exports, and wellness FIT files are not the intended input for this importer.
- The Garmin FIT export may omit some data that is visible in Garmin Dive; missing temperature samples are left blank rather than estimated.

## Deployment
- The deployed app needs `index.html` and `fit-import.js` in the same project root.
- `sw.js` is retained in this archive but is no longer used by V8.18. It does not need to be registered or modified.
- `tests/` contains development tests and is not required for the live page. It is safe to keep in the repository.

## Validation
- Run FIT normalizer unit tests with: `node --test tests/fit-import.test.mjs`.
- The FIT parser loads Garmin’s pinned browser ESM package from jsDelivr only when a `.fit` file is selected, so the first FIT import requires an internet connection.
- Static syntax checks and all 9 FIT normalizer unit tests pass in the build environment.
- A real Garmin FIT file and iPhone Safari were not available for end-to-end testing in this revision. The final export/download should still be verified on the target iPhone.

## Native iOS APP migration — Phase 1

This archive also contains the original SwiftUI iOS project. Phase 1 adds native Garmin FIT import while keeping the existing UDDF parser and shared `DiveRecord` data model.

- The iOS target now links Garmin's official FIT Objective-C / C++ SDK through Swift Package Manager (`FIT` product).
- The dependency is pinned to Garmin FIT SDK 21.222.0 commit `c952434903a440ff44649ffa7f8c967a692f4b19`.
- `GarminFITParser.swift` validates the FIT header and CRC, decodes timestamped depth records, collapses duplicate timestamps, reads dive summary maximum / average depth, and uses explicit water-temperature developer fields before the native FIT temperature field.
- `ContentView.swift` now accepts `.fit`, `.uddf`, and `.xml` using one dive-log import control. Parsing runs off the main thread; the resulting data continues through the existing `DiveRecord`, interpolator, and preview.
- The website files (`index.html`, `fit-import.js`, and `sw.js`) are not changed by this native-import phase.
- The current native HUD editor and native video-export implementation are still the original app drafts. Full V8.18 HUD editing and export parity are later migration phases; this Phase 1 archive does not claim those features are complete in the APP.

### Native build

The Xcode project is generated from `project.yml` using XcodeGen. The existing `codemagic.yaml` workflow performs this generation and builds the iOS target. The first build requires network access so Swift Package Manager can resolve the pinned Garmin FIT SDK revision.

### Native validation performed in this environment

- Swift syntax parse: passed for all project `.swift` files.
- FIT parser static stub checks are limited and are not proof of the Objective-C SDK's Swift-imported API names. The latest Codemagic compiler diagnostic identified the required Swift name `getValueFor(_:)`, and the parser was updated accordingly.
- `project.yml` YAML parsing and XcodeGen package/source declarations: passed.
- iOS SDK / Xcode build and on-device FIT decoding: not run in this Linux environment; verify in Codemagic and on the target iPhone before proceeding to Phase 2.
