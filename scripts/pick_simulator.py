#!/usr/bin/env python3
"""Pick an iPhone simulator from `xcrun simctl list devices available -j` (stdin).

Prefers the newest iOS runtime and a current standard iPhone model; prints its UDID.
"""
import json
import re
import sys

PREFERRED = ["iPhone 16", "iPhone 16 Pro", "iPhone 17", "iPhone 17 Pro", "iPhone 15", "iPhone 15 Pro"]


def runtime_version(key: str) -> tuple:
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?", key)
    return tuple(int(part or 0) for part in match.groups()) if match else (0, 0, 0)


def main() -> int:
    data = json.load(sys.stdin)
    runtimes = sorted((key for key in data.get("devices", {}) if "iOS" in key), key=runtime_version, reverse=True)
    for runtime in runtimes:
        devices = [d for d in data["devices"][runtime] if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
        if not devices:
            continue
        for name in PREFERRED:
            for device in devices:
                if device["name"] == name:
                    print(device["udid"])
                    return 0
        print(devices[0]["udid"])
        return 0
    print("no iPhone simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
