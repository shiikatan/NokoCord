#!/usr/bin/env python3
"""Read-only checks for a locally signed Release app; not notarization proof."""
import argparse
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys


def run(*arguments, include_stderr=False):
    result = subprocess.run(arguments, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(f"{arguments[0]} failed (exit {result.returncode})")
    return result.stdout + (result.stderr if include_stderr else b"")


EDITIONS = {
    "maomao": {
        "CFBundleIdentifier": "com.shiikatan.nokocord.maomao",
        "CFBundleShortVersionString": "1.3.0",
        "CFBundleVersion": "4",
        "NokoEditionID": "maomao",
        "NokoEditionName": "Maomao",
        "NokoPublicVersion": "M1.3.0",
        "NokoMaintainer": "Shiikatan",
    },
    "chiaki": {
        "CFBundleIdentifier": "com.shiikatan.nokocord.chiaki",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "NokoEditionID": "chiaki",
        "NokoEditionName": "Chiaki",
        "NokoPublicVersion": "C1.0.0",
        "NokoMaintainer": "Millx",
    },
}


def verify(app, edition=None, allow_unconfigured=False, allow_ad_hoc=False):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    expected = {
        "CFBundleIdentifier": "com.nokocord.NokoCord",
        "CFBundleName": "NokoCord",
        "CFBundleExecutable": "NokoCord",
        "CFBundlePackageType": "APPL",
    }
    if edition:
        expected.update(EDITIONS[edition])
    else:
        for key in ("NokoEditionID", "NokoEditionName", "NokoPublicVersion", "NokoMaintainer"):
            if info.get(key) not in (None, ""):
                raise ValueError(f"Unexpected foundation edition metadata: {key}")
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected {key}")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            raise ValueError(f"Missing {key}")
    identifier = info.get("NokoDiscordApplicationID", "")
    configured = isinstance(identifier, str) and identifier.isascii() and identifier.isdigit() and 0 < int(identifier) < 2**64
    if not configured and not allow_unconfigured:
        raise ValueError("A configured Discord application ID is required for a presence-capable release")
    schemes = [scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])]
    if schemes != ["nokocord"]:
        raise ValueError("Unexpected OAuth callback schemes")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("/usr/bin/codesign", "-dv", "--verbose=4", str(app), include_stderr=True).decode()
    team_match = re.search(r"^TeamIdentifier=(.+)$", signature, re.M)
    team = team_match.group(1) if team_match else None
    ad_hoc = "Signature=adhoc" in signature
    source_only = allow_ad_hoc and ad_hoc and team == "not set"
    if ad_hoc and not source_only:
        raise ValueError("Ad hoc signatures cannot validate SDK loading under hardened runtime; use developer signing for distribution, or --allow-ad-hoc for local source checks")
    project = pathlib.Path(__file__).resolve().parent.parent / "NokoCord.xcodeproj/project.pbxproj"
    runtime_settings = re.findall(r"ENABLE_HARDENED_RUNTIME\s*=\s*(\w+);", project.read_text())
    if not runtime_settings or any(value != "YES" for value in runtime_settings):
        raise ValueError("Production project hardened runtime settings must remain enabled")
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", signature)
    if not source_only and (not flags or not int(flags.group(1), 16) & 0x10000):
        raise ValueError("Hardened runtime is not enabled")
    entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)))
    required = {
        "com.apple.security.network.client",
        "com.apple.security.automation.apple-events",
        "com.apple.security.device.camera",
        "com.apple.security.device.audio-input",
        "com.apple.security.files.user-selected.read-write",
    }
    for key in required:
        if entitlements.get(key) is not True:
            raise ValueError(f"Required entitlement is absent: {key}")
    if entitlements.get("com.apple.security.app-sandbox") not in (None, False):
        raise ValueError("Maomao M1.3 must use the reviewed unsandboxed presence configuration")
    # Signing identity metadata is allowed; new capabilities require explicit review.
    allowed = required | {"com.apple.application-identifier", "com.apple.developer.team-identifier"}
    unexpected = set(entitlements) - allowed
    if unexpected:
        raise ValueError("Unreviewed entitlements: " + ", ".join(sorted(unexpected)))
    executable = app / "Contents/MacOS/NokoCord"
    architectures = run("/usr/bin/lipo", "-archs", str(executable)).decode().split()
    if "arm64" not in architectures:
        raise ValueError("Apple Silicon executable missing")
    helper = app / "Contents/Helpers/TanTranslator"
    run("/usr/bin/codesign", "--verify", "--strict", str(helper))
    helper_signature = run("/usr/bin/codesign", "-dv", "--verbose=4", str(helper), include_stderr=True).decode()
    helper_flags = re.search(r"flags=0x([0-9a-fA-F]+)", helper_signature)
    if not source_only and (not helper_flags or not int(helper_flags.group(1), 16) & 0x10000):
        raise ValueError("Translator hardened runtime is not enabled")
    helper_entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(helper)))
    if helper_entitlements != {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}:
        raise ValueError("Unexpected translator entitlements")
    if set(run("/usr/bin/lipo", "-archs", str(helper)).decode().split()) != set(architectures):
        raise ValueError("Translator architecture mismatch")
    updater = app / "Contents/Helpers/NokoCordUpdateHelper"
    run("/usr/bin/codesign", "--verify", "--strict", str(updater))
    updater_signature = run("/usr/bin/codesign", "-dv", "--verbose=4", str(updater), include_stderr=True).decode()
    updater_flags = re.search(r"flags=0x([0-9a-fA-F]+)", updater_signature)
    if not source_only and (not updater_flags or not int(updater_flags.group(1), 16) & 0x10000):
        raise ValueError("Updater hardened runtime is not enabled")
    if set(run("/usr/bin/lipo", "-archs", str(updater)).decode().split()) != set(architectures):
        raise ValueError("Updater architecture mismatch")
    framework = app / "Contents/Frameworks/discord_partner_sdk.framework"
    run("/usr/bin/codesign", "--verify", "--strict", str(framework))
    if not source_only:
        if team in (None, "not set"):
            raise ValueError("Developer signing Team ID is missing")
        for dependency in (helper, updater, framework, framework / "Versions/A/Frameworks/libdiscord_krisp.dylib"):
            dependency_signature = run("/usr/bin/codesign", "-dv", "--verbose=4", str(dependency), include_stderr=True).decode()
            dependency_team = re.search(r"^TeamIdentifier=(.+)$", dependency_signature, re.M)
            if not dependency_team or dependency_team.group(1) != team:
                raise ValueError("Embedded code signing Team ID differs from the application")
    sdk_binary = framework / "discord_partner_sdk"
    if not set(architectures).issubset(set(run("/usr/bin/lipo", "-archs", str(sdk_binary)).decode().split())):
        raise ValueError("Discord framework architecture mismatch")
    dependencies = run("/usr/bin/otool", "-L", str(executable)).decode()
    if "@rpath/discord_partner_sdk.framework/" not in dependencies:
        raise ValueError("Discord framework is not linked through rpath")
    load_commands = run("/usr/bin/otool", "-l", str(executable)).decode()
    if "@executable_path/../Frameworks" not in load_commands:
        raise ValueError("Embedded framework search path is missing")
    for resource in ("DiscordSocialSDK-License-Notices.txt", "TanTranslatorRuntime.js", "TypeScript-LICENSE.txt", "TypeScript-ThirdPartyNotices.txt", "NokoCord-LICENSE.txt"):
        if not (app / "Contents/Resources" / resource).is_file():
            raise ValueError(f"Missing required resource: {resource}")
    source_license = pathlib.Path(__file__).resolve().parent.parent / "LICENSE"
    if (app / "Contents/Resources/NokoCord-LICENSE.txt").read_bytes() != source_license.read_bytes():
        raise ValueError("Shipped NokoCord license differs from source license")
    # Scan the shipped bytes, not source or a build-status claim. Never print
    # matched data: a failure may identify a developer path or credential.
    private_patterns = {
        "local home path": re.compile(rb"/Users/[A-Za-z0-9_.-]+/"),
        "local-machine email": re.compile(rb"\b[\w.+-]+@[\w.-]+\.local\b", re.I),
        "private-key marker": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "Discord token shape": re.compile(rb"\b[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{25,110}\b"),
        "Discord webhook": re.compile(rb"https://(?:discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"),
    }
    release_diagnostics = (b"--nokocord-social-auth-smoke", b"NokoCord auth phase=", b"Social SDK smoke activity accepted")
    forbidden_parts = {".git", "xcuserdata", ".DS_Store", "BrowserProfiles", "CEFProfile", "WebKit", "private-backups", "DerivedData", ".build", "node_modules"}
    for path in app.rglob("*"):
        relative = path.relative_to(app)
        if any(part in forbidden_parts for part in relative.parts):
            raise ValueError(f"Private state path in artifact: {relative}")
        if path.name.endswith((".source.json", ".xcuserstate", ".p12", ".pfx", ".mobileprovision", ".log")):
            raise ValueError(f"Private or development artifact in bundle: {relative}")
        if path.is_file():
            data = path.read_bytes()
            if relative.as_posix() == "Contents/MacOS/NokoCord" and any(marker in data for marker in release_diagnostics):
                raise ValueError("Debug-only presence diagnostics found in Release")
            for label, pattern in private_patterns.items():
                matches = list(pattern.finditer(data))
                # This exact upstream TypeScript property chain happens to have
                # token-shaped segment lengths. Do not exempt the whole compiler.
                if relative.as_posix() == "Contents/Resources/TanTranslatorRuntime.js" and label == "Discord token shape":
                    matches = [match for match in matches if match.group() != b"configFileExistenceInfo.config.cachedDirectoryStructureHost"]
                # This pinned SDK library contains upstream assertion source paths.
                # Accept only the exact set reviewed against Discord's original package;
                # all other privacy patterns and every NokoCord-owned byte stay checked.
                if label == "local home path" and relative.as_posix() == "Contents/Frameworks/discord_partner_sdk.framework/Versions/A/Frameworks/libdiscord_krisp.dylib":
                    upstream_paths = sorted(set(re.findall(rb'/Users/[A-Za-z0-9_.-]+/[^\x00\r\n"\x20]*', data)))
                    if hashlib.sha256(b"\0".join(upstream_paths)).hexdigest() == "dc5df472c41a52b0e58b1315c6ea7581827c3d631c067d96714bc3f4c64725b4":
                        matches = []
                if matches:
                    raise ValueError(f"Artifact privacy scan: {label} in {relative}")
    label = f"{info['NokoEditionName']} {info['NokoPublicVersion']}" if edition else info['CFBundleShortVersionString']
    print(f"Release artifact checks passed: NokoCord {label} ({info['CFBundleVersion']})")
    print("Verified signature integrity, identity, callback scheme, architectures, framework/rpath, production hardened runtime settings, reviewed entitlements and shipped-byte privacy patterns.")
    if source_only:
        print("Ad hoc source verification only; this is not a distribution artifact. Runtime SDK loading requires a compatible local test signature or matching developer signatures.")
    if not configured:
        print("Unconfigured source build verified; Social SDK operations are disabled. This is not a presence-capable release.")
    print("Developer ID, notarization, runtime behavior and live Discord access remain separate release gates.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path, help="Path to the signed Release NokoCord.app")
    parser.add_argument("--edition", choices=sorted(EDITIONS), help="Require exact public edition identity")
    parser.add_argument("--allow-unconfigured", action="store_true", help="Validate an offline source build without a Discord application ID")
    parser.add_argument("--allow-ad-hoc", action="store_true", help="Validate local ad hoc source builds; not a distribution artifact")
    args = parser.parse_args()
    try:
        verify(args.app.resolve(strict=True), args.edition, args.allow_unconfigured, args.allow_ad_hoc)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Release artifact check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
