"""Static checks for the third round of requested changes (behaviour is covered by the
XCTest unit and UI tests: AppTests/Round3UnitTests.swift, AppTests/ExportPipelineTests.swift,
AppUITests/Round3UITests.swift)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")
DEPTH_VIEW, POOL_VIEW = read("ContentView.swift"), read("PoolModeView.swift")
STYLE, SHARED, EXPORTER = read("HUDStyle.swift"), read("StudioShared.swift"), read("DiveVideoExporter.swift")
COMPOSITOR, PROJECT = read("HUDVideoCompositor.swift"), read("project.yml")


class ExportTests(unittest.TestCase):
    def test_every_frame_is_composed_with_the_hud_of_its_time(self):
        self.assertIn("customVideoCompositorClass = HUDVideoCompositor.self", EXPORTER)
        self.assertNotIn("animationTool", EXPORTER)
        self.assertIn("overlay.overlay(at: time)", COMPOSITOR)
        for name in ("HUDStyle.swift", "HUDVideoCompositor.swift", "UITestSupport.swift"):
            self.assertIn(f"- path: {name}", PROJECT)

    def test_output_follows_the_source_quality_and_button_is_renamed(self):
        self.assertIn("sourceSize: sourceSize", EXPORTER)
        self.assertIn("static let maximumPixelCount: CGFloat = 3840 * 2160", SHARED)
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn('"輸出影片（另存新檔）"', view)
            self.assertNotIn("輸出高畫質影片（至少 4K）", view)
            self.assertIn("ExportSizing.qualityLabel(for: size)", view)


class LayoutAndStyleTests(unittest.TestCase):
    def test_two_presets_and_their_apply_buttons(self):
        self.assertIn('Label("將目前排版設為預設\\(slot)"', STYLE)
        self.assertIn('"預設\\(slot)"', STYLE)
        self.assertIn("static let all = [1, 2]", STYLE)
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn("HUDPresetButtons(savedSlots: savedPresetSlots", view)
            self.assertIn('Button("設為預設\\(slot)")', view)

    def test_colour_shadow_and_contrast_per_field(self):
        for marker in ("ColorPicker(", '"字體顏色"', 'styleSlider("陰影"', 'styleSlider("對比"'):
            self.assertIn(marker, STYLE)
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn("HUDStyleEditor(", view)
        for name in ("HUDSettings.swift", "PoolHUDSettings.swift"):
            settings = read(name)
            self.assertIn("var styles: [String: HUDItemStyle]", settings)
            self.assertIn("decodeIfPresent([String: HUDItemStyle].self, forKey: .styles)", settings)

    def test_live_proportional_floating_preview_and_centre_snap(self):
        self.assertNotIn("VideoStillView", SHARED + DEPTH_VIEW + POOL_VIEW + read("DiveVideoPreview.swift"))
        self.assertIn("PlayerLayerView(player: playback.player)", read("DiveVideoPreview.swift"))
        self.assertIn("PlayerLayerView(player: playback.player)", POOL_VIEW)
        self.assertIn("func fontSize(unit: CGFloat) -> CGFloat { max(minimum * HUDMetrics.point(unit: unit), unit * size) }", STYLE)
        for name in ("DiveHUDOverlay.swift", "PoolHUDOverlay.swift"):
            self.assertIn("HUDSnapping.snap(", read(name))


class PoolAITests(unittest.TestCase):
    def test_reminder_before_ai_analysis(self):
        self.assertIn("使用此功能容易受到影片中移動的物體干擾，建議畫面都在水中穩定拍攝時再使用", POOL_VIEW)
        self.assertIn('.alert("AI 即時速率提醒", isPresented: $confirmingAIAnalysis)', POOL_VIEW)
        self.assertIn("{ confirmingAIAnalysis = true }", POOL_VIEW)


if __name__ == "__main__":
    unittest.main(verbosity=2)
