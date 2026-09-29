#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

resource_tool_help() {
    echo "SwiftPM resource compilation requires Apple's xcstringstool from full Xcode." >&2
    echo "Install full Xcode and select it with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
    echo "Command Line Tools alone cannot compile .xcstrings resources." >&2
}

check_resource_tool() {
    candidate="$1"
    if [ -z "$candidate" ]; then
        echo "xcstringstool was not found." >&2
        resource_tool_help
        return 1
    fi
    if [ ! -e "$candidate" ]; then
        echo "xcstringstool was not found." >&2
        resource_tool_help
        return 1
    fi
    if [ ! -x "$candidate" ]; then
        echo "xcstringstool is not executable." >&2
        resource_tool_help
        return 1
    fi
    echo "xcstringstool is available from the selected Xcode toolchain."
}

if [ "${1:-}" = "--check-resource-tool" ]; then
    [ "$#" -eq 2 ] || {
        echo "Usage: $0 --check-resource-tool PATH" >&2
        exit 2
    }
    check_resource_tool "$2"
    exit $?
fi

XCSTRINGSTOOL=$(xcrun --find xcstringstool 2>/dev/null || true)
check_resource_tool "$XCSTRINGSTOOL"

python3 scripts/test_release_metadata.py
python3 scripts/test_build_parity.py
swift test --scratch-path /private/tmp/NokoCord-tests
python3 -m unittest discover -s Broker -v
xcodebuild -project NokoCord.xcodeproj -list
XCODE_DERIVED_DATA=/private/tmp/NokoCord-chiaki-build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Debug -destination 'platform=macOS' -derivedDataPath "$XCODE_DERIVED_DATA" CODE_SIGN_IDENTITY=- build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release -destination 'platform=macOS' -derivedDataPath "$XCODE_DERIVED_DATA" CODE_SIGN_IDENTITY=- build
test -d "$XCODE_DERIVED_DATA/Build/Products/Debug/NokoCord.app/Contents/Helpers/NokoMusicWatch.app"
test -d "$XCODE_DERIVED_DATA/Build/Products/Release/NokoCord.app/Contents/Helpers/NokoMusicWatch.app"
node --test Tools/TanTranslator/translator.test.mjs
sh scripts/build.sh
python3 scripts/verify-release.py build/NokoCord.app --edition chiaki --metadata Config/Edition.xcconfig
PACKAGE_GATE_DIR=$(mktemp -d /private/tmp/NokoCord-release.XXXXXX)
trap 'rm -rf "$PACKAGE_GATE_DIR"' EXIT
sh scripts/package-release.sh --app build/NokoCord.app --output "${PACKAGE_GATE_DIR}/NokoCord-release.zip"
python3 - "${PACKAGE_GATE_DIR}" <<'PY'
import hashlib
import pathlib
import sys
import tempfile
import zipfile

sys.path.insert(0, "scripts")
from release_metadata import RELEASE_PACKAGE_FILES

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
    expected = {"NokoCord.app/" + path for path in RELEASE_PACKAGE_FILES}
    if set(source.namelist()) != expected:
        raise SystemExit("release package file manifest does not match the reviewed manifest")
    with tempfile.TemporaryDirectory(prefix="NokoCord-extract-") as extracted:
        destination = pathlib.Path(extracted)
        for member in source.namelist():
            target = (destination / member).resolve()
            if destination.resolve() not in target.parents:
                raise SystemExit("release package contains a path traversal entry")
        source.extractall(destination)
        if not (destination / "NokoCord.app/Contents/Info.plist").is_file():
            raise SystemExit("release package extraction is missing the app Info.plist")
print(f"Release package checks passed: {archive}")
PY
git diff --check
