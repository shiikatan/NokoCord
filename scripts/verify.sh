#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test --scratch-path /private/tmp/NokoCord-tests
python3 -m unittest discover -s Broker -v
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-build CODE_SIGN_IDENTITY=- build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-build CODE_SIGN_IDENTITY=- build
python3 scripts/verify-release.py /private/tmp/NokoCord-build/Build/Products/Release/NokoCord.app
git diff --check
