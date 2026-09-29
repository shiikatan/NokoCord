#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

APP_DIR="build/NokoCord.app"
OUTPUT=""
METADATA="Config/Edition.xcconfig"

usage() {
    echo "Usage: $0 [--app PATH] [--output PATH] [--metadata PATH]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            APP_DIR="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        --metadata)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            METADATA="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ -z "$OUTPUT" ]; then
    EDITION_NAME=$(python3 scripts/release_metadata.py --config "$METADATA" --field edition_name)
    PUBLIC_VERSION=$(python3 scripts/release_metadata.py --config "$METADATA" --field public_version)
    OUTPUT="build/NokoCord-${EDITION_NAME}-${PUBLIC_VERSION}.zip"
fi

exec python3 - "$APP_DIR" "$OUTPUT" "$METADATA" <<'PY'
import hashlib
import pathlib
import stat
import sys
import zipfile

ROOT = pathlib.Path.cwd()
sys.path.insert(0, str(ROOT / "scripts"))
from release_metadata import load_metadata


ALLOWLIST = {
    "Contents/Info.plist",
    "Contents/MacOS/NokoCord",
    "Contents/Helpers/TanTranslator",
    "Contents/Helpers/NokoMusicWatch.app/Contents/Info.plist",
    "Contents/Helpers/NokoMusicWatch.app/Contents/MacOS/NokoMusicWatch",
    "Contents/Helpers/NokoMusicWatch.app/Contents/Resources/AppIcon.icns",
    "Contents/Helpers/NokoMusicWatch.app/Contents/_CodeSignature/CodeResources",
    "Contents/_CodeSignature/CodeResources",
    "Contents/Resources/AppIcon.icns",
    "Contents/Resources/NokoCord-LICENSE.txt",
    "Contents/Resources/NokoMark.png",
    "Contents/Resources/TanTranslatorRuntime.js",
    "Contents/Resources/TypeScript-LICENSE.txt",
    "Contents/Resources/TypeScript-ThirdPartyNotices.txt",
}


def fail(message):
    raise SystemExit(f"package-release: {message}")


app = pathlib.Path(sys.argv[1]).expanduser().resolve()
output = pathlib.Path(sys.argv[2]).expanduser().resolve()
metadata = load_metadata(sys.argv[3])

if not app.is_dir() or app.name != "NokoCord.app":
    fail(f"app bundle is missing or not named NokoCord.app: {app}")
if output.suffix.lower() != ".zip":
    fail(f"output must have a .zip suffix: {output}")
checksum = output.with_name(output.stem + "-SHA256SUMS.txt")
if output.exists() or checksum.exists():
    fail(f"refusing to overwrite existing artifact: {output if output.exists() else checksum}")

files = []
for path in app.rglob("*"):
    if path.is_symlink():
        fail(f"symlink is not allowed in the release bundle: {path.relative_to(app)}")
    if path.is_file():
        files.append(path.relative_to(app).as_posix())
actual = set(files)
if actual != ALLOWLIST:
    missing = sorted(ALLOWLIST - actual)
    unexpected = sorted(actual - ALLOWLIST)
    details = []
    if missing:
        details.append("missing=" + ",".join(missing))
    if unexpected:
        details.append("unexpected=" + ",".join(unexpected))
    fail("bundle does not match the reviewed allowlist (" + "; ".join(details) + ")")

output.parent.mkdir(parents=True, exist_ok=True)
try:
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for relative in sorted(files):
            source = app / relative
            info = zipfile.ZipInfo("NokoCord.app/" + relative)
            info.date_time = (2020, 1, 1, 0, 0, 0)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IMODE(source.stat().st_mode) & 0xFFFF) << 16
            archive.writestr(info, source.read_bytes())
except FileExistsError:
    fail(f"refusing to overwrite existing artifact: {output}")

digest = hashlib.sha256(output.read_bytes()).hexdigest()
try:
    with checksum.open("x", encoding="utf-8") as stream:
        stream.write(f"{digest}  {output.name}\n")
except FileExistsError:
    output.unlink()
    fail(f"refusing to overwrite existing artifact: {checksum}")

print(f"Packaged {metadata.edition_name} {metadata.public_version}: {output}")
print(f"SHA-256: {digest}")
print(f"Checksum file: {checksum}")
PY
