#!/usr/bin/env python3
"""Create a standard AltStore-compatible IPA from an unsigned iOS .app bundle.

The ZIP layout intentionally mirrors the previously user-confirmed working IPA:
- Payload/ is the first-level directory entry.
- App bundle contents live directly under Payload/<AppName>.app/.
- Files and directory entries use ZIP_DEFLATED (not stored directory entries).
- No extra parent directory is added around Payload.
"""
from __future__ import annotations

import argparse
import os
import plistlib
import stat
import sys
import zipfile
from pathlib import Path

EXPECTED_BUNDLE_ID = "com.bananaflow.depthstudio"
EXPECTED_VERSION = "1.0.3"
EXPECTED_BUILD = "4"


def validate_app(app: Path) -> tuple[Path, dict]:
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError(f"App bundle path is not a .app directory: {app}")

    plist_path = app / "Info.plist"
    if not plist_path.is_file():
        raise ValueError("Info.plist is missing from the app bundle")

    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)

    bundle_id = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = str(info.get("CFBundleVersion", ""))
    executable_name = info.get("CFBundleExecutable")
    launch_storyboard = info.get("UILaunchStoryboardName")

    if bundle_id != EXPECTED_BUNDLE_ID:
        raise ValueError(f"Unexpected Bundle ID: {bundle_id!r}")
    if version != EXPECTED_VERSION:
        raise ValueError(f"Unexpected CFBundleShortVersionString: {version!r}")
    if build != EXPECTED_BUILD:
        raise ValueError(f"Unexpected CFBundleVersion: {build!r}")
    if not isinstance(executable_name, str) or not executable_name:
        raise ValueError("CFBundleExecutable is missing or invalid")
    if launch_storyboard != "LaunchScreen":
        raise ValueError(f"UILaunchStoryboardName must be LaunchScreen, got {launch_storyboard!r}")
    storyboard_compiled = app / "Base.lproj" / "LaunchScreen.storyboardc"
    if not storyboard_compiled.is_dir():
        raise ValueError("Compiled Base.lproj/LaunchScreen.storyboardc is missing")

    executable = app / executable_name
    if not executable.is_file() or executable.stat().st_size == 0:
        raise ValueError(f"App executable is missing or empty: {executable_name}")

    assets = app / "Assets.car"
    if not assets.is_file() or assets.stat().st_size == 0:
        raise ValueError("Assets.car is missing or empty")

    fit_bundle = app / "FIT_cppfit.bundle"
    if not fit_bundle.is_dir() or not any(p.is_file() for p in fit_bundle.rglob("*")):
        raise ValueError("FIT_cppfit.bundle is missing or empty")

    supported_platforms = info.get("CFBundleSupportedPlatforms", [])
    if supported_platforms and "iPhoneOS" not in supported_platforms:
        raise ValueError(f"App is not marked for iPhoneOS: {supported_platforms!r}")

    device_families = info.get("UIDeviceFamily", [])
    if device_families and 1 not in device_families:
        raise ValueError(f"App does not include iPhone device family: {device_families!r}")

    return executable, info


def _write_directory(zf: zipfile.ZipFile, archive_name: str) -> None:
    if not archive_name.endswith("/"):
        archive_name += "/"
    entry = zipfile.ZipInfo(archive_name)
    entry.create_system = 3
    entry.external_attr = (stat.S_IFDIR | 0o755) << 16
    entry.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(entry, b"", compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def add_app_contents(zf: zipfile.ZipFile, app: Path) -> None:
    prefix = f"Payload/{app.name}/"
    # Preserve nested directories, but do not add a separate empty
    # Payload/<App>.app/ entry; the previously working archive omitted it.
    for current, dirs, files in os.walk(app, followlinks=False):
        dirs.sort()
        files.sort()
        current_path = Path(current)
        relative = current_path.relative_to(app)

        if relative != Path("."):
            _write_directory(zf, prefix + relative.as_posix())

        for name in files:
            file_path = current_path / name
            relative_file = file_path.relative_to(app).as_posix()
            archive_name = prefix + relative_file

            if file_path.is_symlink():
                link_target = os.readlink(file_path).encode("utf-8")
                entry = zipfile.ZipInfo(archive_name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(entry, link_target, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
            else:
                zf.write(
                    file_path,
                    arcname=archive_name,
                    compress_type=zipfile.ZIP_DEFLATED,
                    compresslevel=9,
                )

        # os.walk lists symlinked directories in dirs. Store the link itself
        # as a symlink entry rather than following it or omitting it.
        symlink_dirs = [d for d in dirs if (current_path / d).is_symlink()]
        for name in symlink_dirs:
            link_path = current_path / name
            relative_link = link_path.relative_to(app).as_posix()
            entry = zipfile.ZipInfo(prefix + relative_link)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(
                entry,
                os.readlink(link_path).encode("utf-8"),
                compress_type=zipfile.ZIP_DEFLATED,
                compresslevel=9,
            )
            dirs.remove(name)


def validate_ipa(ipa: Path, expected_app_name: str, expected_executable: str) -> None:
    with zipfile.ZipFile(ipa, "r") as zf:
        bad_member = zf.testzip()
        if bad_member:
            raise ValueError(f"ZIP CRC validation failed at: {bad_member}")

        names = zf.namelist()
        if not names or names[0] != "Payload/":
            raise ValueError(f"Payload is not the first root entry: {names[:3]!r}")

        app_prefix = f"Payload/{expected_app_name}/"
        required = {
            app_prefix + "Info.plist",
            app_prefix + "Assets.car",
            app_prefix + expected_executable,
        }
        missing = required.difference(names)
        if missing:
            raise ValueError(f"IPA is missing required app files: {sorted(missing)}")

        if any(name.startswith("DepthStudio-iOS/") for name in names):
            raise ValueError("IPA contains an unexpected enclosing project folder")

        plist_data = zf.read(app_prefix + "Info.plist")
        info = plistlib.loads(plist_data)
        if info.get("UILaunchStoryboardName") != "LaunchScreen":
            raise ValueError("Launch storyboard setting did not survive IPA packaging")
        if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
            raise ValueError("Bundle ID changed during IPA packaging")
        if info.get("CFBundleShortVersionString") != EXPECTED_VERSION:
            raise ValueError("App version changed during IPA packaging")
        if str(info.get("CFBundleVersion")) != EXPECTED_BUILD:
            raise ValueError("Build version changed during IPA packaging")

        if not any(name.startswith(app_prefix + "FIT_cppfit.bundle/") for name in names):
            raise ValueError("IPA does not contain the FIT SDK bundle contents")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path, help="Path to the built .app directory")
    parser.add_argument("--output", required=True, type=Path, help="Output .ipa path")
    args = parser.parse_args()

    app = args.app.resolve()
    output = args.output.resolve()

    try:
        executable, info = validate_app(app)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.unlink(missing_ok=True)

        with zipfile.ZipFile(
            output,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            allowZip64=True,
        ) as zf:
            _write_directory(zf, "Payload")
            add_app_contents(zf, app)

        if not output.is_file() or output.stat().st_size == 0:
            raise ValueError("IPA output is missing or empty")
        validate_ipa(output, app.name, executable.name)

        print(f"Validated Bundle ID: {info['CFBundleIdentifier']}")
        print(f"Validated version: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
        print(f"Validated executable: {executable.name}")
        print(f"Validated FIT bundle: {app / 'FIT_cppfit.bundle'}")
        print(f"IPA created: {output} ({output.stat().st_size} bytes)")
        return 0
    except Exception as exc:  # surfaced in Codemagic logs
        print(f"IPA packaging validation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
