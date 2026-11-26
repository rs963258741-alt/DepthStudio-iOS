import importlib.util
import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


make_altstore_source = load("make_altstore_source")
package_ipa = load("package_ipa")

INFO = {
    "CFBundleIdentifier": "com.bananaflow.depthstudio",
    "CFBundleShortVersionString": "1.0.3",
    "CFBundleVersion": "105",
    "CFBundleExecutable": "Depth Studio",
    "CFBundleDisplayName": "Depth Studio",
    "MinimumOSVersion": "17.0",
    "UILaunchStoryboardName": "LaunchScreen",
    "NSPhotoLibraryAddUsageDescription": "Save exported dive videos.",
    "UIUserInterfaceStyle": "Dark",
}


def write_ipa(path: Path, info: dict) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Payload/", b"")
        zf.writestr("Payload/Depth Studio.app/Info.plist", plistlib.dumps(info))
        zf.writestr("Payload/Depth Studio.app/Depth Studio", b"FAKE")


class AltStoreSourceTests(unittest.TestCase):
    def test_source_matches_ipa(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / "DepthStudio.ipa"
            write_ipa(ipa, INFO)
            source = make_altstore_source.build_source(
                ipa, "https://example.invalid/DepthStudio.ipa", "https://example.invalid/icon.png", "notes"
            )
            # Round-trips as JSON.
            source = json.loads(json.dumps(source, ensure_ascii=False))

        self.assertTrue(source["name"])
        app = source["apps"][0]
        for key in ("name", "bundleIdentifier", "developerName", "iconURL", "localizedDescription", "versions"):
            self.assertIn(key, app)
        self.assertEqual(app["bundleIdentifier"], "com.bananaflow.depthstudio")
        # AltStore rejects an install whose privacy keys are not all declared.
        self.assertEqual(app["appPermissions"], {
            "entitlements": [],
            "privacy": {"NSPhotoLibraryAddUsageDescription": "Save exported dive videos."},
        })
        version = app["versions"][0]
        # AltStore rejects an install whose version/build differ from the IPA.
        self.assertEqual(version["version"], "1.0.3")
        self.assertEqual(version["buildVersion"], "105")
        self.assertEqual(version["minOSVersion"], "17.0")
        self.assertRegex(version["date"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00$")
        self.assertRegex(version["sha256"], r"^[0-9a-f]{64}$")
        self.assertGreater(version["size"], 0)

    def test_rejects_ipa_without_version(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / "DepthStudio.ipa"
            info = dict(INFO)
            del info["CFBundleVersion"]
            write_ipa(ipa, info)
            with self.assertRaises(ValueError):
                make_altstore_source.build_source(ipa, "https://x", "https://y", "")


class PackageVersionTests(unittest.TestCase):
    def make_app(self, root: Path) -> Path:
        app = root / "Depth Studio.app"
        (app / "FIT_cppfit.bundle").mkdir(parents=True)
        (app / "FIT_cppfit.bundle" / "fit.h").write_text("header")
        (app / "Base.lproj" / "LaunchScreen.storyboardc").mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps(INFO))
        (app / "Depth Studio").write_bytes(b"FAKE")
        (app / "Assets.car").write_bytes(b"FAKE")
        return app

    def test_expected_version_and_build_are_enforced(self):
        with tempfile.TemporaryDirectory() as temp:
            app = self.make_app(Path(temp))
            package_ipa.validate_app(app, "1.0.3", "105")
            with self.assertRaises(ValueError):
                package_ipa.validate_app(app, "1.0.4", "105")
            with self.assertRaises(ValueError):
                package_ipa.validate_app(app, "1.0.3", "4")

    def test_ci_build_reads_versions_from_project_yml(self):
        script = (ROOT / "scripts" / "ci_build.sh").read_text(encoding="utf-8")
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("read_setting MARKETING_VERSION", script)
        self.assertIn("--expect-version", script)
        self.assertIn("MARKETING_VERSION:", project)
        self.assertIn("CURRENT_PROJECT_VERSION:", project)
        # Versions live in one place only.
        self.assertNotIn("INFOPLIST_KEY_CFBundleVersion", project)
        self.assertNotIn("INFOPLIST_KEY_CFBundleShortVersionString", project)


if __name__ == "__main__":
    unittest.main(verbosity=2)
