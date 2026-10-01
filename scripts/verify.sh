#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test --scratch-path /private/tmp/NokoCord-tests
sh scripts/verify-native-callbacks.sh
sh scripts/verify-native-account.sh
# Ad hoc signatures have no Team ID for hardened-runtime library validation.
# These local source checks override runtime only for the generated test app;
# production project settings retain hardened runtime for developer signing.
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-maomao-build CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-maomao-build CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO build
python3 scripts/verify-release.py /private/tmp/NokoCord-maomao-build/Build/Products/Release/NokoCord.app --edition maomao --allow-unconfigured --allow-ad-hoc
git diff --check
