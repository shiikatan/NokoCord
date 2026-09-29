#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/test_release_metadata.py
swift test --scratch-path /private/tmp/NokoCord-tests
python3 -m unittest discover -s Broker -v
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-chiaki-build CODE_SIGN_IDENTITY=- build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-chiaki-build CODE_SIGN_IDENTITY=- build
# The Xcode target does not build the Apple Music helper, so the release checks
# run against the artifact that is actually published: scripts/build.sh is what
# compiles, assembles and signs the shipping bundle.
sh scripts/build.sh
python3 scripts/verify-release.py build/NokoCord.app --edition chiaki --metadata Config/Edition.xcconfig
PACKAGE_GATE_DIR=$(mktemp -d /private/tmp/NokoCord-release.XXXXXX)
trap 'rm -rf "$PACKAGE_GATE_DIR"' EXIT
sh scripts/package-release.sh --app build/NokoCord.app --output "${PACKAGE_GATE_DIR}/NokoCord-release.zip"
python3 - "${PACKAGE_GATE_DIR}" <<'PY'
import hashlib
import pathlib
import sys
import zipfile

directory = pathlib.Path(sys.argv[1])
archive = directory / "NokoCord-release.zip"
checksum = directory / "NokoCord-release-SHA256SUMS.txt"
if not archive.is_file() or not checksum.is_file():
    raise SystemExit("release package gate did not produce both artifacts")
expected = hashlib.sha256(archive.read_bytes()).hexdigest()
if checksum.read_text() != f"{expected}  {archive.name}\n":
    raise SystemExit("release package checksum does not match the archive")
with zipfile.ZipFile(archive) as source:
    if any(name.startswith("__MACOSX/") for name in source.namelist()):
        raise SystemExit("release package contains macOS metadata entries")
    if not source.namelist():
        raise SystemExit("release package is empty")
print(f"Release package checks passed: {archive}")
PY
git diff --check
