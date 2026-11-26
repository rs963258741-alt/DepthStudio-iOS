from pathlib import Path
import unittest
import json

ROOT = Path(__file__).resolve().parents[1]
CONTENT = (ROOT / "ContentView.swift").read_text(encoding="utf-8")
HUD = (ROOT / "DiveHUDOverlay.swift").read_text(encoding="utf-8")
SETTINGS = (ROOT / "HUDSettings.swift").read_text(encoding="utf-8")
EXPORTER = (ROOT / "DiveVideoExporter.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")
PACKAGE = (ROOT / "scripts" / "package_ipa.py").read_text(encoding="utf-8")

class IOSFeatureWiringTests(unittest.TestCase):
    def test_photos_picker_imports_movie_and_copies_temporary_file(self):
        self.assertIn("import PhotosUI", CONTENT)
        self.assertIn("PhotosPicker(", CONTENT)
        self.assertIn("matching: .videos", CONTENT)
        self.assertIn("loadTransferable(type: ImportedMovie.self)", CONTENT)
        self.assertIn("FileRepresentation(importedContentType: .movie)", CONTENT)
        self.assertIn("copyItem(at: source, to: destination)", CONTENT)

    def test_watch_log_import_and_file_fallback_are_wired(self):
        self.assertIn("allowedContentTypes: fileImportKind == .video ? videoContentTypes : diveLogContentTypes", CONTENT)
        self.assertIn('UTType(filenameExtension: "fit", conformingTo: .data)', CONTENT)
        self.assertIn('UTType(filenameExtension: "uddf", conformingTo: .data)', CONTENT)
        self.assertIn('case "fit": record = try GarminFITParser()', CONTENT)
        self.assertIn("AtmosUDDFParser().parse(data:", CONTENT)

    def test_full_screen_and_small_logo_animation_are_wired(self):
        self.assertIn("DepthStudioColors.background.ignoresSafeArea()", CONTENT)
        self.assertIn("DepthStudioLaunchAnimation()", CONTENT)
        self.assertIn('Image("JiaoliuLogo")', CONTENT)
        self.assertIn('.frame(width: 56, height: 46)', CONTENT)
        self.assertIn("showingLaunchAnimation = false", CONTENT)
        self.assertIn("UILaunchStoryboardName: LaunchScreen", PROJECT)
        self.assertIn("- path: LaunchScreen.storyboard", PROJECT)
        self.assertTrue((ROOT / "LaunchScreen.storyboard").is_file())
        self.assertIn('maximumDepth: maximumDepth, sync: sync', CONTENT)
        self.assertIn('launch_storyboard != "LaunchScreen"', PACKAGE)

    def test_all_web_hud_fields_are_defined_and_rendered(self):
        expected = ["hudBrand", "hudClock", "identityGroup", "depthValue", "depthUnit",
                    "elapsedValue", "elapsedLabel", "tempValue", "tempLabel",
                    "speedValue", "speedLabel", "profileTitle", "profileBlock",
                    "footerBrand", "maxDepth"]
        for item_id in expected:
            self.assertIn(f'id: "{item_id}"', SETTINGS)
            self.assertIn(f'case "{item_id}"', HUD)
        self.assertIn("setAllVisible(_ visible: Bool)", SETTINGS)

    def test_editor_has_independent_transforms_visibility_identity_and_sync(self):
        for marker in ["selectedScaleBinding", "selectedRotationBinding", "resetLayout()",
                       "setAllVisible(true)", "setAllVisible(false)", "identityScale",
                       "divingType", "syncOffset", "save()"]:
            self.assertIn(marker, CONTENT + SETTINGS)

    def test_export_has_4k_audio_and_mp4_validation(self):
        self.assertIn("ExportSizing.renderSize(aspect:", EXPORTER)
        self.assertIn("isFourKClass", EXPORTER)
        self.assertIn("sourceHadAudio", EXPORTER)
        self.assertIn("audioTrackMissing", EXPORTER)
        self.assertIn('"ftyp"', EXPORTER)
        self.assertIn('"moov"', EXPORTER)
        self.assertIn('"mdat"', EXPORTER)
        self.assertIn("PHPhotoLibrary.shared().performChanges", CONTENT)

    def test_xcodegen_includes_all_new_assets_and_settings(self):
        self.assertIn("- path: HUDSettings.swift", PROJECT)
        self.assertIn("NSPhotoLibraryAddUsageDescription", PROJECT)
        for asset in ["JiaoliuLogo.imageset", "FlagROC.imageset", "FlagHongKong.imageset",
                      "FlagChina.imageset", "FlagSouthKorea.imageset", "FlagMalaysia.imageset",
                      "FlagJapan.imageset", "FlagChineseTaipei.imageset"]:
            self.assertTrue((ROOT / "Assets.xcassets" / asset).is_dir(), asset)

if __name__ == "__main__":
    unittest.main(verbosity=2)
