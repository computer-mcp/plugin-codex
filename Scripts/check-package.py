#!/usr/bin/env python3
"""Verify exact archive, inventory and manifest bytes; optionally relocate to a new directory."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import tomllib
import zipfile

from package import input_kind, publish_directory, validate_architectures


def digest(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        result.update(chunk)
    return result.hexdigest()


def safe_path(name):
    if not isinstance(name, str) or not name or "\\" in name or ":" in name or "\0" in name:
        raise ValueError("Archive path must be a canonical relative POSIX path")
    parts = name.split("/")
    if (any(part in {"", ".", ".."} or part.endswith((".", " ")) for part in parts)
            or any(re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", part) for part in parts)):
        raise ValueError("Archive path is unsafe or platform-ambiguous")
    return PurePosixPath(name)


def verify(archive, receipt_path, manifest, destination=None):
    for path in [archive, receipt_path, manifest]:
        if not stat.S_ISREG(input_kind(path)):
            raise ValueError("Archive verification inputs must be regular files")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    inventory = receipt.get("files")
    if not isinstance(inventory, dict) or not inventory:
        raise ValueError("Archive receipt must declare its file inventory")
    for name, value in inventory.items():
        safe_path(name)
        if receipt.get("platform") == "windows":
            from windows_runtime import is_msvc_runtime
            if is_msvc_runtime(PurePosixPath(name).name):
                raise ValueError("Microsoft runtime DLLs must be installed separately, not bundled")
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise ValueError("Archive inventory requires exact SHA-256 digests")
    expected_name = validate_architectures(manifest, receipt["architectures"], receipt["platform"])
    declaration = tomllib.loads(manifest.read_text(encoding="utf-8"))
    if receipt.get("plugin_id") != declaration["id"] or archive.name != expected_name or receipt["archive"] != archive.name:
        raise ValueError("Archive identity does not match its platform declaration")
    with archive.open("rb") as stream:
        archive_digest = digest(stream)
    if archive.stat().st_size != receipt["archive_bytes"] or archive_digest != receipt["archive_sha256"]:
        raise ValueError("Archive differs from its accepted receipt")
    stage = None
    with zipfile.ZipFile(archive) as zipped:
        files = {}
        seen = set()
        directories = set()
        for entry in zipped.infolist():
            name = entry.filename[:-1] if entry.is_dir() else entry.filename
            safe_path(name)
            if entry.orig_filename != entry.filename or name.casefold() in seen or entry.flag_bits & 1:
                raise ValueError("Archive contains duplicate, aliased or encrypted entries")
            seen.add(name.casefold())
            mode = entry.external_attr >> 16
            expected_mode = stat.S_IFDIR if entry.is_dir() else stat.S_IFREG
            if stat.S_IFMT(mode) not in {0, expected_mode} or mode & 0o7000:
                raise ValueError("Archive contains links, special files or privileged modes")
            if entry.is_dir():
                if entry.file_size != 0:
                    raise ValueError("Archive directory has unexpected data")
                directories.add(name)
            else:
                files[name] = entry
        if set(files) != set(inventory):
            raise ValueError("Archive file inventory differs from the accepted receipt")
        parents = set()
        canonical = {}
        for name in files:
            for path in [PurePosixPath(name), *PurePosixPath(name).parents]:
                if path == PurePosixPath("."):
                    continue
                value = path.as_posix()
                previous = canonical.setdefault(value.casefold(), value)
                if previous != value:
                    raise ValueError("Archive contains case-aliased parent paths")
            parents.update(parent.as_posix() for parent in PurePosixPath(name).parents if parent != PurePosixPath("."))
        if not directories <= parents or parents & set(files):
            raise ValueError("Archive contains undeclared directories or file/directory collisions")
        for name, entry in files.items():
            with zipped.open(entry) as stream:
                if digest(stream) != inventory[name]:
                    raise ValueError(f"Archive file digest differs: {name}")
        if zipped.read("computer-mcp-plugin.toml") != manifest.read_bytes():
            raise ValueError("Archive manifest must match the repository declaration byte for byte")
        try:
            if destination is not None:
                if os.path.lexists(destination):
                    raise ValueError("Relocation destination already exists")
                destination.parent.mkdir(parents=True, exist_ok=True)
                stage = Path(tempfile.mkdtemp(prefix="codex-relocation-", dir=destination.parent))
                for name, entry in files.items():
                    output = stage.joinpath(*PurePosixPath(name).parts)
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with zipped.open(entry) as source, output.open("xb") as target:
                        shutil.copyfileobj(source, target, length=1024 * 1024)
                    if os.name != "nt":
                        output.chmod((entry.external_attr >> 16) & 0o777 or 0o644)
                publish_directory(stage, destination)
                stage = None
        finally:
            if stage is not None:
                shutil.rmtree(stage)
    return {"archive": archive.name, "archive_sha256": archive_digest,
            "platform": receipt["platform"], "architectures": receipt["architectures"],
            "plugin_id": declaration["id"], "version": declaration["version"],
            "files_verified": len(files), "manifest_byte_identical": True,
            "relocated_to": str(destination) if destination is not None else None}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[1] / "computer-mcp-plugin.toml")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.archive, args.receipt, args.manifest, args.destination), indent=2))
