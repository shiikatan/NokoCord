#!/usr/bin/env python3
"""Create signed native-icon variants and their small bidirectional switch data.

Run after the normal Release build with all app icon assets included. The app
is never modified in place; all products are written to a new output folder.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import struct
import subprocess
import tempfile

ALLOWED_CHANGES = {
    "Contents/Info.plist", "Contents/MacOS/NokoCord",
    "Contents/_CodeSignature/CodeResources",
}

def run(*args):
    subprocess.run([str(x) for x in args], check=True, stdout=subprocess.DEVNULL)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def manifest(root):
    result = {}
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode & 0o777
        if path.is_symlink():
            result[name] = {"kind": "symlink", "mode": mode, "link": os.readlink(path)}
        elif path.is_dir():
            result[name] = {"kind": "directory", "mode": mode}
        elif path.is_file():
            data = path.read_bytes()
            result[name] = {"kind": "file", "mode": mode, "size": len(data), "sha256": digest(data)}
        else:
            raise ValueError("Unsupported file in application")
    return result

def unsigned_executable_digest(data):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Icon switching requires the official 64-bit Apple Silicon build")
    commands, command_bytes = struct.unpack_from("<II", data, 16)
    if commands > 1024 or 32 + command_bytes > len(data):
        raise ValueError("Invalid Mach-O commands")
    normalized = bytearray(data)
    cursor = 32
    signature = None
    for _ in range(commands):
        if cursor + 8 > 32 + command_bytes:
            raise ValueError("Invalid Mach-O command bounds")
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > 32 + command_bytes:
            raise ValueError("Invalid Mach-O command size")
        if command == 0x1D:
            if signature or size != 16:
                raise ValueError("Invalid code signature command")
            signature = struct.unpack_from("<II", data, cursor + 8)
            normalized[cursor + 8:cursor + 16] = bytes(8)
        elif command == 0x19 and size >= 72 and data[cursor + 8:cursor + 24].split(b"\0")[0] == b"__LINKEDIT":
            # Signing can resize LINKEDIT, without changing executable code.
            normalized[cursor + 32:cursor + 40] = bytes(8)
            normalized[cursor + 48:cursor + 56] = bytes(8)
        cursor += size
    if not signature or signature[0] < 32 + command_bytes or sum(signature) != len(data):
        raise ValueError("Expected bounded signature at end of executable")
    return digest(normalized[:signature[0]])

def chunks(source, target):
    result = []
    cursor, limit = 0, min(len(source), len(target))
    while cursor < limit:
        if source[cursor] == target[cursor]:
            cursor += 1
            continue
        start = cursor
        last_difference = cursor
        cursor += 1
        while cursor < limit:
            if source[cursor] != target[cursor]:
                last_difference = cursor
            elif cursor - last_difference >= 32:
                break
            cursor += 1
        end = last_difference + 1
        result.append({"offset": start, "bytes": base64.b64encode(target[start:end]).decode("ascii")})
    if len(target) > limit:
        result.append({"offset": limit, "bytes": base64.b64encode(target[limit:]).decode("ascii")})
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, help="New, nonexistent output folder")
    parser.add_argument("--identity", default="-", help="Same signing identity used for the app")
    args = parser.parse_args()
    source = args.application.resolve(strict=True)
    output = args.output.absolute()
    if output.exists():
        raise ValueError("Output folder must not exist")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", source)
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.shiikatan.nokocord.maomao" or info.get("CFBundleIconName") != "MaomaoAppIcon" or info.get("NSDockTilePlugIn"):
        raise ValueError("Expected unmodified native NokoCord release")
    output.mkdir(parents=True, mode=0o700)
    noko, mao = output / "NokoCord-Noko.app", output / "NokoCord-MaoList.app"
    run("/bin/cp", "-cR", source, noko)
    # Asset catalogs compile both icon graphs, but emit only the primary ICNS.
    with tempfile.TemporaryDirectory(prefix="noko-icon-fallback-") as temporary:
        temp = pathlib.Path(temporary)
        root = pathlib.Path(__file__).resolve().parent.parent
        run("/usr/bin/xcrun", "actool", root / "NokoCord/MaoListAppIcon.icon",
            "--compile", temp, "--platform", "macosx", "--minimum-deployment-target", "26.6",
            "--app-icon", "MaoListAppIcon", "--output-partial-info-plist", temp / "info.plist")
        run("/bin/cp", temp / "MaoListAppIcon.icns", noko / "Contents/Resources/MaoListAppIcon.icns")
    run("/usr/bin/codesign", "--force", "--sign", args.identity, "--options", "runtime",
        "--preserve-metadata=identifier,entitlements,flags", noko)
    run("/bin/cp", "-cR", noko, mao)
    mao_info = dict(info)
    mao_info["CFBundleIconName"] = "MaoListAppIcon"
    mao_info["CFBundleIconFile"] = "MaoListAppIcon"
    (mao / "Contents/Info.plist").write_bytes(plistlib.dumps(mao_info, sort_keys=False))
    run("/usr/bin/codesign", "--force", "--sign", args.identity, "--options", "runtime",
        "--preserve-metadata=identifier,entitlements,flags", mao)
    for app in (noko, mao):
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    first, second = manifest(noko), manifest(mao)
    if first.keys() != second.keys():
        raise ValueError("Variants must share all application paths")
    changed = [name for name in first if first[name] != second[name]]
    if not set(changed).issubset(ALLOWED_CHANGES):
        raise ValueError("Non-icon application files differ: " + repr(changed))
    executable = "Contents/MacOS/NokoCord"
    code_digest = unsigned_executable_digest((noko / executable).read_bytes())
    if code_digest != unsigned_executable_digest((mao / executable).read_bytes()):
        raise ValueError("Executable code changed between icon variants")
    changes = []
    for name in changed:
        left, right = (noko / name).read_bytes(), (mao / name).read_bytes()
        changes.append({"path": name, "toMaoList": chunks(left, right), "toNokoCord": chunks(right, left)})
    package = {"schemaVersion": 1, "bundleIdentifier": info["CFBundleIdentifier"],
               "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
               "unsignedExecutableSHA256": code_digest,
               "variants": {"nokocord": first, "maolist": second}, "changes": changes}
    data = json.dumps(package, separators=(",", ":"), sort_keys=True).encode()
    if len(data) > 16 * 1024 * 1024:
        raise ValueError("Icon switch package exceeds bounded cache size")
    name = "NokoCord-Maomao-M" + package["version"] + "-Icons.nokoicons"
    (output / name).write_bytes(data)
    (output / "SHA256SUMS").write_text(digest(data) + "  " + name + "\n")
    report = {"packageBytes": len(data), "changedPaths": changed,
              "sameUnsignedExecutable": True, "sameSharedResources": True,
              "signatureVerifiedBoth": True,
              "patchPayloadBytes": sum(len(base64.b64decode(c["bytes"])) for d in changes for key in ("toMaoList", "toNokoCord") for c in d[key])}
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
