# Native iOS build fix — follow-up 2026-11-24

## First Codemagic error
The first build failed because the Swift-imported SDK method returns a non-optional `NSNumber`, so optional chaining was invalid.

## Follow-up Codemagic error
The second build passed the Optional-chaining error and reported:

`'getValueForIndex' has been renamed to 'getValueFor(_:)'`

The pinned Garmin FIT SDK exposes the Objective-C selector `getValueForIndex:`. Xcode's Swift importer renames that selector for Swift source, so the correct call is `getValueFor(0)`.

## Change in this revision
- Replaced `field.getValueForIndex(0).doubleValue` with `field.getValueFor(0).doubleValue`.
- Kept the finite-value guard and existing developer-field name matching, scale, offset, and temperature range logic.
- No website runtime files (`index.html`, `fit-import.js`, `sw.js`), `project.yml`, Codemagic workflow, HUD, video exporter, or UDDF parser were changed.

## Validation boundary
- Swift syntax parsing passes locally.
- The existing JavaScript FIT normalizer tests pass (9/9).
- `project.yml` YAML and FIT package/source registration checks pass.
- Full Xcode/iOS build must still be confirmed by the next Codemagic run. This Linux environment does not contain Xcode or the iOS SDK.
