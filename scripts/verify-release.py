#!/usr/bin/env python3
"""Read-only checks for a locally signed Release app; not notarization proof."""
import argparse
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
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "NokoEditionID": "maomao",
        "NokoEditionName": "Maomao",
        "NokoPublicVersion": "M1.0.0",
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


def verify(app, edition=None):
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
    schemes = [scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])]
    if schemes != ["nokocord"]:
        raise ValueError("Unexpected OAuth callback schemes")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("/usr/bin/codesign", "-dv", "--verbose=4", str(app), include_stderr=True).decode()
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", signature)
    if not flags or not int(flags.group(1), 16) & 0x10000:
        raise ValueError("Hardened runtime is not enabled")
    entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)))
    required = {
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
        "com.apple.security.device.camera",
        "com.apple.security.device.audio-input",
        "com.apple.security.files.user-selected.read-write",
    }
    for key in required:
        if entitlements.get(key) is not True:
            raise ValueError(f"Required entitlement is absent: {key}")
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
    if not helper_flags or not int(helper_flags.group(1), 16) & 0x10000:
        raise ValueError("Translator hardened runtime is not enabled")
    helper_entitlements = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(helper)))
    if helper_entitlements != {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}:
        raise ValueError("Unexpected translator entitlements")
    if set(run("/usr/bin/lipo", "-archs", str(helper)).decode().split()) != set(architectures):
        raise ValueError("Translator architecture mismatch")
    for resource in ("TanTranslatorRuntime.js", "TypeScript-LICENSE.txt", "TypeScript-ThirdPartyNotices.txt", "NokoCord-LICENSE.txt"):
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
    forbidden_parts = {".git", "xcuserdata", ".DS_Store", "BrowserProfiles", "CEFProfile", "WebKit", "private-backups", "DerivedData", ".build", "node_modules"}
    for path in app.rglob("*"):
        relative = path.relative_to(app)
        if any(part in forbidden_parts for part in relative.parts):
            raise ValueError(f"Private state path in artifact: {relative}")
        if path.name.endswith((".source.json", ".xcuserstate", ".p12", ".pfx", ".mobileprovision", ".log")):
            raise ValueError(f"Private or development artifact in bundle: {relative}")
        if path.is_file():
            data = path.read_bytes()
            for label, pattern in private_patterns.items():
                matches = list(pattern.finditer(data))
                # This exact upstream TypeScript property chain happens to have
                # token-shaped segment lengths. Do not exempt the whole compiler.
                if relative.as_posix() == "Contents/Resources/TanTranslatorRuntime.js" and label == "Discord token shape":
                    matches = [match for match in matches if match.group() != b"configFileExistenceInfo.config.cachedDirectoryStructureHost"]
                if matches:
                    raise ValueError(f"Artifact privacy scan: {label} in {relative}")
    label = f"{info['NokoEditionName']} {info['NokoPublicVersion']}" if edition else info['CFBundleShortVersionString']
    print(f"Release artifact checks passed: NokoCord {label} ({info['CFBundleVersion']})")
    print("Verified signature integrity, identity, callback scheme, Apple Silicon, hardened runtime and reviewed sandbox entitlements and shipped-byte privacy patterns.")
    print("Developer ID, notarization, runtime behavior and live Discord access remain separate release gates.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path, help="Path to the signed Release NokoCord.app")
    parser.add_argument("--edition", choices=sorted(EDITIONS), help="Require exact public edition identity")
    args = parser.parse_args()
    try:
        verify(args.app.resolve(strict=True), args.edition)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Release artifact check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
