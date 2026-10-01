#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/nokocord-account-tests.XXXXXX")
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM
mkdir "$scratch_dir/home" "$scratch_dir/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch_dir/module-cache" -parse-as-library \
    -o "$scratch_dir/DiscordAccountServiceHarness" \
    NokoCord/Native/DiscordSocialAccountService.swift \
    Tests/Native/DiscordAccountServiceHarness.swift
# Isolate the production logout marker. The harness uses in-memory fake
# credentials and SDK callbacks, and crosses the 60-second cancel deadline.
CFFIXED_USER_HOME="$scratch_dir/home" "$scratch_dir/DiscordAccountServiceHarness"
