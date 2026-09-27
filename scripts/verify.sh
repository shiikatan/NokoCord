#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test --scratch-path /private/tmp/NokoCord-tests
python3 -m unittest discover -s Broker -v
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-chiaki-build CODE_SIGN_IDENTITY=- build
xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release -destination 'platform=macOS' -derivedDataPath /private/tmp/NokoCord-chiaki-build CODE_SIGN_IDENTITY=- build
# The Xcode target does not build the Apple Music helper, so the release checks
# run against the artifact that is actually published: scripts/build.sh is what
# compiles, assembles and signs the shipping bundle.
sh scripts/build.sh
python3 scripts/verify-release.py build/NokoCord.app --edition chiaki
git diff --check
