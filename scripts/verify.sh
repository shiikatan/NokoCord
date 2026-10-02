#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test --scratch-path /private/tmp/NokoCord-tests
sh scripts/verify-native-callbacks.sh
sh scripts/verify-native-account.sh
# Source verification uses ad hoc signatures without weakening hardened runtime.
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-maomao-build CODE_SIGN_IDENTITY=- build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-maomao-build CODE_SIGN_IDENTITY=- build
python3 scripts/verify-release.py /private/tmp/NokoCord-maomao-build/Build/Products/Release/NokoCord.app --edition maomao --allow-unconfigured --allow-ad-hoc
git diff --check
