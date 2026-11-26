#!/usr/bin/env python3
"""Print APP_VERSION / APP_BUILD_NUMBER / BUNDLE_ID / APP_NAME of a built IPA as KEY=value lines.

Used when publishing an IPA built outside GitHub Actions (e.g. on Codemagic), so the
release tag and AltStore source come from the IPA itself. Exits non-zero if the IPA
is not a Payload/<App>.app archive or the bundle ID is not the expected one.
"""
from __future__ import annotations

import argparse
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def ipa_info(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as zf:
        if zf.testzip() is not None:
            raise ValueError("IPA failed the ZIP CRC check")
        names = zf.namelist()
        if not names or names[0] != "Payload/":
            raise ValueError("Payload/ is not the first entry of the IPA")
        plists = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(plists) != 1:
            raise ValueError(f"Expected one Payload/<App>.app/Info.plist, found {plists!r}")
        info = plistlib.loads(zf.read(plists[0]))
    app_name = plists[0].split("/")[1][: -len(".app")]
    values = {
        "APP_VERSION": info.get("CFBundleShortVersionString"),
        "APP_BUILD_NUMBER": info.get("CFBundleVersion"),
        "BUNDLE_ID": info.get("CFBundleIdentifier"),
        "APP_NAME": app_name,
    }
    missing = [key for key, value in values.items() if not value]
    if missing:
        raise ValueError(f"Info.plist is missing {missing}")
    return {key: str(value) for key, value in values.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--expect-bundle-id", required=True)
    args = parser.parse_args()
    try:
        values = ipa_info(args.ipa)
        if values["BUNDLE_ID"] != args.expect_bundle_id:
            raise ValueError(f"Unexpected bundle ID {values['BUNDLE_ID']!r}")
    except Exception as exc:
        print(f"IPA check failed: {exc}", file=sys.stderr)
        return 1
    for key, value in values.items():
        quoted = value.replace("\\", "\\\\").replace('"', '\\"')
        print(f'{key}="{quoted}"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
