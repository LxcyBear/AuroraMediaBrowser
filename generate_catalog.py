#!/usr/bin/env python3
"""Build Aurora Skin Browser catalog.txt from XZP and ZIP packages.

Skins may live at repo root or in skins/. ZIPs may contain layout files.
Generated columns match Aurora Skin Browser v2.1 Main.lua exactly.
"""
from pathlib import Path, PurePosixPath
import hashlib
import re
import zipfile

ROOT = Path(__file__).resolve().parent
SAFE_NAME = re.compile(r"^[A-Za-z0-9 _().+\-]+\.(?:xzp|zip|cfljson)$", re.I)
SAFE_PART = re.compile(r"^[A-Za-z0-9 _().+\-]+$")
MAX_PACKAGE = 350 * 1024 * 1024
MAX_UNPACKED = 550 * 1024 * 1024


def safe_name(s):
    return (
        bool(SAFE_NAME.fullmatch(s)) and 5 <= len(s) <= 110
        and not s.startswith(".") and not s.endswith(" ")
        and ".." not in s and "|" not in s and ";" not in s
    )


def safe_member(path):
    if not path or len(path) > 260 or path.startswith("/") or "\\" in path or ":" in path:
        return False
    if ".." in path:
        return False
    parts = path.rstrip("/").split("/")
    return 0 < len(parts) <= 16 and all(
        p and p not in (".", "..") and not p.endswith((".", " "))
        and SAFE_PART.fullmatch(p) for p in parts
    )


def sha1(path):
    digest = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def examine_zip(path):
    skins, layouts, unpacked = [], [], 0
    with zipfile.ZipFile(path) as archive:
        items = archive.infolist()
        if len(items) > 2000:
            raise ValueError("too many ZIP entries")
        for item in items:
            if not safe_member(item.filename):
                raise ValueError("unsafe ZIP path: " + item.filename)
            if (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("ZIP contains a symlink")
            if item.flag_bits & 1:
                raise ValueError("encrypted ZIP not supported")
            unpacked += item.file_size
            if unpacked > MAX_UNPACKED:
                raise ValueError("ZIP too large after extraction")
            if item.is_dir():
                continue
            basename = PurePosixPath(item.filename).name
            ext = PurePosixPath(item.filename).suffix.lower()
            if ext in (".xzp", ".cfljson") and not safe_name(basename):
                raise ValueError("unsafe internal filename: " + basename)
            if ext == ".xzp":
                skins.append(item.filename)
            elif ext == ".cfljson":
                layouts.append(item.filename)
        if len(skins) != 1:
            raise ValueError("ZIP must contain exactly one .xzp; found " + str(len(skins)))
        if len(layouts) > 32:
            raise ValueError("too many layouts")
        names = [PurePosixPath(x).name.lower() for x in layouts]
        if len(names) != len(set(names)):
            raise ValueError("duplicate layout filenames")
        invalid = archive.testzip()
        if invalid:
            raise ValueError("bad CRC for " + invalid)
    return PurePosixPath(skins[0]).name, skins[0], ";".join(layouts) or "-"


def main():
    lines = [
        "# Aurora Skin Browser v2 - automatically generated. Do not edit.",
        "# package-path|package-bytes|sha1|installed-xzp-name|zip-xzp-member|zip-layout-members",
    ]
    files = []
    for folder in (ROOT, ROOT / "skins"):
        if folder.is_dir():
            files.extend(p for p in folder.iterdir()
                         if p.is_file() and p.suffix.lower() in (".xzp", ".zip"))
    owners = {}
    for file in sorted(files, key=lambda x: str(x.relative_to(ROOT)).lower()):
        path = file.relative_to(ROOT).as_posix()
        try:
            if not safe_name(file.name):
                raise ValueError("unsafe package filename")
            size = file.stat().st_size
            if not 0 < size <= MAX_PACKAGE:
                raise ValueError("invalid package size")
            if file.suffix.lower() == ".zip":
                skin, member, layouts = examine_zip(file)
            else:
                skin, member, layouts = file.name, "-", "-"
            if skin.lower() in owners:
                raise ValueError("skin filename conflicts with " + owners[skin.lower()])
            owners[skin.lower()] = path
            lines.append("|".join([path, str(size), sha1(file), skin, member, layouts]))
            print("OK  ", path, "->", skin)
        except (ValueError, OSError, zipfile.BadZipFile) as exc:
            print("SKIP", path, ":", exc)
    (ROOT / "catalog.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Generated", len(lines) - 2, "catalog entries.")


if __name__ == "__main__":
    main()
