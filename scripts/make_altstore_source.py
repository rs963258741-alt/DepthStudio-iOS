#!/usr/bin/env python3
"""Write an AltStore source (altstore-source.json) for a built DepthStudio.ipa.

AltStore refuses an install when the source disagrees with the IPA, so every
value it checks is read from the IPA itself rather than typed in by hand:

- version / buildVersion  <- CFBundleShortVersionString / CFBundleVersion
- bundleIdentifier        <- CFBundleIdentifier
- appPermissions.privacy  <- every *UsageDescription key in Info.plist
- size / sha256           <- the IPA file

The IPA is unsigned, so it carries no entitlements and `entitlements` is empty.
AltStore shows an update whenever version or buildVersion differs from the
installed copy, so each CI build only needs a new build number.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

PRIVACY_KEY = re.compile(r"^(NS)?.+UsageDescription$")

SOURCE_NAME = "Depth Studio｜蕉流 Freediving"
SOURCE_IDENTIFIER = "com.bananaflow.depthstudio.source"
DEVELOPER_NAME = "BananaFlow Freediving"
APP_SUBTITLE = "潛水影片深度 HUD 與 4K 輸出"
APP_DESCRIPTION = (
    "Depth Studio 將潛水電腦（Garmin FIT、ATMOS UDDF/XML）的深度、時間、水溫與速度，"
    "以可自由拖曳、縮放、旋轉的透明 HUD 疊加到潛水影片上，並在 iPhone 上輸出 4K MP4。"
)
TINT_COLOR = "0A84FF"


def read_info_plist(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as zf:
        candidates = [
            name
            for name in zf.namelist()
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
        ]
        if len(candidates) != 1:
            raise ValueError(f"Expected one Payload/<App>.app/Info.plist, found {candidates!r}")
        return plistlib.loads(zf.read(candidates[0]))


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_source(
    ipa: Path,
    download_url: str,
    icon_url: str,
    notes: str,
    website: str | None = None,
    date: datetime | None = None,
) -> dict:
    info = read_info_plist(ipa)

    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    bundle_id = info.get("CFBundleIdentifier")
    if not version or not build or not bundle_id:
        raise ValueError("Info.plist is missing the version, build or bundle identifier")

    privacy = {
        key: str(value)
        for key, value in sorted(info.items())
        if PRIVACY_KEY.match(key)
    }

    when = (date or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)

    version_entry = {
        "version": str(version),
        "buildVersion": str(build),
        "date": when.isoformat(),
        "localizedDescription": notes,
        "downloadURL": download_url,
        "size": ipa.stat().st_size,
        "sha256": sha256_of(ipa),
    }
    if info.get("MinimumOSVersion"):
        version_entry["minOSVersion"] = str(info["MinimumOSVersion"])

    source = {
        "name": SOURCE_NAME,
        "identifier": SOURCE_IDENTIFIER,
        "iconURL": icon_url,
        "tintColor": TINT_COLOR,
        "apps": [
            {
                "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or "Depth Studio",
                "bundleIdentifier": bundle_id,
                "developerName": DEVELOPER_NAME,
                "subtitle": APP_SUBTITLE,
                "localizedDescription": APP_DESCRIPTION,
                "iconURL": icon_url,
                "tintColor": TINT_COLOR,
                "category": "photo-video",
                "appPermissions": {
                    "entitlements": [],
                    "privacy": privacy,
                },
                "versions": [version_entry],
            }
        ],
        "news": [],
    }
    if website:
        source["website"] = website
    return source


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--icon-url", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--notes", default="", help="What changed in this build")
    parser.add_argument("--website")
    args = parser.parse_args()

    try:
        source = build_source(args.ipa, args.download_url, args.icon_url, args.notes, args.website)
    except Exception as exc:
        print(f"AltStore source generation failed: {exc}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    entry = source["apps"][0]["versions"][0]
    print(f"AltStore source written: {args.output} ({entry['version']} build {entry['buildVersion']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
