#!/usr/bin/env python3
"""Read and validate the canonical NokoCord edition build metadata."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from dataclasses import asdict, dataclass


ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = ROOT / "Config" / "Edition.xcconfig"

_REQUIRED_KEYS = {
    "NOKO_BUNDLE_ID": "bundle_id",
    "NOKO_APPLE_VERSION": "apple_version",
    "NOKO_BUILD_NUMBER": "build_number",
    "NOKO_EDITION_ID": "edition",
    "NOKO_EDITION_NAME": "edition_name",
    "NOKO_PUBLIC_VERSION": "public_version",
    "NOKO_MAINTAINER": "maintainer",
    "NOKO_DEPLOYMENT_TARGET": "deployment_target",
}
_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*$")
_EDITION = re.compile(r"^[a-z][a-z0-9-]*$")
_DEPLOYMENT_TARGET = re.compile(r"^\d+\.\d+$")


@dataclass(frozen=True)
class ReleaseMetadata:
    bundle_id: str
    apple_version: str
    build_number: str
    edition: str
    edition_name: str
    public_version: str
    maintainer: str
    deployment_target: str

    def as_dict(self) -> dict[str, str]:
        return asdict(self)

    @property
    def artifact_stem(self) -> str:
        return f"NokoCord-{self.edition_name}-{self.public_version}"


def _strip_value(value: str) -> str:
    value = value.split("//", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _read_xcconfig(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise ValueError(f"{path}:{line_number}: expected KEY = VALUE")
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"{path}:{line_number}: metadata key is empty")
        if key in values:
            raise ValueError(f"{path}:{line_number}: duplicate metadata key {key}")
        values[key] = _strip_value(value)
    return values


def _require(values: dict[str, str], key: str, path: pathlib.Path) -> str:
    value = values.get(key)
    if value is None or not value:
        raise ValueError(f"{path}: missing {key}")
    return value


def load_metadata(config_path: pathlib.Path | str = DEFAULT_CONFIG) -> ReleaseMetadata:
    """Load and validate one edition's metadata from an xcconfig file."""

    path = pathlib.Path(config_path).expanduser().resolve(strict=True)
    values = _read_xcconfig(path)
    mapped = {
        field: _require(values, key, path)
        for key, field in _REQUIRED_KEYS.items()
    }

    if not _IDENTIFIER.fullmatch(mapped["bundle_id"]) or "." not in mapped["bundle_id"]:
        raise ValueError(f"{path}: invalid NOKO_BUNDLE_ID")
    if not _VERSION.fullmatch(mapped["apple_version"]):
        raise ValueError(f"{path}: invalid NOKO_APPLE_VERSION")
    if not mapped["build_number"].isdigit() or int(mapped["build_number"]) < 1:
        raise ValueError(f"{path}: invalid NOKO_BUILD_NUMBER")
    if not _EDITION.fullmatch(mapped["edition"]):
        raise ValueError(f"{path}: invalid NOKO_EDITION_ID")
    if not _VERSION.fullmatch(mapped["public_version"][1:]) or not mapped["public_version"][0].isalpha():
        raise ValueError(f"{path}: invalid NOKO_PUBLIC_VERSION")
    if mapped["public_version"][0].lower() != mapped["edition"][0]:
        raise ValueError(f"{path}: public version prefix does not match edition")
    if not _DEPLOYMENT_TARGET.fullmatch(mapped["deployment_target"]):
        raise ValueError(f"{path}: invalid NOKO_DEPLOYMENT_TARGET")

    return ReleaseMetadata(**mapped)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=pathlib.Path, default=DEFAULT_CONFIG)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="print all fields as JSON")
    output.add_argument("--field", choices=sorted(ReleaseMetadata.__dataclass_fields__), help="print one field")
    args = parser.parse_args(argv)
    try:
        metadata = load_metadata(args.config)
    except (OSError, ValueError) as error:
        print(f"release metadata error: {error}", file=sys.stderr)
        return 1

    if args.field:
        print(metadata.as_dict()[args.field])
    else:
        print(json.dumps(metadata.as_dict(), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
