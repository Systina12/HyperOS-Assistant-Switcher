#!/usr/bin/env python3
"""Build a deterministic, manager-installable module ZIP using only stdlib."""

from __future__ import annotations

import argparse
import hashlib
import re
import stat
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
MODULE_FILES = (
    "module.prop",
    "skip_mount",
    "action.sh",
    "control.sh",
    "common.sh",
    "service.sh",
    "customize.sh",
    "uninstall.sh",
    "restore.sh",
)
DOCUMENTS = ("README.md", "LICENSE", "docs/TESTING.md", "docs/ARCHITECTURE.md")


def build(output: Path) -> Path:
    props = dict(
        line.split("=", 1)
        for line in (ROOT / "module/module.prop").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    )
    if props.get("id") != "hyperos_assistant_switcher":
        raise ValueError("Unexpected module id")
    version = props["version"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?", version):
        raise ValueError("Invalid module version")
    if not props.get("versionCode", "").isdigit():
        raise ValueError("versionCode must be an integer")

    entries = [(ROOT / "module" / name, name) for name in MODULE_FILES]
    entries += [(ROOT / name, name) for name in DOCUMENTS]
    payloads = []
    for source, name in entries:
        if source.is_symlink():
            raise ValueError(f"Symlinks are not allowed: {source}")
        data = source.read_bytes().replace(b"\r\n", b"\n")
        if data.startswith(b"\xef\xbb\xbf") or b"\r" in data:
            raise ValueError(f"BOM or non-LF line ending in {source}")
        if name.endswith(".sh") and not data.startswith(b"#!/system/bin/sh\n"):
            raise ValueError(f"Invalid Android shell script header: {source}")
        payloads.append((name, data))

    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"HyperOS-Assistant-Switcher-{version}.zip"
    with ZipFile(archive, "w", compression=ZIP_DEFLATED, compresslevel=9) as bundle:
        for name, data in sorted(payloads):
            entry = ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.compress_type = ZIP_DEFLATED
            mode = 0o755 if name.endswith(".sh") else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            bundle.writestr(entry, data, compress_type=ZIP_DEFLATED, compresslevel=9)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(
        f"{digest}  {archive.name}\n", encoding="ascii", newline="\n"
    )
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    archive = build(parser.parse_args().output.resolve())
    print(archive)
    print(archive.with_suffix(".zip.sha256").read_text(encoding="ascii").strip())


if __name__ == "__main__":
    main()
