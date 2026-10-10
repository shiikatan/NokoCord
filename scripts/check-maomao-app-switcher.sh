#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/maomao-switcher.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc Tests/MaomaoAppSwitchingChecks.swift -o "$work/checks"
"$work/checks" NokoCord/Resources/MaomaoAppSwitching.js
