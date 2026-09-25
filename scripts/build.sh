#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Detect Command Line Tools macOS SDK
# On macOS 27 beta Command Line Tools, libSwiftUIMacros is not bundled;
# using MacOSX26.sdk uses native SwiftUI property wrappers seamlessly.
if [ -z "${SDKROOT:-}" ]; then
    if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
    elif [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    else
        export SDKROOT="$(xcrun --show-sdk-path 2>/dev/null || echo '')"
    fi
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
swiftc Tools/TanTranslator/Helper/main.swift -O -o "${HELPERS_DIR}/TanTranslator"

echo "==> [2/6] Compiling NokoCord native binary with swiftc..."
CPU_CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
SWIFT_FILES=$(find NokoCord -name "*.swift")
swiftc -parse-as-library -j"${CPU_CORES}" ${SWIFT_FILES} -O -o "${MACOS_DIR}/NokoCord"

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

echo "==> [4/6] Generating Info.plist..."
cat << 'PLIST_EOF' > "${CONTENTS_DIR}/Info.plist"
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
	<string>com.shiikatan.nokocord.chiaki</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NokoEditionID</key>
	<string>chiaki</string>
	<key>NokoEditionName</key>
	<string>Chiaki</string>
	<key>NokoPublicVersion</key>
	<string>C1.0.0</string>
	<key>NokoMaintainer</key>
	<string>Millx</string>
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

/usr/bin/codesign --force --sign - --options runtime \
    --entitlements Config/NokoCord.entitlements \
    "${APP_DIR}"

echo "==> [6/6] Verifying release integrity..."
python3 scripts/verify-release.py "${APP_DIR}" --edition chiaki

echo ""
echo "🎉 Build succeeded! App bundle created at: ${APP_DIR}"
echo ""

if [ "${1:-}" = "--run" ] || [ "${1:-}" = "run" ]; then
    echo "==> Launching NokoCord Chiaki..."
    open "${APP_DIR}"
fi
