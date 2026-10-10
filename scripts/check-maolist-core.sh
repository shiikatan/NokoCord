#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/maolist-checks.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library NokoCord/MaoList/MaoListModels.swift NokoCord/MaoList/MaoListAuthorization.swift NokoCord/MaoList/MaoListColor.swift NokoCord/MaoList/MaoListPreferences.swift NokoCord/MaoList/MaoListClient.swift NokoCord/MaoList/MaoListRepository.swift Tests/MaoListCoreChecks.swift -o "$work/checks"
"$work/checks"
