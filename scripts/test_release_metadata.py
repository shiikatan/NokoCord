#!/usr/bin/env python3
"""Focused tests for canonical release metadata and app packaging."""

import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from release_metadata import load_metadata  # noqa: E402


EXPECTED_PACKAGE_FILES = {
    "NokoCord.app/Contents/Info.plist",
    "NokoCord.app/Contents/MacOS/NokoCord",
    "NokoCord.app/Contents/Helpers/TanTranslator",
    "NokoCord.app/Contents/Helpers/NokoMusicWatch.app/Contents/Info.plist",
    "NokoCord.app/Contents/Helpers/NokoMusicWatch.app/Contents/MacOS/NokoMusicWatch",
    "NokoCord.app/Contents/Helpers/NokoMusicWatch.app/Contents/Resources/AppIcon.icns",
    "NokoCord.app/Contents/Helpers/NokoMusicWatch.app/Contents/_CodeSignature/CodeResources",
    "NokoCord.app/Contents/_CodeSignature/CodeResources",
    "NokoCord.app/Contents/Resources/AppIcon.icns",
    "NokoCord.app/Contents/Resources/NokoCord-LICENSE.txt",
    "NokoCord.app/Contents/Resources/NokoMark.png",
    "NokoCord.app/Contents/Resources/TanTranslatorRuntime.js",
    "NokoCord.app/Contents/Resources/TypeScript-LICENSE.txt",
    "NokoCord.app/Contents/Resources/TypeScript-ThirdPartyNotices.txt",
}


class ReleaseMetadataTests(unittest.TestCase):
    def test_current_chiaki_config_is_the_canonical_source(self):
        metadata = load_metadata(ROOT / "Config" / "Edition.xcconfig")

        self.assertEqual(metadata.bundle_id, "com.shiikatan.nokocord.chiaki")
        self.assertEqual(metadata.edition, "chiaki")
        self.assertEqual(metadata.edition_name, "Chiaki")
        self.assertEqual(metadata.apple_version, "1.3.0")
        self.assertEqual(metadata.public_version, "C1.3.0")
        self.assertEqual(metadata.build_number, "6")
        self.assertEqual(metadata.deployment_target, "26.0")

    def test_parser_supports_a_future_release_fixture_without_changing_current_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / "Edition.xcconfig"
            config.write_text(
                "\n".join(
                    [
                        "NOKO_BUNDLE_ID = com.example.nokocord.chiaki",
                        "NOKO_APPLE_VERSION = 1.3.0",
                        "NOKO_BUILD_NUMBER = 6",
                        "NOKO_EDITION_ID = chiaki",
                        "NOKO_EDITION_NAME = Chiaki",
                        "NOKO_PUBLIC_VERSION = C1.3.0",
                        "NOKO_MAINTAINER = Millx",
                        "NOKO_DEPLOYMENT_TARGET = 26.0",
                    ]
                )
                + "\n"
            )

            metadata = load_metadata(config)

        self.assertEqual(metadata.apple_version, "1.3.0")
        self.assertEqual(metadata.public_version, "C1.3.0")
        self.assertEqual(metadata.build_number, "6")

    def test_parser_rejects_duplicate_or_missing_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            duplicate = pathlib.Path(directory) / "duplicate.xcconfig"
            duplicate.write_text(
                "NOKO_BUNDLE_ID = one\nNOKO_BUNDLE_ID = two\n"
            )
            with self.assertRaises(ValueError):
                load_metadata(duplicate)

            missing = pathlib.Path(directory) / "missing.xcconfig"
            missing.write_text("NOKO_EDITION_ID = chiaki\n")
            with self.assertRaises(ValueError):
                load_metadata(missing)

    def test_xcode_targets_defer_identity_and_deployment_to_xcconfig(self):
        project = (ROOT / "NokoCord.xcodeproj" / "project.pbxproj").read_text()

        self.assertNotIn("CURRENT_PROJECT_VERSION = 1;", project)
        self.assertEqual(project.count('CURRENT_PROJECT_VERSION = "$(NOKO_BUILD_NUMBER)";'), 4)
        self.assertNotIn("MACOSX_DEPLOYMENT_TARGET = 26.6;", project)
        self.assertEqual(project.count('MACOSX_DEPLOYMENT_TARGET = "$(NOKO_DEPLOYMENT_TARGET)";'), 4)
        self.assertEqual(project.count('MARKETING_VERSION = "$(NOKO_APPLE_VERSION)";'), 4)

    def test_native_build_expands_canonical_metadata_into_plists(self):
        build = (ROOT / "scripts" / "build.sh").read_text()

        self.assertIn("cat << WATCH_PLIST_EOF", build)
        self.assertIn("cat << PLIST_EOF", build)
        self.assertNotIn("cat << 'WATCH_PLIST_EOF'", build)
        self.assertNotIn("cat << 'PLIST_EOF'", build)


class PackageReleaseTests(unittest.TestCase):
    def _make_bundle(self, root):
        app = root / "NokoCord.app"
        for relative in sorted(EXPECTED_PACKAGE_FILES):
            path = app / pathlib.PurePosixPath(relative).relative_to("NokoCord.app")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode("utf-8"))
        return app

    def test_package_is_allowlisted_deterministic_and_checksumed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app = self._make_bundle(root)
            output = root / "NokoCord-Chiaki-C1.3.0.zip"

            command = [
                "sh",
                str(ROOT / "scripts" / "package-release.sh"),
                "--app",
                str(app),
                "--output",
                str(output),
            ]
            subprocess.run(command, check=True, cwd=ROOT)
            first_bytes = output.read_bytes()
            checksum = output.with_name("NokoCord-Chiaki-C1.3.0-SHA256SUMS.txt")
            self.assertTrue(checksum.is_file())

            with zipfile.ZipFile(output) as archive:
                self.assertEqual(set(archive.namelist()), EXPECTED_PACKAGE_FILES)
                self.assertFalse(any(name.startswith("__MACOSX/") for name in archive.namelist()))

            expected_digest = hashlib.sha256(first_bytes).hexdigest()
            self.assertEqual(checksum.read_text(), f"{expected_digest}  {output.name}\n")

            second_output = root / "second.zip"
            subprocess.run(
                [
                    "sh",
                    str(ROOT / "scripts" / "package-release.sh"),
                    "--app",
                    str(app),
                    "--output",
                    str(second_output),
                ],
                check=True,
                cwd=ROOT,
                stdout=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(second_output.read_bytes(), first_bytes)

            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to overwrite", result.stderr.lower())
            self.assertEqual(output.read_bytes(), first_bytes)

    def test_metadata_cli_emits_machine_readable_values(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "release_metadata.py"),
                "--json",
            ],
            check=True,
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["public_version"], "C1.3.0")
        self.assertEqual(payload["build_number"], "6")


if __name__ == "__main__":
    unittest.main()
