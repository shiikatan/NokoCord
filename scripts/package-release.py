#!/usr/bin/env python3
"""Package an already signed Maomao app; verify both copies and final checksums."""
import argparse
import hashlib
import pathlib
import subprocess
import tempfile


def run(*args):
    subprocess.run(args, check=True)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def manifest(root):
    result = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[relative] = ("link", path.readlink().as_posix())
        elif path.is_file():
            result[relative] = ("file", path.stat().st_mode & 0o777, digest(path))
        else:
            result[relative] = ("directory",)
    return result


def verify(app):
    run("python3", str(pathlib.Path(__file__).with_name("verify-release.py")),
        str(app), "--edition", "maomao", "--ad-hoc-release")


def package(app, output):
    verify(app)
    original = manifest(app)
    output.mkdir(parents=True, exist_ok=True)
    names = ["NokoCord-Maomao-M1.5.0.zip", "NokoCord-Maomao-M1.5.0.dmg", "SHA256SUMS"]
    if any((output / name).exists() for name in names):
        raise ValueError("Release output already exists; choose a fresh directory")
    archive, image, checksums = [output / name for name in names]
    with tempfile.TemporaryDirectory(prefix="NokoCord-package-") as temporary:
        work = pathlib.Path(temporary)
        run("ditto", "--norsrc", "--noextattr", "-c", "-k", "--keepParent", str(app), str(archive))
        extracted = work / "extracted"
        extracted.mkdir()
        run("ditto", "-x", "-k", str(archive), str(extracted))
        if {p.name for p in extracted.iterdir()} != {"NokoCord.app"}:
            raise ValueError("ZIP contains unexpected top-level files")
        verify(extracted / "NokoCord.app")
        if manifest(extracted / "NokoCord.app") != original:
            raise ValueError("ZIP application differs from signed input")
        staging = work / "staging"
        staging.mkdir()
        run("ditto", "--norsrc", "--noextattr", str(app), str(staging / "NokoCord.app"))
        (staging / "Applications").symlink_to("/Applications")
        run("hdiutil", "create", "-srcfolder", str(staging), "-volname", "NokoCord Maomao M1.5.0",
            "-fs", "APFS", "-format", "UDZO", str(image))
        run("hdiutil", "verify", str(image))
        mount = work / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image))
        try:
            # Allow only the filesystem's known housekeeping directories.
            contents = {p.name for p in mount.iterdir()}
            housekeeping = {".fseventsd", ".Trashes", ".Spotlight-V100"}
            if contents - housekeeping != {"NokoCord.app", "Applications"}:
                raise ValueError("DMG contains unexpected files")
            if not (mount / "Applications").is_symlink() or (mount / "Applications").readlink() != pathlib.Path("/Applications"):
                raise ValueError("DMG Applications link is invalid")
            verify(mount / "NokoCord.app")
            if manifest(mount / "NokoCord.app") != original:
                raise ValueError("DMG application differs from signed input")
        finally:
            run("hdiutil", "detach", str(mount))
    if manifest(app) != original:
        raise ValueError("Signed input application changed during packaging")
    checksums.write_text("".join(f"{digest(path)}  {path.name}\n" for path in (archive, image)))
    subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=output, check=True)
    for path in (archive, image):
        print(f"{path.name}: {path.stat().st_size} bytes; SHA-256 {digest(path)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    package(args.app.resolve(strict=True), args.output.resolve())
