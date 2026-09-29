#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/discord_social_sdk" >&2
    exit 64
fi

sdk_root=$1
source_framework="$sdk_root/lib/release/discord_partner_sdk.framework"
source_notices="$sdk_root/License-Notices.txt"
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vendor_parent="$repo_root/Vendor"
vendor_dir="$vendor_parent/DiscordSocialSDK-1.10.19337"

if [ ! -d "$source_framework" ]; then
    echo "Discord Social SDK 1.10.19337 framework not found at: $source_framework" >&2
    exit 66
fi

mkdir -p "$vendor_parent"
staging_dir=$(mktemp -d "$vendor_parent/.discord-social-sdk.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM

ditto "$source_framework" "$staging_dir/discord_partner_sdk.framework"
lipo -verify_arch arm64 "$staging_dir/discord_partner_sdk.framework/discord_partner_sdk"
lipo -verify_arch x86_64 "$staging_dir/discord_partner_sdk.framework/discord_partner_sdk"

# NokoCord currently uses ad hoc signing. Re-sign both nested code and the
# enclosing framework together so Xcode's framework copy remains verifiable.
codesign --force --sign - "$staging_dir/discord_partner_sdk.framework/Versions/A/Frameworks/libdiscord_krisp.dylib"
codesign --force --sign - "$staging_dir/discord_partner_sdk.framework"
codesign --verify --deep --strict "$staging_dir/discord_partner_sdk.framework"

if [ -f "$source_notices" ]; then
    cp "$source_notices" "$staging_dir/License-Notices.txt"
fi

rm -rf "$vendor_dir"
mv "$staging_dir" "$vendor_dir"
trap - EXIT HUP INT TERM

echo "Installed Discord Social SDK 1.10.19337 at $vendor_dir"
