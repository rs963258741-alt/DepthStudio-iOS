"""Static checks for the second round of requested changes (the Swift behaviour itself is
covered by the XCTest unit and UI tests in AppTests/ and AppUITests/)."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")
DEPTH_VIEW, POOL_VIEW = read("ContentView.swift"), read("PoolModeView.swift")
DEPTH_HUD, POOL_HUD = read("DiveHUDOverlay.swift"), read("PoolHUDOverlay.swift")
EXPORTER, FACTORY = read("DiveVideoExporter.swift"), read("HUDLayerFactory.swift")
POOL_EXPORT, SHARED = read("PoolVideoHUDLayer.swift"), read("StudioShared.swift")


class DraggingTests(unittest.TestCase):
    def test_gestures_are_attached_before_position(self):
        # .position() makes a view as large as the stage; a gesture added after it
        # captured touches everywhere, so only the top item (the chart) could be dragged.
        for hud in (DEPTH_HUD, POOL_HUD):
            item = hud[hud.index("hudItem(definition.id"):]
            item = item[:item.index(".position(") + 10]
            self.assertIn(".gesture(dragGesture(", item)
            self.assertIn(".contentShape(Rectangle())", item)
            self.assertIn(".allowsHitTesting(isEditing)", item)
            self.assertIn('accessibilityIdentifier("hud.\\(definition.id)")', item)
            self.assertIn("coordinateSpace: .global", hud)


class LayoutDefaultTests(unittest.TestCase):
    def test_both_modes_have_set_default_restore_and_free_layout_switch(self):
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn("將目前排版設為預設", view)
            self.assertIn("hudSettings.saveLayoutAsDefault()", view)
            self.assertIn("恢復預設位置", view)
            self.assertIn("開啟任意排版", view)
            self.assertIn("Toggle(isOn: $isEditingLayout)", view)
        for name in ("HUDSettings.swift", "PoolHUDSettings.swift"):
            settings = read(name)
            self.assertIn("customDefaultLayoutKey", settings)
            self.assertIn("mutating func resetLayout(using store: UserDefaults = .standard)", settings)


class OutputShapeAndPreviewTests(unittest.TestCase):
    def test_aspect_picker_preview_and_export_use_the_same_shape(self):
        self.assertEqual([m for m in re.findall(r'case \.(\w+): return "(.+?)"', SHARED) if m[0] in
                          ("original", "square", "portrait45", "vertical916", "landscape169")][:5],
                         [("original", "原始"), ("square", "1:1"), ("portrait45", "4:5"),
                          ("vertical916", "9:16"), ("landscape169", "16:9")])
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn("OutputAspectPicker(selection: $outputAspect)", view)
            self.assertIn(".aspectRatio(stageRatio, contentMode: .fit)", view)
            self.assertIn("aspect: outputAspect", view)
        self.assertIn("videoGravity = .resizeAspectFill", SHARED)
        self.assertIn("max(renderSize.width / max(1, sourceSize.width), renderSize.height / max(1, sourceSize.height))", EXPORTER)

    def test_floating_preview_button_in_sections_02_to_05(self):
        self.assertEqual(len(re.findall(r'sectionHeader\("0[2-5] / ', DEPTH_VIEW)), 4)
        self.assertEqual(len(re.findall(r'sectionHeader\("0[2-5] / ', POOL_VIEW)), 4)
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn("FloatingPreviewButton(isShowing: $showingFloatingPreview)", view)
            self.assertIn("FloatingPreviewPanel(aspect: stageRatio", view)


class ExportTests(unittest.TestCase):
    def test_progress_keeps_polling_until_finished_and_shows_time_left(self):
        self.assertNotIn("if session.status != .exporting { break }", EXPORTER)
        self.assertIn("if status == .completed || status == .failed || status == .cancelled { break }", EXPORTER)
        for view in (DEPTH_VIEW, POOL_VIEW):
            self.assertIn("exportClock.label(progress: exportProgress)", view)
        self.assertIn("預估剩餘", SHARED)

    def test_export_renders_at_one_pixel_per_point_and_caps_frame_rate(self):
        self.assertIn("layer.contentsScale = 1", FACTORY)
        for source in (EXPORTER, POOL_EXPORT, FACTORY):
            self.assertNotIn("UIScreen.main.scale", source)
        self.assertIn("CMTime(value: 1, timescale: 60)", EXPORTER)
        self.assertIn("shouldOptimizeForNetworkUse = false", EXPORTER)

    def test_export_chart_matches_preview_chart(self):
        # Same geometry type in preview and export, with grid dashes, labels and marker.
        self.assertIn("DepthProfileGeometry(", DEPTH_HUD)
        self.assertIn("DepthProfileGeometry(", EXPORTER)
        self.assertIn("chart.depthGrid", EXPORTER)
        self.assertIn("chart.timeLabel(part: part)", EXPORTER)
        self.assertIn("PoolProfileGeometry(", POOL_EXPORT)


class PoolSpeedTests(unittest.TestCase):
    def test_ai_analysis_and_fluctuating_fallback(self):
        analyzer = read("PoolMotionAnalyzer.swift")
        timeline = read("PoolTimeline.swift")
        self.assertIn("VNGenerateOpticalFlowRequest", analyzer)
        self.assertIn("VNDetectHumanRectanglesRequest", analyzer)
        self.assertIn("min(0.22, max(0.05, average * 0.12), safeAverage * 0.5)", timeline)
        self.assertIn("PoolTimeline(session: session, motion: motionSignal)", POOL_VIEW)
        self.assertIn("AI 即時速率分析", POOL_VIEW)


if __name__ == "__main__":
    unittest.main(verbosity=2)
