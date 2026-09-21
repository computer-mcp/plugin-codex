#!/usr/bin/env python3
"""Build a local, relocatable plugin archive without installing or publishing it."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import tomllib
import zipfile


def command(arguments, cwd):
    result = subprocess.run(arguments, cwd=cwd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def copy_file(source, destination):
    if not stat.S_ISREG(source.lstat().st_mode):
        raise ValueError(f"Package input must be a regular file: {source}")
    shutil.copy2(source, destination, follow_symlinks=False)


def copy_tree(source, destination):
    if not stat.S_ISDIR(source.lstat().st_mode):
        raise ValueError(f"Package input must be a directory: {source}")
    # Preserve links for rejection, never copy the files they point at.
    shutil.copytree(source, destination, symlinks=True)


def validate_payload(root):
    for entry in root.rglob("*"):
        mode = entry.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError(f"Package contains a link or special file: {entry.relative_to(root)}")


def validate_architectures(manifest, architectures):
    declaration = tomllib.loads(manifest.read_text(encoding="utf-8"))
    compatibility = declaration.get("compatibility", {})
    declared = compatibility.get("architectures") if isinstance(compatibility, dict) else None
    if (not isinstance(declared, list) or not declared
            or not all(isinstance(value, str) and value for value in declared)
            or len(set(declared)) != len(declared)
            or set(declared) != set(architectures)):
        raise ValueError("Manifest compatibility.architectures must exactly match the built adapter slices")


def publish_directory(source, destination):
    # Darwin RENAME_EXCL atomically refuses an existing destination, including an empty directory.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def package(output, configuration):
    repo = Path(__file__).resolve().parent.parent
    if output.exists():
        raise ValueError("Output already exists; select a new directory to preserve existing artifacts")
    output.parent.mkdir(parents=True, exist_ok=True)
    command(["/usr/bin/swift", "build", "-c", configuration, "--disable-automatic-resolution"], repo)
    built = Path(command(["/usr/bin/swift", "build", "-c", configuration, "--show-bin-path"], repo))
    executable = built / "codex-mcp-adapter"
    bundle = built / "codex-plugin_CodexAdapter.bundle"
    if not executable.is_file() or not bundle.is_dir():
        raise ValueError("The executable and its SwiftPM resource bundle must both be built")
    stage = Path(tempfile.mkdtemp(prefix="codex-package-", dir=output.parent))
    try:
        payload = stage / "package"
        binary_directory = payload / "bin"
        binary_directory.mkdir(parents=True)
        copy_file(executable, binary_directory / executable.name)
        copy_tree(bundle, binary_directory / bundle.name)
        for name in ["computer-mcp-plugin.toml", "README.md", "CONTRIBUTING.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "Package.resolved"]:
            copy_file(repo / name, payload / name)
        copy_tree(repo / "Documentation", payload / "Documentation")
        notices = payload / "ThirdPartyNotices"
        notices.mkdir()
        pins = json.loads((repo / "Package.resolved").read_text())["pins"]
        for pin in pins:
            identity = pin["identity"]
            checkout = repo / ".build" / "checkouts" / identity
            # Preserve every dependency's root notices verbatim; never infer a license from its name.
            originals = [entry for entry in checkout.iterdir()
                         if entry.is_file() and entry.name.upper().startswith(("LICENSE", "NOTICE", "COPYING"))]
            if not any(entry.name.upper().startswith(("LICENSE", "COPYING")) for entry in originals):
                raise ValueError(f"Pinned dependency {identity} has no available root license")
            target = notices / identity
            target.mkdir()
            for entry in originals:
                copy_file(entry, target / entry.name)
        schema_notices = notices / "codex-protocol"
        schema_notices.mkdir()
        for name in ["LICENSE", "NOTICE"]:
            copy_file(repo / ".build/checkouts/swift-codex/Vendor/CodexAppServerProtocolSchema" / name,
                      schema_notices / name)
        validate_payload(payload)
        with (payload / "ThirdPartyNotices.txt").open("wb") as aggregate:
            for entry in sorted(notices.rglob("*")):
                if entry.is_file():
                    aggregate.write(("\n--- " + str(entry.relative_to(notices)) + " ---\n\n").encode())
                    aggregate.write(entry.read_bytes())
                    aggregate.write(b"\n")
        binary = binary_directory / executable.name
        command(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)], stage)
        command(["/usr/bin/codesign", "--verify", "--strict", str(binary)], stage)
        architectures = command(["/usr/bin/lipo", "-archs", str(binary)], stage).split()
        manifest = payload / "computer-mcp-plugin.toml"
        validate_architectures(manifest, architectures)
        # Basic relocation check; the separate MCP workflow validates resource lookup and execution.
        command([str(binary), "--help"], stage)
        declared_version = tomllib.loads(manifest.read_text(encoding="utf-8"))["version"]
        if command([str(binary), "--version"], stage) != declared_version:
            raise ValueError("Adapter executable version must match the package manifest")
        if manifest.read_bytes() != (repo / manifest.name).read_bytes():
            raise ValueError("Archive manifest must be byte-identical to the repository declaration")
        inventory = {}
        for entry in sorted(payload.rglob("*")):
            if entry.is_symlink():
                raise ValueError(f"Unexpected symlink in package: {entry.relative_to(payload)}")
            if entry.is_file():
                inventory[str(entry.relative_to(payload))] = hashlib.sha256(entry.read_bytes()).hexdigest()
        archive = stage / "codex-plugin.zip"
        with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as package_zip:
            for entry in sorted(payload.rglob("*")):
                package_zip.write(entry, str(entry.relative_to(payload)))
        receipt = {"plugin_id": "codex", "configuration": configuration, "architectures": architectures,
                   "signature": "ad-hoc", "publisher_verified": False, "published": False,
                   "archive": "codex-plugin.zip", "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                   "archive_bytes": archive.stat().st_size, "files": inventory}
        (stage / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        publish_directory(stage, output)
        return {"directory": str(output), "archive": str(output / archive.name),
                "receipt": str(output / "receipt.json"), "sha256": receipt["archive_sha256"]}
    except Exception:
        shutil.rmtree(stage)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    args = parser.parse_args()
    print(json.dumps(package(args.output.absolute(), args.configuration), indent=2))
