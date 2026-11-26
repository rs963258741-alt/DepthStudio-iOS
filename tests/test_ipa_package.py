import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "package_ipa.py"
spec = importlib.util.spec_from_file_location("package_ipa", SCRIPT)
package_ipa = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(package_ipa)


class PackageIPATests(unittest.TestCase):
    def test_builds_root_payload_and_keeps_required_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "Depth Studio.app"
            (app / "FIT_cppfit.bundle" / "include").mkdir(parents=True)
            (app / "Base.lproj" / "LaunchScreen.storyboardc").mkdir(parents=True)
            (app / "Base.lproj" / "LaunchScreen.storyboardc" / "Info.plist").write_text("fixture")
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.bananaflow.depthstudio",
                "CFBundleShortVersionString": "1.0.3",
                "CFBundleVersion": "4",
                "CFBundleExecutable": "Depth Studio",
                "UILaunchStoryboardName": "LaunchScreen",
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
                "UIDeviceFamily": [1],
            }))
            (app / "Depth Studio").write_bytes(b"FAKE-MACH-O")
            (app / "Assets.car").write_bytes(b"FAKE-ASSETS")
            (app / "FIT_cppfit.bundle" / "include" / "fit.h").write_text("header")
            out = root / "DepthStudio.ipa"

            executable, _ = package_ipa.validate_app(app)
            package_ipa._write_directory  # ensure helper is present
            with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
                package_ipa._write_directory(zf, "Payload")
                package_ipa.add_app_contents(zf, app)
            package_ipa.validate_ipa(out, app.name, executable.name)

            with zipfile.ZipFile(out) as zf:
                self.assertEqual(zf.namelist()[0], "Payload/")
                self.assertIn("Payload/Depth Studio.app/Info.plist", zf.namelist())
                self.assertNotIn("Payload/Depth Studio.app/", zf.namelist())
                self.assertTrue(all(i.compress_type == zipfile.ZIP_DEFLATED for i in zf.infolist()))

    def test_rejects_wrong_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "Depth Studio.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "wrong.bundle",
                "CFBundleShortVersionString": "1.0.3",
                "CFBundleVersion": "4",
                "CFBundleExecutable": "Depth Studio",
                "UILaunchStoryboardName": "LaunchScreen",
            }))
            (app / "Depth Studio").write_bytes(b"fake")
            (app / "Assets.car").write_bytes(b"fake")
            (app / "FIT_cppfit.bundle").mkdir()
            (app / "Base.lproj" / "LaunchScreen.storyboardc").mkdir(parents=True)
            with self.assertRaises(ValueError):
                package_ipa.validate_app(app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
