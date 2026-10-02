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


def read_entitlements(path):
    result = subprocess.run(
        ("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)),
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise ValueError(f"Could not inspect entitlements for {path.name}")
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def signature_details(path):
    signature = run("/usr/bin/codesign", "-dv", "--verbose=4", str(path), include_stderr=True).decode()
    team_match = re.search(r"^TeamIdentifier=(.+)$", signature, re.M)
    team = team_match.group(1) if team_match else None
    return signature, team


def verify_updater_identity_entitlements(entitlements, signature, team):
    identity_keys = {"com.apple.application-identifier", "com.apple.developer.team-identifier"}
    unexpected = set(entitlements) - identity_keys
    if unexpected:
        raise ValueError("Updater carries an unapproved security entitlement")
    team_entitlement = entitlements.get("com.apple.developer.team-identifier")
    if team_entitlement is not None and team_entitlement != team:
        raise ValueError("Updater Team ID entitlement differs from its signature")
    application_identifier = entitlements.get("com.apple.application-identifier")
    if application_identifier is not None:
        identifier_match = re.search(r"^Identifier=(.+)$", signature, re.M)
        code_identifier = identifier_match.group(1) if identifier_match else ""
        adhoc_helper_marker = (
            application_identifier == ".UpdateHelper"
            and "Signature=adhoc" in signature
            and team in (None, "not set")
            and code_identifier.startswith("NokoCordUpdateHelper-")
        )
        if not adhoc_helper_marker and (not code_identifier or not (
            application_identifier == code_identifier
            or application_identifier.endswith("." + code_identifier.lstrip("."))
        )):
            raise ValueError("Updater application identifier does not match its code signature")
        if team not in (None, "not set") and not application_identifier.startswith(team + "."):
            raise ValueError("Updater application identifier does not match the signing Team ID")
        if team in (None, "not set") and team_entitlement is not None:
            raise ValueError("Ad hoc updater must not carry a Team ID entitlement")


def code_objects(app, known_objects):
    """Return every embedded code container plus explicitly named helpers."""
    objects = set(known_objects)
    code_suffixes = {".app", ".appex", ".bundle", ".dylib", ".framework", ".xpc"}
    for path in app.rglob("*"):
        if path.suffix in code_suffixes:
            objects.add(path)
    return sorted(objects, key=lambda item: (len(item.parts), str(item)))


def verify_runpaths(binary, expected, label):
    load_commands = run("/usr/bin/otool", "-l", str(binary)).decode()
    lines = load_commands.splitlines()
    actual = set()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for candidate in lines[index + 1:index + 7]:
            match = re.match(r"\s*path (\S+) \(offset \d+\)$", candidate)
            if match:
                actual.add(match.group(1))
                break
    if actual != expected:
        raise ValueError(f"Unexpected {label} runpaths: {', '.join(sorted(actual)) or '<none>'}")


def verify_library_paths(binary, label):
    output = run("/usr/bin/otool", "-L", str(binary)).decode()
    for line in output.splitlines():
        match = re.match(r"\s+(.+?) \(compatibility version ", line)
        if not match:
            continue
        dependency = match.group(1)
        if dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/")):
            continue
        raise ValueError(f"Uncontrolled {label} library path: {dependency}")


HARDENED_RUNTIME_EXCEPTIONS = {
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.get-task-allow",
}


def require_hardened_runtime(signature, label):
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", signature)
    if not flags or not int(flags.group(1), 16) & 0x10000:
        raise ValueError(f"{label} hardened runtime is not enabled")


EDITIONS = {
    "maomao": {
        "CFBundleIdentifier": "com.shiikatan.nokocord.maomao",
        "CFBundleShortVersionString": "1.3.1",
        "CFBundleVersion": "5",
        "NokoEditionID": "maomao",
        "NokoEditionName": "Maomao",
        "NokoPublicVersion": "M1.3.1",
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


def verify(app, edition=None, allow_unconfigured=False, allow_ad_hoc=False, ad_hoc_release=False):
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
    signature, team = signature_details(app)
    ad_hoc = "Signature=adhoc" in signature
    source_only = allow_ad_hoc
    if allow_ad_hoc and ad_hoc_release:
        raise ValueError("Choose either source-only ad hoc verification or --ad-hoc-release")
    if source_only and (not ad_hoc or team != "not set"):
        raise ValueError("Source-only verification requires an ad hoc signature without a Team ID")
    if ad_hoc_release and (not ad_hoc or team != "not set"):
        raise ValueError("--ad-hoc-release requires an ad hoc signature without a Team ID")
    if ad_hoc and not (source_only or ad_hoc_release):
        raise ValueError("Ad hoc signatures require --allow-ad-hoc for source checks or --ad-hoc-release for distribution checks")
    if not ad_hoc and (source_only or ad_hoc_release):
        raise ValueError("Ad hoc verification mode cannot be used with a developer-signed app")
    project = pathlib.Path(__file__).resolve().parent.parent / "NokoCord.xcodeproj/project.pbxproj"
    runtime_settings = re.findall(r"ENABLE_HARDENED_RUNTIME\s*=\s*(\w+);", project.read_text())
    if not runtime_settings or any(value != "YES" for value in runtime_settings):
        raise ValueError("Production project hardened runtime settings must remain enabled")
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", signature)
    if not source_only:
        require_hardened_runtime(signature, "Application")
    entitlements = read_entitlements(app)
    required = {
        "com.apple.security.network.client",
        "com.apple.security.automation.apple-events",
        "com.apple.security.device.camera",
        "com.apple.security.device.audio-input",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.cs.disable-library-validation",
    }
    for key in required:
        if entitlements.get(key) is not True:
            raise ValueError(f"Required entitlement is absent: {key}")
    if entitlements.get("com.apple.security.app-sandbox") not in (None, False):
        raise ValueError("Maomao M1.3 must use the reviewed unsandboxed presence configuration")
    # Signing identity metadata is allowed only when it matches the signature.
    identity_keys = {"com.apple.application-identifier", "com.apple.developer.team-identifier"}
    allowed = required | identity_keys | {"com.apple.security.app-sandbox"}
    unexpected = set(entitlements) - allowed
    if unexpected:
        raise ValueError("Unreviewed entitlements: " + ", ".join(sorted(unexpected)))
    if entitlements.get("com.apple.security.cs.disable-library-validation") is not True:
        raise ValueError("The reviewed main-app library-validation exception is absent")
    if team in (None, "not set") and identity_keys & set(entitlements):
        raise ValueError("Ad hoc app must not carry developer signing identity entitlements")
    if entitlements.get("com.apple.developer.team-identifier", team) != team:
        raise ValueError("Application Team ID entitlement differs from its signature")
    application_identifier = entitlements.get("com.apple.application-identifier")
    if application_identifier and not application_identifier.endswith("." + info["CFBundleIdentifier"]):
        raise ValueError("Application identifier entitlement does not match the bundle identifier")
    if application_identifier and team not in (None, "not set") and not application_identifier.startswith(team + "."):
        raise ValueError("Application identifier entitlement does not match the signing Team ID")
    executable = app / "Contents/MacOS/NokoCord"
    architectures = run("/usr/bin/lipo", "-archs", str(executable)).decode().split()
    if "arm64" not in architectures:
        raise ValueError("Apple Silicon executable missing")
    helper = app / "Contents/Helpers/TanTranslator"
    run("/usr/bin/codesign", "--verify", "--strict", str(helper))
    helper_signature, _ = signature_details(helper)
    if not source_only:
        require_hardened_runtime(helper_signature, "Translator")
    helper_entitlements = read_entitlements(helper)
    if helper_entitlements != {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}:
        raise ValueError("Unexpected translator entitlements")
    if set(run("/usr/bin/lipo", "-archs", str(helper)).decode().split()) != set(architectures):
        raise ValueError("Translator architecture mismatch")
    updater = app / "Contents/Helpers/NokoCordUpdateHelper"
    run("/usr/bin/codesign", "--verify", "--strict", str(updater))
    updater_signature, _ = signature_details(updater)
    if not source_only:
        require_hardened_runtime(updater_signature, "Updater")
    updater_entitlements = read_entitlements(updater)
    verify_updater_identity_entitlements(updater_entitlements, updater_signature, _)
    if set(run("/usr/bin/lipo", "-archs", str(updater)).decode().split()) != set(architectures):
        raise ValueError("Updater architecture mismatch")
    framework = app / "Contents/Frameworks/discord_partner_sdk.framework"
    run("/usr/bin/codesign", "--verify", "--strict", str(framework))
    krisp = framework / "Versions/A/Frameworks/libdiscord_krisp.dylib"
    if not source_only and not ad_hoc_release and team in (None, "not set"):
        raise ValueError("Developer signing Team ID is missing")
    embedded_code = code_objects(app, (app, helper, updater, framework, krisp))
    for code in embedded_code:
        code_signature, code_team = signature_details(code)
        if code != app:
            run("/usr/bin/codesign", "--verify", "--strict", str(code))
        if ad_hoc_release:
            if "Signature=adhoc" not in code_signature or code_team != "not set":
                raise ValueError(f"Ad hoc release contains code without an ad hoc signature: {code.relative_to(app)}")
        elif not source_only and code_team != team:
            raise ValueError(f"Embedded code signing Team ID differs from the application: {code.relative_to(app)}")
        code_entitlements = read_entitlements(code)
        if code in (helper, updater, framework, krisp):
            exceptions = HARDENED_RUNTIME_EXCEPTIONS & set(code_entitlements)
            if exceptions:
                raise ValueError(f"Hardened-runtime exception or get-task-allow entitlement in embedded code: {code.relative_to(app)}")
        if code == updater:
            verify_updater_identity_entitlements(code_entitlements, code_signature, code_team)
        elif code not in (app, helper):
            if code_entitlements:
                raise ValueError(f"Unexpected entitlements in embedded code: {code.relative_to(app)}")
    sdk_binary = framework / "discord_partner_sdk"
    if not set(architectures).issubset(set(run("/usr/bin/lipo", "-archs", str(sdk_binary)).decode().split())):
        raise ValueError("Discord framework architecture mismatch")
    dependencies = run("/usr/bin/otool", "-L", str(executable)).decode()
    if "@rpath/discord_partner_sdk.framework/" not in dependencies:
        raise ValueError("Discord framework is not linked through rpath")
    verify_runpaths(executable, {"@executable_path/../Frameworks"}, "application")
    sdk_binary = framework / "Versions/A/discord_partner_sdk"
    verify_runpaths(sdk_binary, set(), "Discord SDK")
    verify_runpaths(krisp, set(), "Krisp")
    for binary, label in ((executable, "application"), (sdk_binary, "Discord SDK"), (krisp, "Krisp")):
        verify_library_paths(binary, label)
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
        print("Ad hoc source verification only; this is not a distribution artifact. It checks local build integrity without asserting release signing behavior.")
    if ad_hoc_release:
        print("Ad hoc release layout verified. This package is not Developer ID signed or notarized; users may need to approve it in System Settings > Privacy & Security.")
    if not configured:
        print("Unconfigured source build verified; Social SDK operations are disabled. This is not a presence-capable release.")
    print("Runtime behavior and live Discord access are separate validation evidence.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path, help="Path to the signed Release NokoCord.app")
    parser.add_argument("--edition", choices=sorted(EDITIONS), help="Require exact public edition identity")
    parser.add_argument("--allow-unconfigured", action="store_true", help="Validate an offline source build without a Discord application ID")
    ad_hoc_group = parser.add_mutually_exclusive_group()
    ad_hoc_group.add_argument("--allow-ad-hoc", action="store_true", help="Validate a local ad hoc source build only; not a distribution artifact")
    ad_hoc_group.add_argument("--ad-hoc-release", action="store_true", help="Validate a hardened ad hoc distribution layout; not notarization or Gatekeeper proof")
    args = parser.parse_args()
    try:
        verify(args.app.resolve(strict=True), args.edition, args.allow_unconfigured, args.allow_ad_hoc, args.ad_hoc_release)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Release artifact check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
