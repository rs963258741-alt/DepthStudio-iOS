from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WEB = (ROOT / "index.html").read_text(encoding="utf-8")
SETTINGS = (ROOT / "HUDSettings.swift").read_text(encoding="utf-8")
HUD = (ROOT / "DiveHUDOverlay.swift").read_text(encoding="utf-8")
CONTENT = (ROOT / "ContentView.swift").read_text(encoding="utf-8")
EXPORTER = (ROOT / "DiveVideoExporter.swift").read_text(encoding="utf-8")


# Intentional native differences from the web V8.18 HUD (user requests, 1.4):
# the depth unit is part of the depth value (fixed at its bottom right, so the value
# moved right to keep the number where it was), and the vertical depth gauge is new.
MERGED_INTO_VALUE = {"depthUnit"}
NATIVE_ONLY = {"depthGauge": (86.0, 46.0, True)}
MOVED = {"depthValue": (20.0, 18.0)}


class WebV818NativeParityTests(unittest.TestCase):
    def test_native_has_the_web_hud_items_with_the_unit_merged_and_the_gauge_added(self):
        web_ids = re.findall(r'<div class="hud-item(?: [^"]*)?" id="([A-Za-z0-9]+)"', WEB)
        hud_section = SETTINGS.split("struct HUDCountryOption", 1)[0]
        native_ids = re.findall(r'\.init\(id: "([A-Za-z0-9]+)"', hud_section)
        self.assertEqual(len(web_ids), 15)
        self.assertEqual((set(web_ids) - MERGED_INTO_VALUE) | set(NATIVE_ONLY), set(native_ids))
        for item_id in native_ids:
            self.assertIn(f'case "{item_id}"', HUD + EXPORTER)
        # The unit is drawn with the depth value.
        self.assertIn('live: { String(format: "%.1f", $0.depthMeters) }, unit: "M")', EXPORTER)

    def test_native_defaults_match_web_layout_and_visibility(self):
        layout_match = re.search(r'const DEFAULT_LAYOUT=\{([^}]+)\}', WEB)
        self.assertIsNotNone(layout_match)
        web_layout = {
            key: (float(x), float(y))
            for key, x, y in re.findall(r'([A-Za-z0-9]+):\[([0-9.]+),([0-9.]+)\]', layout_match.group(1))
        }
        native_layout = {
            key: (float(x), float(y))
            for key, x, y in re.findall(r'"([A-Za-z0-9]+)": HUDPoint\(x: ([0-9.]+), y: ([0-9.]+)\)', SETTINGS)
        }
        expected_layout = {key: value for key, value in web_layout.items() if key not in MERGED_INTO_VALUE}
        expected_layout.update(MOVED)
        expected_layout.update({key: (x, y) for key, (x, y, _) in NATIVE_ONLY.items()})
        self.assertEqual(expected_layout, native_layout)

        visibility_match = re.search(r'const DEFAULT_VISIBILITY=\{([^}]+)\}', WEB)
        self.assertIsNotNone(visibility_match)
        web_visibility = {key: value == "true" for key, value in re.findall(r'([A-Za-z0-9]+):(true|false)', visibility_match.group(1))}
        native_visibility = {key: value == "true" for key, value in re.findall(r'"([A-Za-z0-9]+)": (true|false)', SETTINGS)}
        expected_visibility = {key: value for key, value in web_visibility.items() if key not in MERGED_INTO_VALUE}
        expected_visibility.update({key: shown for key, (_, _, shown) in NATIVE_ONLY.items()})
        self.assertEqual(expected_visibility, native_visibility)

    def test_identity_options_match_web(self):
        for flag in ["roc", "hongkong", "china", "southkorea", "malaysia", "japan", "chinesetaipei"]:
            self.assertIn(f'.init(id: "{flag}"', SETTINGS)
            self.assertIn(f'<option value="{flag}"', WEB)
        for dive_type in ["CWTB", "CNF", "CWT", "FIM", "VWT", "DPV"]:
            self.assertIn(f'"{dive_type}"', SETTINGS)
            self.assertIn(f'<option value="{dive_type}"', WEB)
        self.assertIn('"name"', SETTINGS)
        self.assertIn('"chinesetaipei"', SETTINGS)

    def test_editor_ranges_and_reset_actions_match_web(self):
        # The ±120 s sync range is the 手動同步 slider (DiveSync.swift) since 1.5.
        sync = (ROOT / "DiveSync.swift").read_text(encoding="utf-8")
        for marker in ["0.3...3.0", "0...359", "0.2...1.0", "0.7...1.4", "-15...25", "-120...120", "0.6...1.8"]:
            self.assertIn(marker, CONTENT + sync)
        for action in ["恢復預設位置", "重設此項目", "全部顯示", "全部隱藏", "重設外觀"]:
            self.assertIn(action, CONTENT)
        self.assertIn("(threshold 2% of stage)", HUD)
        self.assertIn("static let threshold = 2.0", (ROOT / "StudioShared.swift").read_text(encoding="utf-8"))
        self.assertIn("UserDefaults", SETTINGS)

    def test_native_has_video_data_import_preview_and_platform_export(self):
        self.assertIn("PhotosPicker(", CONTENT)
        self.assertIn("GarminFITParser().parse", CONTENT)
        self.assertIn("AtmosUDDFParser().parse", CONTENT)
        self.assertIn("aspectRatio(9.0 / 16.0", CONTENT + (ROOT / "DiveVideoPreview.swift").read_text(encoding="utf-8"))
        self.assertIn("ExportSizing.renderSize(aspect:", EXPORTER)
        self.assertIn("HUDVideoCompositor", EXPORTER)
        self.assertIn("countCompressedVideoSamples", EXPORTER)
        self.assertIn("decodeFirstVideoFrame", EXPORTER)
        self.assertIn("PhotoLibrarySaver.saveNewVideo(at:", CONTENT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
