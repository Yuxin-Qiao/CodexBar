#!/usr/bin/env python3
"""Reject packaged Mach-O slices with incorrect deployment or SDK metadata."""

import argparse
import re
import subprocess
import sys


def version_tuple(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError(f"Invalid macOS version: {value}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def check_build_versions(output, minimum_version, sdk_version):
    minimum = version_tuple(minimum_version)
    sdk = version_tuple(sdk_version)
    if sdk < minimum:
        raise ValueError("Selected macOS SDK is older than the deployment target")
    if re.search(r"\bcmd LC_VERSION_MIN_MACOSX\b", output):
        raise ValueError("Legacy macOS load command found; expected LC_BUILD_VERSION in every slice")
    commands = re.findall(
        r"\bcmd LC_BUILD_VERSION\b(?:(?!\bcmd\b).)*", output, re.DOTALL
    )
    if not commands:
        raise ValueError("No LC_BUILD_VERSION load commands found")
    for index, command in enumerate(commands, start=1):
        fields = dict(
            re.findall(r"^\s*(platform|minos|sdk)\s+(\S+)\s*$", command, re.MULTILINE)
        )
        if fields.get("platform") != "MACOS":
            raise ValueError(f"Slice {index}: expected macOS build metadata")
        if version_tuple(fields.get("minos", "")) != minimum:
            raise ValueError(
                f"Slice {index}: deployment target {fields.get('minos')} "
                f"does not match {minimum_version}"
            )
        if version_tuple(fields.get("sdk", "")) != sdk:
            raise ValueError(
                f"Slice {index}: linked SDK {fields.get('sdk')} does not match "
                f"selected SDK {sdk_version}; this can enable legacy system UI"
            )
    return len(commands)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("minimum_version")
    parser.add_argument("sdk_version")
    args = parser.parse_args()
    try:
        result = subprocess.run(
            ["xcrun", "vtool", "-show-build", args.binary],
            capture_output=True,
            text=True,
            check=True,
        )
        count = check_build_versions(
            result.stdout, args.minimum_version, args.sdk_version
        )
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"ERROR: macOS build metadata check failed for {args.binary}: {error}", file=sys.stderr)
        return 1
    print(f"macOS build metadata OK: {count} slice(s), minimum {args.minimum_version}, SDK {args.sdk_version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
