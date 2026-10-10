#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/nokocord-toolbar.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library NokoCord/Views/WorkspaceWindowToolbarVisibility.swift Tests/WorkspaceToolbarChecks.swift -o "$work/checks"
"$work/checks"
