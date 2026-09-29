#!/usr/bin/env python3
"""Tests for the shared Xcode, SwiftPM, CLI, and package build contract."""

import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "NokoCord.xcodeproj" / "project.pbxproj"
BUILD = ROOT / "scripts" / "build.sh"
VERIFY = ROOT / "scripts" / "verify.sh"
PACKAGE = ROOT / "scripts" / "package-release.sh"
RELEASE_VERIFIER = ROOT / "scripts" / "verify-release.py"
PACKAGE_SWIFT = ROOT / "Package.swift"
sys.path.insert(0, str(ROOT / "scripts"))
from release_metadata import RELEASE_PACKAGE_FILES  # noqa: E402

EXPECTED_RELEASE_FILES = {
    "Contents/Info.plist",
    "Contents/MacOS/NokoCord",
    "Contents/Helpers/TanTranslator",
    "Contents/Helpers/NokoMusicWatch.app/Contents/Info.plist",
    "Contents/Helpers/NokoMusicWatch.app/Contents/MacOS/NokoMusicWatch",
    "Contents/Helpers/NokoMusicWatch.app/Contents/Resources/AppIcon.icns",
    "Contents/Helpers/NokoMusicWatch.app/Contents/_CodeSignature/CodeResources",
    "Contents/_CodeSignature/CodeResources",
    "Contents/Resources/AppIcon.icns",
    "Contents/Resources/Localizable.xcstrings",
    "Contents/Resources/NokoCord-LICENSE.txt",
    "Contents/Resources/NokoMark.png",
    "Contents/Resources/TanTranslatorRuntime.js",
    "Contents/Resources/TypeScript-LICENSE.txt",
    "Contents/Resources/TypeScript-ThirdPartyNotices.txt",
}


def run_verify_resource_tool(path):
    return subprocess.run(
        ["sh", str(VERIFY), "--check-resource-tool", str(path)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )


class BuildParityTests(unittest.TestCase):
    def test_xcode_declares_the_music_watch_target_and_embed_phase(self):
        project = PROJECT.read_text(encoding="utf-8")

        self.assertIn("name = NokoMusicWatch;", project)
        self.assertIn('productType = "com.apple.product-type.application";', project)
        self.assertIn("path = Tools/NokoMusicWatch;", project)
        self.assertIn("main.swift in NokoMusicWatch Sources", project)
        self.assertIn('NokoMusicWatch.app in Embed NokoMusicWatch Helper', project)
        self.assertIn('name = "Embed NokoMusicWatch Helper";', project)
        self.assertIn('dstPath = "Contents/Helpers";', project)
        self.assertIn('remoteInfo = NokoMusicWatch;', project)

    def test_music_watch_uses_canonical_identity_and_local_signing(self):
        project = PROJECT.read_text(encoding="utf-8")
        match = re.search(
            r'/\* Debug configuration for PBXNativeTarget "NokoMusicWatch" \*/ = \{(.*?)\n\s*\};\n\s*[A-F0-9]+ .*?Release configuration for PBXNativeTarget "NokoMusicWatch"',
            project,
            re.DOTALL,
        )

        self.assertIsNotNone(match, "NokoMusicWatch must have a Debug and Release configuration")
        settings = match.group(1)
        self.assertIn('CURRENT_PROJECT_VERSION = "$(NOKO_BUILD_NUMBER)";', settings)
        self.assertIn('MACOSX_DEPLOYMENT_TARGET = "$(NOKO_DEPLOYMENT_TARGET)";', settings)
        self.assertIn('MARKETING_VERSION = "$(NOKO_APPLE_VERSION)";', settings)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "$(NOKO_BUNDLE_ID).musicwatch";', settings)
        self.assertIn("ENABLE_APP_SANDBOX = NO;", settings)
        self.assertIn("ENABLE_HARDENED_RUNTIME = NO;", settings)
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;", settings)
        self.assertIn("GENERATE_INFOPLIST_FILE = YES;", settings)

    def test_swiftpm_reads_the_canonical_deployment_target(self):
        manifest = PACKAGE_SWIFT.read_text(encoding="utf-8")

        self.assertIn("NOKO_DEPLOYMENT_TARGET", manifest)
        self.assertIn("Config/Edition.xcconfig", manifest)
        self.assertNotIn('platforms: [.macOS("26.0")]', manifest)

    def test_swiftpm_copies_localization_resources_without_host_compiler(self):
        manifest = PACKAGE_SWIFT.read_text(encoding="utf-8")

        self.assertIn('resources: [.copy("Resources")]', manifest)
        self.assertIn('resources: [.copy("Fixtures")]', manifest)

    def test_cli_and_package_keep_the_reviewed_helper_resource_manifest(self):
        build = BUILD.read_text(encoding="utf-8")
        package = PACKAGE.read_text(encoding="utf-8")
        verifier = RELEASE_VERIFIER.read_text(encoding="utf-8")

        self.assertIn('WATCH_DIR="${HELPERS_DIR}/NokoMusicWatch.app"', build)
        self.assertIn('Tools/NokoMusicWatch/main.swift', build)
        self.assertIn('RELEASE_PACKAGE_FILES', package)
        self.assertIn('RELEASE_PACKAGE_FILES', verifier)
        self.assertIn('NokoCord/Resources/Localizable.xcstrings', build)

        for relative in EXPECTED_RELEASE_FILES:
            self.assertIn(relative, RELEASE_PACKAGE_FILES, relative)

    def test_verifier_and_packager_share_the_exact_manifest(self):
        package = PACKAGE.read_text(encoding="utf-8")
        verifier = RELEASE_VERIFIER.read_text(encoding="utf-8")

        self.assertIn("RELEASE_PACKAGE_FILES", package)
        self.assertIn("RELEASE_PACKAGE_FILES", verifier)
        self.assertIn("actual_files", verifier)
        self.assertIn("actual_files != RELEASE_PACKAGE_FILES", verifier)

    def test_verify_runs_parity_before_swiftpm(self):
        verify = VERIFY.read_text(encoding="utf-8")

        self.assertLess(
            verify.index("python3 scripts/test_build_parity.py"),
            verify.index("swift test"),
        )

    def test_missing_resource_tool_has_an_actionable_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = pathlib.Path(directory) / "xcstringstool"
            result = run_verify_resource_tool(missing)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("xcstringstool", output)
        self.assertIn("full Xcode", output)
        self.assertIn("xcode-select", output)
        self.assertRegex(output.lower(), r"missing|not found|does not exist")

    def test_non_executable_resource_tool_has_an_actionable_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            non_executable = pathlib.Path(directory) / "xcstringstool"
            non_executable.write_text("not a compiler\n", encoding="utf-8")
            result = run_verify_resource_tool(non_executable)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("xcstringstool", output)
        self.assertIn("not executable", output.lower())
        self.assertIn("full Xcode", output)
        self.assertIn("xcode-select", output)


if __name__ == "__main__":
    unittest.main()
