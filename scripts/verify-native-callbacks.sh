#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
framework="$repo_root/Vendor/DiscordSocialSDK-1.10.19337/discord_partner_sdk.framework"

if [ ! -d "$framework" ]; then
    echo "Discord Social SDK framework is missing. Install 1.10.19337 first." >&2
    exit 66
fi

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/nokocord-native-callbacks.XXXXXX")
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

clangxx=$(xcrun --find clang++)
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
"$clangxx" \
    -std=c++17 \
    -isysroot "$macos_sdk" \
    -fobjc-arc \
    -fblocks \
    -fsanitize=address \
    -fno-omit-frame-pointer \
    -Wno-nullability-completeness \
    -g \
    -I "$framework/Headers" \
    -F "$(dirname -- "$framework")" \
    "$repo_root/Tests/Native/DiscordCallbackLifetimeTests.mm" \
    -framework Foundation \
    -framework discord_partner_sdk \
    -Wl,-rpath,"$(dirname -- "$framework")" \
    -Wl,-rpath,"$framework/Versions/A/Frameworks" \
    -o "$scratch_dir/DiscordCallbackLifetimeTests"

ASAN_OPTIONS="detect_stack_use_after_return=1:detect_stack_use_after_scope=1:halt_on_error=1" \
    "$scratch_dir/DiscordCallbackLifetimeTests"
