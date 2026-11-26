import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "DepthStudioApp.swift").read_text(encoding="utf-8")
CONTENT = (ROOT / "ContentView.swift").read_text(encoding="utf-8")
MODES = (ROOT / "ModeSelectionView.swift").read_text(encoding="utf-8")
POOL = (ROOT / "PoolModeView.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")


class ModeSelectionTests(unittest.TestCase):
    def test_app_starts_at_root_with_launch_animation_then_mode_picker(self):
        self.assertIn("DepthStudioRootView()", APP)
        self.assertNotIn("ContentView()", APP)
        root = CONTENT[CONTENT.index("struct DepthStudioRootView"):]
        self.assertIn("DepthStudioLaunchAnimation()", root)
        self.assertIn("ModeSelectionView {", root)
        self.assertIn("case .depth:", root)
        self.assertIn("ContentView(onSwitchMode:", root)
        self.assertIn("case .pool:", root)
        self.assertIn("PoolModeView(onSwitchMode:", root)

    def test_both_modes_are_offered(self):
        self.assertIn('case .depth: return "深度潛水"', MODES)
        self.assertIn('case .pool: return "泳池平潛"', MODES)
        self.assertIn("ForEach(DiveMode.allCases)", MODES)

    def test_each_mode_can_return_to_the_picker(self):
        self.assertIn('ModeSwitchButton(title: "深度潛水")', CONTENT)
        self.assertIn('ModeSwitchButton(title: "泳池平潛"', POOL)

    def test_every_swift_file_is_listed_in_project_yml(self):
        listed = set(re.findall(r"- path: (\S+\.swift)", PROJECT))
        on_disk = {p.name for p in ROOT.glob("*.swift")}
        self.assertEqual(on_disk - listed, set(), "Swift files missing from project.yml sources")
        self.assertEqual(listed - on_disk, set(), "project.yml lists Swift files that do not exist")


if __name__ == "__main__":
    unittest.main(verbosity=2)
