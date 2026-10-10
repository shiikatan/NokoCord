#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/maolist-lifecycle.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library NokoCord/Models/EditionIdentity.swift NokoCord/Models/NokoWorkspaceVisibility.swift NokoCord/MaoList/MaoListModels.swift NokoCord/MaoList/MaoListPageStore.swift NokoCord/MaoList/MaoListAuthorization.swift NokoCord/MaoList/MaoListPreferences.swift NokoCord/MaoList/MaoListClient.swift NokoCord/MaoList/MaoListRepository.swift NokoCord/MaoList/MaoListImages.swift NokoCord/MaoList/MaoListModule.swift Tests/MaoListLifecycleChecks.swift -o "$work/checks"
"$work/checks"
