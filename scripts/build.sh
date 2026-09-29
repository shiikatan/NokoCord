#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

METADATA_CONFIG="Config/Edition.xcconfig"
metadata() {
    python3 scripts/release_metadata.py --config "$METADATA_CONFIG" --field "$1"
}

BUNDLE_ID=$(metadata bundle_id)
APPLE_VERSION=$(metadata apple_version)
BUILD_NUMBER=$(metadata build_number)
DEPLOYMENT_TARGET=$(metadata deployment_target)
EDITION_ID=$(metadata edition)
EDITION_NAME=$(metadata edition_name)
PUBLIC_VERSION=$(metadata public_version)
MAINTAINER=$(metadata maintainer)
WATCHER_BUNDLE_ID="${BUNDLE_ID%.*}.musicwatch"
SWIFT_TARGET="arm64-apple-macos${DEPLOYMENT_TARGET}"

# Detect Command Line Tools macOS SDK
# On macOS 27 beta Command Line Tools, libSwiftUIMacros is not bundled;
# using MacOSX26.sdk uses native SwiftUI property wrappers seamlessly.
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
elif [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
elif [ -z "${SDKROOT:-}" ]; then
    export SDKROOT="$(xcrun --show-sdk-path 2>/dev/null || echo '')"
fi

BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/NokoCord.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Preparing build directories in ${BUILD_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}"

echo "==> [1/6] Compiling TanTranslator helper..."
swiftc -target "${SWIFT_TARGET}" Tools/TanTranslator/Helper/main.swift -O -o "${HELPERS_DIR}/TanTranslator"

echo "==> [2/6] Compiling NokoCord native binary with swiftc..."
CPU_CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
SWIFT_FILES=$(find NokoCord -name "*.swift")
swiftc -target "${SWIFT_TARGET}" -parse-as-library -j"${CPU_CORES}" ${SWIFT_FILES} -O -o "${MACOS_DIR}/NokoCord"

echo "==> [3/6] Packaging resources and app icon..."
cp NokoCord/Resources/TanTranslatorRuntime.js "${RESOURCES_DIR}/"
cp NokoCord/Resources/TypeScript-LICENSE.txt "${RESOURCES_DIR}/"
cp NokoCord/Resources/TypeScript-ThirdPartyNotices.txt "${RESOURCES_DIR}/"
cp LICENSE "${RESOURCES_DIR}/NokoCord-LICENSE.txt"
cp NokoCord/Assets.xcassets/NokoMark.imageset/noko-256.png "${RESOURCES_DIR}/NokoMark.png"

# Generate AppIcon.icns from asset catalog PNGs
TMP_ICONSET="/tmp/NokoCord_AppIcon.iconset"
rm -rf "${TMP_ICONSET}"
mkdir -p "${TMP_ICONSET}"
APPICON_SRC="NokoCord/Assets.xcassets/AppIcon.appiconset"
cp "${APPICON_SRC}/icon-16@1x.png" "${TMP_ICONSET}/icon_16x16.png"
cp "${APPICON_SRC}/icon-16@2x.png" "${TMP_ICONSET}/icon_16x16@2x.png"
cp "${APPICON_SRC}/icon-32@1x.png" "${TMP_ICONSET}/icon_32x32.png"
cp "${APPICON_SRC}/icon-32@2x.png" "${TMP_ICONSET}/icon_32x32@2x.png"
cp "${APPICON_SRC}/icon-128@1x.png" "${TMP_ICONSET}/icon_128x128.png"
cp "${APPICON_SRC}/icon-128@2x.png" "${TMP_ICONSET}/icon_128x128@2x.png"
cp "${APPICON_SRC}/icon-256@1x.png" "${TMP_ICONSET}/icon_256x256.png"
cp "${APPICON_SRC}/icon-256@2x.png" "${TMP_ICONSET}/icon_256x256@2x.png"
cp "${APPICON_SRC}/icon-512@1x.png" "${TMP_ICONSET}/icon_512x512.png"
cp "${APPICON_SRC}/icon-512@2x.png" "${TMP_ICONSET}/icon_512x512@2x.png"
iconutil -c icns "${TMP_ICONSET}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "${TMP_ICONSET}"

echo "==> [1b/6] Building NokoMusicWatch helper..."
WATCH_DIR="${HELPERS_DIR}/NokoMusicWatch.app"
WATCH_MACOS="${WATCH_DIR}/Contents/MacOS"
mkdir -p "${WATCH_MACOS}" "${WATCH_DIR}/Contents/Resources"
swiftc -target "${SWIFT_TARGET}" Tools/NokoMusicWatch/main.swift -O -o "${WATCH_MACOS}/NokoMusicWatch"
cp "${RESOURCES_DIR}/AppIcon.icns" "${WATCH_DIR}/Contents/Resources/AppIcon.icns"
cat << WATCH_PLIST_EOF > "${WATCH_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>NokoMusicWatch</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${WATCHER_BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>NokoMusicWatch</string>
	<key>CFBundleShortVersionString</key>
	<string>${APPLE_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${DEPLOYMENT_TARGET}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Read the Apple Music playback position so your Discord listening activity stays in sync with the song, including when you seek or repeat a track.</string>
</dict>
</plist>
WATCH_PLIST_EOF

echo "==> [4/6] Generating Info.plist..."
cat << PLIST_EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleName</key>
	<string>NokoCord</string>
	<key>CFBundleExecutable</key>
	<string>NokoCord</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleShortVersionString</key>
	<string>${APPLE_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>NokoCord's Apple Music helper reads the player's current track and position so your Discord listening activity stays in sync. NokoCord itself never controls Music.</string>
	<key>NokoEditionID</key>
	<string>${EDITION_ID}</string>
	<key>NokoEditionName</key>
	<string>${EDITION_NAME}</string>
	<key>NokoPublicVersion</key>
	<string>${PUBLIC_VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${DEPLOYMENT_TARGET}</string>
	<key>NokoMaintainer</key>
	<string>${MAINTAINER}</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.nokocord.NokoCord.oauth</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>nokocord</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
		</dict>
	</array>
	<key>NSCameraUsageDescription</key>
	<string>Preview your selected camera locally when you start a device check. No video is sent to Discord.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Show your microphone input level when you start a local device check. No audio is sent to Discord.</string>
</dict>
</plist>
PLIST_EOF

echo "==> [5/6] Code signing with hardened runtime and sandboxing..."
/usr/bin/codesign --force --sign - --options runtime \
    --entitlements Config/TanTranslator.entitlements \
    "${HELPERS_DIR}/TanTranslator"

# The watcher is deliberately the one component outside the sandbox and without
# the hardened runtime: macOS only offers Apple Events consent to apps that are
# neither sandboxed nor hardened when they are signed locally, and consent is
# what lets it read Apple Music at all.
/usr/bin/codesign --force --sign - "${WATCH_DIR}"

/usr/bin/codesign --force --sign - --options runtime \
    --entitlements Config/NokoCord.entitlements \
    "${APP_DIR}"

echo "==> [6/6] Verifying release integrity..."
python3 scripts/verify-release.py "${APP_DIR}" --edition "${EDITION_ID}" --metadata "${METADATA_CONFIG}"

echo ""
echo "🎉 Build succeeded! App bundle created at: ${APP_DIR}"
echo ""

if [ "${1:-}" = "--run" ] || [ "${1:-}" = "run" ]; then
    echo "==> Launching NokoCord Chiaki..."
    open "${APP_DIR}"
fi
