import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TIMELINE = (ROOT / "PoolTimeline.swift").read_text(encoding="utf-8")
SETTINGS = (ROOT / "PoolHUDSettings.swift").read_text(encoding="utf-8")
OVERLAY = (ROOT / "PoolHUDOverlay.swift").read_text(encoding="utf-8")
EXPORT = (ROOT / "PoolVideoHUDLayer.swift").read_text(encoding="utf-8")
VIEW = (ROOT / "PoolModeView.swift").read_text(encoding="utf-8")
EXPORTER = (ROOT / "DiveVideoExporter.swift").read_text(encoding="utf-8")


def item_ids():
    block = SETTINGS[SETTINGS.index("static let all"):SETTINGS.index("static let liveIDs")]
    return re.findall(r'\.init\(id: "(\w+)"', block)


def dict_keys(name):
    block = SETTINGS[SETTINGS.index(f"{name} = ["):]
    block = block[:block.index("]")]
    return set(re.findall(r'"(\w+)":', block))


class PoolHUDConsistencyTests(unittest.TestCase):
    def test_every_item_has_position_visibility_preview_and_export(self):
        ids = item_ids()
        self.assertEqual(len(ids), len(set(ids)))
        self.assertGreaterEqual(len(ids), 15)
        self.assertEqual(dict_keys("positions"), set(ids))
        self.assertEqual(dict_keys("visibility"), set(ids))
        for item_id in ids:
            self.assertIn(f'case "{item_id}"', OVERLAY, f"preview does not draw {item_id}")
            self.assertTrue(f'case "{item_id}"' in EXPORT or f'"{item_id}"' in EXPORT,
                            f"export does not draw {item_id}")

    def test_no_depth_fields_in_pool_hud(self):
        for depth_only in ["depthValue", "tempValue", "maxDepth", "WATER TEMP", "DEPTH / SEC"]:
            self.assertNotIn(depth_only, SETTINGS + OVERLAY + EXPORT)

    def test_disciplines_and_footer_follow_the_design(self):
        self.assertIn('["DYN", "DYNB", "DNF"]', SETTINGS)
        self.assertIn('footerText = "蕉流自潛設計"', SETTINGS)


class PoolTimelineSourceTests(unittest.TestCase):
    def test_demo_matches_design_example(self):
        # 50 m pool: 0 m at 00:02, turns at 00:50 and 01:40, 150 m at 02:30.
        self.assertIn("[0: 2, 50: 50, 100: 100, 150: 150]", TIMELINE)
        self.assertIn("PoolSession(poolLength: 50, finalDistance: 150)", TIMELINE)

    def test_pool_lengths_and_custom_final_distance(self):
        self.assertIn("poolLengths: [Double] = [25, 50]", TIMELINE)
        self.assertIn("mutating func setFinalDistance", TIMELINE)
        self.assertIn("mutating func addCheckpoint", TIMELINE)

    def test_speed_is_segment_average_and_needs_start_and_finish(self):
        self.assertIn("var speed: Double { distance / duration }", TIMELINE)
        self.assertIn("case missingStart", TIMELINE)
        self.assertIn("case missingFinish", TIMELINE)
        self.assertIn("case timeNotIncreasing", TIMELINE)


class PoolScreenWiringTests(unittest.TestCase):
    def test_import_mark_and_export_are_wired(self):
        self.assertIn("PhotosPicker(", VIEW)
        self.assertIn("loadTransferable(type: ImportedMovie.self)", VIEW)
        self.assertIn("session.setTime(currentVideoTime, for: node.id)", VIEW)
        self.assertIn("DiveVideoExporter().exportPool(", VIEW)
        self.assertIn("PHPhotoLibrary.shared().performChanges", VIEW)
        self.assertIn("aspectRatio(9.0 / 16.0", VIEW)

    def test_pool_export_reuses_the_shared_4k_path(self):
        self.assertIn("func exportVideo(", EXPORTER)
        self.assertIn("makeHUD: @escaping (CGSize, Double) -> CALayer", EXPORTER)
        self.assertIn("exportVideo(", EXPORT)
        self.assertIn("calculationMode = .discrete", EXPORT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
