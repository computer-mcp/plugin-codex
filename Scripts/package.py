#!/usr/bin/env python3
"""Build a local, relocatable plugin archive without installing or publishing it."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import zipfile

from version import check as check_version


def command(arguments, cwd):
    result = subprocess.run(arguments, cwd=cwd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def current_platform():
    if sys.platform == "darwin":
        return "macos"
    if sys.platform == "win32":
        return "windows"
    raise ValueError("Native packaging requires macOS or Windows")


def input_kind(path):
    metadata = path.lstat()
    if getattr(metadata, "st_file_attributes", 0) & 0x400:
        raise ValueError(f"Package input is a reparse point: {path}")
    return metadata.st_mode


def copy_file(source, destination):
    if not stat.S_ISREG(input_kind(source)):
        raise ValueError(f"Package input must be a regular file: {source}")
    shutil.copy2(source, destination, follow_symlinks=False)


def copy_tree(source, destination):
    if not stat.S_ISDIR(input_kind(source)):
        raise ValueError(f"Package input must be a directory: {source}")
    validate_payload(source)
    shutil.copytree(source, destination, symlinks=True)


def validate_payload(root):
    if not stat.S_ISDIR(input_kind(root)):
        raise ValueError("Package root must be a regular directory")
    pending = [root]
    while pending:
        for entry in pending.pop().iterdir():
            mode = input_kind(entry)
            if stat.S_ISDIR(mode):
                pending.append(entry)
            elif not stat.S_ISREG(mode):
                raise ValueError(f"Package contains a link or special file: {entry.relative_to(root)}")


def validate_architectures(manifest, architectures, platform="macos"):
    declaration = tomllib.loads(manifest.read_text(encoding="utf-8"))
    compatibility = declaration.get("compatibility", {})
    declared = compatibility.get("architectures") if isinstance(compatibility, dict) else None
    if (not isinstance(declared, list) or not declared
            or not all(isinstance(value, str) and value for value in declared)
            or len(set(declared)) != len(declared)
            or not set(architectures).issubset(declared)):
        raise ValueError("Manifest compatibility.architectures must cover the built adapter slices")
    platforms = compatibility.get("platforms", ["macos"])
    if (not isinstance(platforms, list) or not all(isinstance(value, str) and value for value in platforms)
            or platform not in platforms or len(set(platforms)) != len(platforms)):
        raise ValueError("Manifest compatibility.platforms must cover the built platform")
    artifacts = compatibility.get("artifacts", [])
    if not isinstance(artifacts, list) or not all(isinstance(item, dict) for item in artifacts):
        raise ValueError("Manifest artifacts must be declarations")
    if not artifacts:
        if platforms != ["macos"] or set(declared) != set(architectures):
            raise ValueError("Manifest architectures must exactly match an explicit artifact target")
        return "codex-plugin.zip"
    names = set()
    matches = []
    for artifact in artifacts:
        name = artifact.get("name", "")
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.zip", name)
                or name.casefold() in names):
            raise ValueError("Artifact names must be unique ZIP filenames")
        names.add(name.casefold())
        target_platforms = artifact.get("platforms", [])
        target_architectures = artifact.get("architectures", [])
        if (not isinstance(target_platforms, list) or not isinstance(target_architectures, list)
                or not target_platforms or not target_architectures
                or not all(isinstance(value, str) and value for value in target_platforms + target_architectures)
                or len(set(target_platforms)) != len(target_platforms)
                or len(set(target_architectures)) != len(target_architectures)
                or not set(target_platforms).issubset(platforms)
                or not set(target_architectures).issubset(declared)):
            raise ValueError("Artifact target must be contained in package compatibility")
        if target_platforms == [platform] and set(target_architectures) == set(architectures):
            matches.append(name)
    if len(matches) != 1:
        raise ValueError("Built platform and architectures must match exactly one named artifact")
    return matches[0]


def publish_directory(source, destination):
    if sys.platform == "win32":
        # Windows rename atomically refuses every existing destination.
        os.rename(source, destination)
        return
    # Darwin RENAME_EXCL atomically refuses an existing destination, including an empty directory.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def package(output, configuration):
    repo = Path(__file__).resolve().parent.parent
    check_version(repo)
    if os.path.lexists(output):
        raise ValueError("Output already exists; select a new directory to preserve existing artifacts")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="codex-package-", dir=output.parent))
    try:
        platform = current_platform()
        swift = "/usr/bin/swift" if platform == "macos" else shutil.which("swift")
        if swift is None:
            raise ValueError("Swift must be available to build the native archive")
        build_arguments = []
        sqlite = None
        if platform == "windows":
            shell = shutil.which("pwsh")
            if shell is None:
                raise ValueError("PowerShell is required for the native SQLite build")
            sqlite = json.loads(command([shell, "-NoProfile", "-NonInteractive", "-File",
                str(repo / "Scripts/build-windows-sqlite.ps1"), "-OutputDirectory", str(stage / "sqlite"), "-AsJSON"], repo))
            build_arguments = ["-Xcc", "-I" + sqlite["includeDirectory"],
                               "-Xlinker", "/LIBPATH:" + sqlite["libraryDirectory"]]
        command([swift, "build", "-c", configuration, "--disable-automatic-resolution", *build_arguments], repo)
        built = Path(command([swift, "build", "-c", configuration, "--show-bin-path"], repo))
        executable = built / ("codex-mcp-adapter.exe" if platform == "windows" else "codex-mcp-adapter")
        bundle = built / ("codex-plugin_CodexAdapter.resources" if platform == "windows" else "codex-plugin_CodexAdapter.bundle")
        if not executable.is_file() or not bundle.is_dir():
            raise ValueError("The executable and its SwiftPM resource bundle must both be built")
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
        runtime_receipt = None
        if platform == "windows":
            from windows_package import stage_runtime
            runtime_receipt = stage_runtime(repo, binary_directory, notices, sqlite, swift, command, copy_file, copy_tree)
        validate_payload(payload)
        with (payload / "ThirdPartyNotices.txt").open("wb") as aggregate:
            for entry in sorted(notices.rglob("*")):
                if entry.is_file():
                    aggregate.write(("\n--- " + str(entry.relative_to(notices)) + " ---\n\n").encode())
                    aggregate.write(entry.read_bytes())
                    aggregate.write(b"\n")
        binary = binary_directory / executable.name
        if platform == "macos":
            command(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)], stage)
            command(["/usr/bin/codesign", "--verify", "--strict", str(binary)], stage)
            architectures = command(["/usr/bin/lipo", "-archs", str(binary)], stage).split()
        else:
            architectures = [runtime_receipt["architecture"]]
        manifest = payload / "computer-mcp-plugin.toml"
        archive_name = validate_architectures(manifest, architectures, platform)
        declaration = tomllib.loads(manifest.read_text(encoding="utf-8"))
        contributions = declaration.get("mcp", [])
        if not contributions:
            raise ValueError("Manifest must declare its packaged MCP executable")
        for contribution in contributions:
            selected = contribution.get("executable", {})
            path = selected.get("platform_paths", {}).get(platform, selected.get("path"))
            if path != binary.relative_to(payload).as_posix():
                raise ValueError("Manifest executable must select the native packaged adapter")
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
                inventory[entry.relative_to(payload).as_posix()] = hashlib.sha256(entry.read_bytes()).hexdigest()
        archive = stage / archive_name
        with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as package_zip:
            for entry in sorted(payload.rglob("*")):
                package_zip.write(entry, entry.relative_to(payload).as_posix())
        receipt = {"plugin_id": "codex", "configuration": configuration, "architectures": architectures,
                   "platform": platform, "signature": "ad-hoc" if platform == "macos" else "unsigned",
                   "publisher_verified": False, "published": False,
                   "archive": archive_name, "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                   "archive_bytes": archive.stat().st_size, "files": inventory}
        if runtime_receipt is not None:
            receipt["windows_runtime"] = runtime_receipt
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
