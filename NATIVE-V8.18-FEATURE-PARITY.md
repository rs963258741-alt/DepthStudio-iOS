# Native iOS vs Web V8.18 — Feature Parity Audit

Source baseline: `DepthStudio_WebPreview_V8_18(2).zip` supplied by the user.

## HUD model parity

The app defines and renders the same fifteen V8.18 items: `hudBrand`, `hudClock`, `identityGroup`, `depthValue`, `depthUnit`, `elapsedValue`, `elapsedLabel`, `tempValue`, `tempLabel`, `speedValue`, `speedLabel`, `profileTitle`, `profileBlock`, `footerBrand`, and `maxDepth`.

The default layout positions and visibility dictionary are compared against the V8.18 `DEFAULT_LAYOUT` and `DEFAULT_VISIBILITY` in `tests/test_web_native_parity.py`.

## Controls and identity parity

- Independent x/y position, 30–300% transform scale, 0–359° rotation, right-angle shortcuts, reset-one-item and reset-layout.
- Drag snap between visible item centers using the V8.18 2% threshold.
- Global opacity 20–100%, text scale 70–140%, vertical offset -15–25%, and watch/video offset -120–120 seconds.
- Individual visibility toggles plus show-all/hide-all.
- Name default `name`, 30-character cap, the same seven country/region choices and six dive types, and identity-group scale 60–180%.
- HUD settings persist in UserDefaults instead of Safari LocalStorage.

## Import and preview parity

- Video: PhotosPicker (direct iPhone Photos selection) plus Files fallback.
- Dive log: Garmin FIT, ATMOS UDDF and XML.
- FIT parser remains based on Garmin's pinned native SDK; the existing UDDF parser is retained.
- Preview uses a 9:16 stage, transparent HUD, interpolated telemetry, a depth profile with metre labels and three equal time divisions, and a moving playhead.

## Export parity with iOS-native delivery

- MP4 export, long edge at least 3840 px, with original display aspect ratio retained.
- HUD is composited into the video through AVFoundation/Core Animation.
- Output validation checks MP4 top-level boxes, expected output dimensions, video sample count, recognised codec subtype, first-frame decoding, and audio-track retention when the source has audio.
- Final video is saved to Photos, with ShareLink as a user-controlled alternative. This replaces the browser's OPFS/direct-download delivery path with the iOS-native equivalent.

## Branding

Uses the supplied white/silver-on-transparent “Jiaoliu / Freediving” logo variant because it is more legible against the app's dark ocean background. It appears small in the launch animation and the main-screen header.

## Remaining runtime verification

Static tests do not prove actual PhotosPicker permissions/provider behaviour, Xcode API availability, iPhone-specific rendering or long 4K export success. These require the next Codemagic build and device acceptance test. Do not treat static checks as a completed iPhone test.

## Full-screen device presentation

The native target includes a `LaunchScreen.storyboard` using the chosen white/silver Jiaoliu logo on the dark ocean background, and validates the compiled storyboard in the IPA. This is the targeted fix for the 2:3 legacy letterboxing seen in the supplied iPhone recording; final full-device sizing must still be verified on the next iPhone install. The app then transitions to the animated SwiftUI intro.
