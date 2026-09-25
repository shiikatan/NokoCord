#!/usr/bin/env python3
"""Export and scan an exact committed source archive. Never zip the worktree."""
import argparse
import hashlib
import io
import json
import pathlib
import re
import subprocess
import tarfile


def git(*args):
    return subprocess.check_output(["git", *args])


def image_metadata_categories(path, data):
    """Return metadata categories without decoding or printing metadata values."""
    categories = []
    if path.lower().endswith(".png") and data.startswith(b"\x89PNG\r\n\x1a\n"):
        offset = 8
        while offset + 12 <= len(data):
            length = int.from_bytes(data[offset:offset + 4], "big")
            kind = data[offset + 4:offset + 8]
            end = offset + 12 + length
            if end > len(data):
                break
            if kind in {b"eXIf", b"tEXt", b"zTXt", b"iTXt"}:
                categories.append("image-metadata")
                break
            offset = end
    elif path.lower().endswith((".jpg", ".jpeg")) and data.startswith(b"\xff\xd8"):
        offset = 2
        while offset + 4 <= len(data) and data[offset] == 0xff:
            marker = data[offset + 1]
            if marker in {0xd8, 0xd9}:
                offset += 2
                continue
            length = int.from_bytes(data[offset + 2:offset + 4], "big")
            end = offset + 2 + length
            if end > len(data):
                break
            if marker == 0xe1 and data[offset + 4:offset + 10] == b"Exif\x00\x00":
                categories.append("image-metadata")
                break
            offset = end
    return categories


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--deny-file", type=pathlib.Path,
                        help="JSON array of private literal identity strings to reject")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Choose a new output path; existing archives are never overwritten")
    report_path = args.output.with_suffix(args.output.suffix + ".json")
    if report_path.exists():
        parser.error("Choose a new output path; existing archive reports are never overwritten")
    if git("diff", "--name-only") or git("diff", "--cached", "--name-only"):
        parser.error("Commit reviewed tracked changes before exporting a public candidate")
    revision = git("rev-parse", "HEAD").decode().strip()
    archive = git("archive", "--format=tar", revision)
    forbidden = {".git", ".agents", ".codex", "xcuserdata", "DerivedData", ".build", ".DS_Store", "__pycache__",
                 "private-backups", "BrowserProfiles", "WebKit", "CEFProfile", "Cookies",
                 "Local Storage", "Session Storage", "NetworkCache", "WebKitCache"}
    internal_documents = {
        "docs/MASTER_PLAN_V2_STATUS.md", "docs/PUBLIC_RELEASE_PRIVACY_CHECKLIST.md",
        "docs/REQUIREMENTS_AUDIT.md", "docs/BASELINE.md",
        "docs/HYBRID_IMPLEMENTATION.md", "docs/VERIFICATION.md",
    }
    patterns = {
        "private-home-path": re.compile(rb"/Users/(?!<)[A-Za-z0-9_.-]+/"),
        "local-email": re.compile(rb"\b[\w.+-]+@[\w.-]+\.local\b", re.I),
        "private-key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "aws-access-key": re.compile(rb"\bAKIA[A-Z0-9]{16}\b"),
        "discord-token-shape": re.compile(rb"\b[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{25,110}\b"),
        "discord-webhook": re.compile(rb"https://(?:discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"),
    }
    # A TypeScript compiler property chain has the same three-segment shape as
    # a Discord token. Exempt only that literal in files known to contain it.
    compiler_property = b"configFileExistenceInfo" + b".config.cachedDirectoryStructureHost"
    compiler_property_paths = {
        "NokoCord/Resources/TanTranslatorRuntime.js", "docs/PERFORMANCE.md",
        "scripts/verify-release.py",
    }
    deny_values = []
    if args.deny_file:
        try:
            loaded = json.loads(args.deny_file.read_text())
        except (OSError, json.JSONDecodeError) as error:
            parser.error(f"Cannot read deny file: {error}")
        if not isinstance(loaded, list) or any(not isinstance(value, str) or not value for value in loaded):
            parser.error("--deny-file must contain a JSON array of non-empty strings")
        deny_values = [(value, value.encode("utf-8")) for value in loaded]
    findings, files = [], 0
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        for member in source:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or any(part in forbidden for part in path.parts):
                findings.append({"path": member.name, "category": "private-or-unsafe-path"})
            if path.as_posix() in internal_documents:
                findings.append({"path": member.name, "category": "internal-process-document"})
            if member.isdir():
                continue
            if not member.isfile() or member.name.endswith((".log", ".xcuserstate", ".sqlite", ".db", ".p12", ".pfx", ".mobileprovision")) or path.name.startswith(".env"):
                findings.append({"path": member.name, "category": "unreviewed-artifact"})
                continue
            data = source.extractfile(member).read()
            assert data == git("show", f"{revision}:{member.name}"), "Archive/source mismatch"
            files += 1
            for name, pattern in patterns.items():
                matches = list(pattern.finditer(data))
                if name == "discord-token-shape" and member.name in compiler_property_paths:
                    matches = [match for match in matches if match.group() != compiler_property]
                if matches: findings.append({"path": member.name, "category": name})
            for _, value in deny_values:
                if value.lower() in data.lower():
                    findings.append({"path": member.name, "category": "private-deny-list"})
                    break
            for category in image_metadata_categories(member.name, data):
                findings.append({"path": member.name, "category": category})
    # Scan the exact tar bytes as well as extracted members. This catches a
    # deny-listed literal in tar metadata while keeping matched values private.
    for _, value in deny_values:
        if value.lower() in archive.lower():
            findings.append({"path": "<archive>", "category": "private-deny-list"})
            break
    report = {"revision": revision, "files": files, "archiveSHA256": hashlib.sha256(archive).hexdigest(),
              "sourceEquivalent": True, "findings": findings,
              "scope": "committed source archive only; no Git history, untracked or ignored files; heuristic scan is not a guarantee"}
    if findings:
        print(json.dumps(report, indent=2))
        raise SystemExit("Candidate failed the archive scan; no archive written")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(archive)
    report_path.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
