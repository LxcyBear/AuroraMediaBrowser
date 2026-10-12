#!/usr/bin/env python3
"""Build Aurora-compatible 7z archives for ZIP skin bundles.

Keeps ZIPs in repo/Skins/ and places converted archives in repo/.bundles/.
Aurora's older native Lua ZipFile binding is designed for 7z, not ZIP.
"""
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
ZIP_FOLDER = ROOT / "repo" / "Skins"
BUNDLE_FOLDER = ROOT / "repo" / ".bundles"
SAFE = re.compile(r"^[A-Za-z0-9 _().+\-]+$")
MAX_PACKAGE = 350 * 1024 * 1024


def legal_filename(name):
    return (5 <= len(name) <= 110 and bool(SAFE.fullmatch(name))
            and ".." not in name and not name.startswith(".")
            and not name.endswith((" ", ".")))


def compile_bundle(archive, bundle):
    with tempfile.TemporaryDirectory(prefix="aurora_bundle_") as dirname:
        staging = Path(dirname)
        extracted, skins, layouts = [], [], []
        total_size = 0
        seen = set()
        with zipfile.ZipFile(archive) as src:
            entries = src.infolist()
            if len(entries) > 2000:
                raise ValueError("too many ZIP entries")
            for info in entries:
                if info.is_dir():
                    continue
                internal = info.filename
                if (not internal or internal.startswith("/") or "\\" in internal
                    or ":" in internal or ".." in internal
                    or len(internal) > 260 or len(internal.split("/")) > 16
                    or not all(part and part != "." and SAFE.fullmatch(part)
                               for part in internal.split("/"))):
                    raise ValueError(f"unsafe ZIP path: {internal!r}")
                unix_type = (info.external_attr >> 16) & 0o170000
                if unix_type not in (0, 0o100000):
                    raise ValueError("symlinks/special files not supported")
                ext = PurePosixPath(internal).suffix.lower()
                if ext not in (".xzp", ".cfljson"):
                    continue
                name = PurePosixPath(internal).name
                if not legal_filename(name) or name.lower() in seen:
                    raise ValueError(f"unsafe/duplicate member: {name!r}")
                seen.add(name.lower())
                if info.flag_bits & 1:
                    raise ValueError("encrypted ZIP not supported")
                if info.file_size <= 0:
                    raise ValueError(f"empty member: {name!r}")
                total_size += info.file_size
                if total_size > MAX_PACKAGE:
                    raise ValueError("bundle exceeds 350 MiB unpacked")
                (skins if ext == ".xzp" else layouts).append(name)
                with src.open(info) as reader, (staging / name).open("wb") as writer:
                    shutil.copyfileobj(reader, writer, length=1024 * 1024)
                extracted.append(name)
        if len(skins) != 1 or len(layouts) > 32:
            raise ValueError(f"ZIP requires one skin and <=32 layouts; got {len(skins)} skins, {len(layouts)} layouts")
        result = subprocess.run([
            "7z", "a", "-t7z", "-mx=1", "-m0=lzma", "-y",
            str(bundle.resolve()), *extracted
        ], cwd=staging, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"7z failed: {result.stdout} {result.stderr}")
        if not bundle.is_file() or not 100 <= bundle.stat().st_size <= MAX_PACKAGE:
            raise RuntimeError("invalid 7z output")
        print(f"OK {archive.name} -> {bundle.name}: {skins[0]}, {len(layouts)} layouts")


def main():
    if not ZIP_FOLDER.is_dir():
        raise RuntimeError("Missing repo/Skins")
    BUNDLE_FOLDER.mkdir(parents=True, exist_ok=True)
    archives = sorted((p for p in ZIP_FOLDER.iterdir()
                      if p.is_file() and p.suffix.lower() == ".zip"),
                      key=lambda p: p.name.lower())
    if len({p.name.lower() for p in archives}) != len(archives):
        raise RuntimeError("case-insensitive ZIP name collision")
    desired = {p.name + ".7z" for p in archives}
    for archive in archives:
        compile_bundle(archive, BUNDLE_FOLDER / (archive.name + ".7z"))
    for obsolete in BUNDLE_FOLDER.glob("*.7z"):
        if obsolete.name not in desired:
            obsolete.unlink()
    print(f"Prepared {len(archives)} compatibility bundle(s)")


if __name__ == "__main__":
    main()
