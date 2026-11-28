"""Smart Sync update (1.5): static checks of the wiring.

The behaviour is tested on the simulator: AppTests/SmartSyncTests.swift (sync core, export
naming, preview and export using the same sync, a real export with an offset) and
AppUITests/SmartSyncUITests.swift (layout, modes, capture, manual timeline, docked preview).
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTENT = (ROOT / "ContentView.swift").read_text(encoding="utf-8")
POOL = (ROOT / "PoolModeView.swift").read_text(encoding="utf-8")
SYNC = (ROOT / "DiveSync.swift").read_text(encoding="utf-8")
PANEL = (ROOT / "DiveSyncPanel.swift").read_text(encoding="utf-8")
NAMING = (ROOT / "ExportNaming.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")


class SyncCoreTests(unittest.TestCase):
    def test_new_files_are_compiled(self):
        for name in ("DiveSync.swift", "DiveSyncPanel.swift", "ExportNaming.swift"):
            self.assertIn(f"- path: {name}", PROJECT)

    def test_one_sync_for_preview_floating_docked_and_export(self):
        # data time = video time − delay, mapped onto TimelineSync once.
        self.assertIn("(try? TimelineSync(offsetSeconds: -delay))", SYNC)
        self.assertIn("private var currentSync: TimelineSync { syncState.timelineSync }", CONTENT)
        self.assertEqual(CONTENT.count("sync: currentSync"), 3)   # stage, floating, docked
        self.assertIn("let sync = currentSync", CONTENT)          # export
        self.assertNotIn("TimelineSync(offsetSeconds: hudSettings.syncOffset)", CONTENT)

    def test_three_modes_with_their_audience_notes(self):
        for title in ("智慧同步", "進階同步", "手動同步"):
            self.assertIn(f'"{title}"', SYNC)
        for note in ("適合一般使用者", "適合擁有完整下潛至上升影片", "適合不完整的潛水影片"):
            self.assertIn(note, SYNC)
        self.assertIn("case .smart: smartContent", PANEL)
        self.assertIn("case .advanced: advancedContent", PANEL)
        self.assertIn("case .manual: manualContent", PANEL)
        self.assertIn('Text("數據顯示太快：將數據延後（＋）。")', PANEL)
        self.assertIn('Text("數據顯示太慢：將數據提前（−）。")', PANEL)

    def test_new_material_resets_the_sync(self):
        self.assertGreaterEqual(CONTENT.count("syncState.reset()"), 3)  # video, dive log, demo data


class LayoutTests(unittest.TestCase):
    def test_sections_are_renumbered_with_sync_under_the_preview(self):
        body = CONTENT[CONTENT.index("var body: some View"):CONTENT.index("private var presetConfirmationShown")]
        order = ["importSection", "previewSection", "syncSection", "hudAppearanceSection",
                 "visibilitySection", "identitySection", "exportSection", "statusSection"]
        positions = [body.index(name) for name in order]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("if let diveRecord { diveSummary(diveRecord) }", body, "duplicate summary removed")
        titles = re.findall(r'"(0\d) / ([^"]+)"', CONTENT)
        # Each number once, continuous (the screen order is checked through `body` above).
        self.assertEqual(sorted(number for number, _ in titles), ["01", "02", "03", "04", "05", "06"])
        self.assertIn(("02", "潛水紀錄摘要與時間同步"), titles)

    def test_docked_preview_does_not_cover_other_sections(self):
        self.assertIn("DockedPreviewPanel(aspect: stageRatio, playback: playback)", CONTENT)
        self.assertIn("&& !showingFloatingPreview", CONTENT)
        self.assertIn(".maxY > 420", CONTENT)


class ExportAsNewFileTests(unittest.TestCase):
    def test_both_modes_save_a_new_file(self):
        for view in (CONTENT, POOL):
            self.assertIn('"輸出影片（另存新檔）"', view)
            self.assertIn('"輸出影片不會覆蓋原始影片。"', view)
            self.assertIn("ExportNaming.nextOutputURL(", view)
            self.assertIn("ExportNaming.recordExport(at:", view)
            self.assertNotIn("creationRequestForAssetFromVideo", view)
        self.assertIn('static let suffix = "_DepthStudio"', NAMING)
        self.assertIn("options.originalFilename = url.lastPathComponent", NAMING)


if __name__ == "__main__":
    unittest.main(verbosity=2)
