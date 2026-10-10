#!/usr/bin/env python3
"""Portable regressions for SDK metadata, including universal app binaries."""

import unittest

from check_macos_sdk import check_build_versions


def build_command(sdk="27.0", minimum="14.0", platform="MACOS"):
    return f"""Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform {platform}
    minos {minimum}
      sdk {sdk}
   ntools 1
     tool LD
  version 27037.1
"""


class MacOSSDKTests(unittest.TestCase):
    def test_current_sdk_keeps_older_deployment_target(self):
        self.assertEqual(check_build_versions(build_command(), "14.0", "27.0"), 1)

    def test_sdk_version_is_not_hardcoded_to_current_release(self):
        self.assertEqual(check_build_versions(build_command("26.6"), "14.0", "26.6"), 1)

    def test_equivalent_version_formats(self):
        self.assertEqual(check_build_versions(build_command("27.0.0", "14"), "14.0", "27"), 1)

    def test_deployment_target_written_as_sdk_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "linked SDK 14.0"):
            check_build_versions(build_command("14.0"), "14.0", "27.0")

    def test_universal_binary_checks_both_slices(self):
        output = "app (architecture x86_64):\n" + build_command()
        output += "app (architecture arm64):\n" + build_command()
        self.assertEqual(check_build_versions(output, "14.0", "27.0"), 2)

    def test_bad_second_universal_slice_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Slice 2: linked SDK"):
            check_build_versions(build_command() + build_command("14.0"), "14.0", "27.0")

    def test_raised_minimum_system_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "deployment target"):
            check_build_versions(build_command(minimum="27.0"), "14.0", "27.0")

    def test_non_macos_platform_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "expected macOS"):
            check_build_versions(build_command(platform="IOS"), "14.0", "27.0")

    def test_missing_sdk_is_rejected(self):
        with self.assertRaises(ValueError):
            check_build_versions(build_command().replace("      sdk 27.0\n", ""), "14.0", "27.0")

    def test_missing_load_commands_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "No LC_BUILD_VERSION"):
            check_build_versions("", "14.0", "27.0")

    def test_legacy_slice_in_universal_binary_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Legacy macOS load command"):
            check_build_versions(build_command() + "cmd LC_VERSION_MIN_MACOSX\n", "14.0", "27.0")

    def test_sdk_older_than_deployment_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "older than the deployment"):
            check_build_versions(build_command("13.0"), "14.0", "13.0")

    def test_invalid_requested_version_is_rejected(self):
        with self.assertRaises(ValueError):
            check_build_versions(build_command(), "14.0", "27.0 extra")


if __name__ == "__main__":
    unittest.main()
