#!/usr/bin/env python3
"""Inspect a Windows executable's recursive runtime imports without loading it."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def regular_file(path):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode)
            or getattr(metadata, "st_file_attributes", 0) & 0x400):
        raise ValueError(f"Runtime input is a link or special file: {path}")


def imports(path, inspector):
    regular_file(path)
    result = subprocess.run([str(inspector), "--file-headers", "--coff-imports", str(path)],
                            capture_output=True, text=True, check=True, timeout=60)
    architecture = re.search(r"^Arch: (\S+)$", result.stdout, re.MULTILINE)
    if architecture is None or architecture[1] not in {"x86_64", "aarch64"}:
        raise ValueError(f"Unsupported or missing PE architecture: {path}")
    names = re.findall(r"^  Name: (.+)$", result.stdout, re.MULTILINE)
    for name in names:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.dll", name, re.IGNORECASE):
            raise ValueError(f"Invalid DLL import: {name!r}")
    return architecture[1], sorted(set(names), key=str.casefold)


def directory_files(directory):
    metadata = directory.lstat()
    if (not stat.S_ISDIR(metadata.st_mode)
            or getattr(metadata, "st_file_attributes", 0) & 0x400):
        raise ValueError(f"Runtime directory is a link or special file: {directory}")
    result = {}
    for path in directory.iterdir():
        if path.suffix.lower() == ".dll":
            key = path.name.casefold()
            if key in result:
                raise ValueError(f"Case-colliding DLL names in {directory}: {path.name}")
            result[key] = path
    return result


def resolve(name, runtime_files, system_files):
    key = name.casefold()
    # API-set contracts are resolved by Windows, not independent redistributable files.
    if key.startswith(("api-ms-win-", "ext-ms-win-")):
        return "windows-api-set", None
    candidates = [files[key] for files in runtime_files if key in files]
    if candidates:
        for path in candidates:
            regular_file(path)
        if len({digest(path) for path in candidates}) != 1:
            raise ValueError(f"Conflicting runtime DLL sources for {name}: {candidates}")
        return "runtime", candidates[0]
    if key in system_files:
        # Visual C++ redistributables are not Windows OS components, even in System32.
        role = ("external-msvc-runtime" if key.startswith(("vcruntime", "msvcp", "concrt"))
                else "windows-system")
        regular_file(system_files[key])
        return role, system_files[key]
    raise ValueError(f"Unresolved DLL import: {name}")


def audit(executable, runtime_directories, system_directory, inspector):
    runtime_files = [directory_files(path) for path in runtime_directories]
    system_files = directory_files(system_directory)
    architecture, direct = imports(executable, inspector)
    queue = [(name, executable.name) for name in direct]
    libraries = {}
    while queue:
        name, owner = queue.pop(0)
        key = name.casefold()
        if key in libraries:
            if owner not in libraries[key]["imported_by"]:
                libraries[key]["imported_by"].append(owner)
            continue
        role, path = resolve(name, runtime_files, system_files)
        entry = {"name": name, "role": role, "imported_by": [owner]}
        libraries[key] = entry
        if path is not None:
            entry.update(path=str(path), bytes=path.stat().st_size, sha256=digest(path))
        if role in {"runtime", "external-msvc-runtime"}:
            native_arch, dependencies = imports(path, inspector)
            if native_arch != architecture:
                raise ValueError(f"Runtime architecture mismatch: {path}: {native_arch} != {architecture}")
            entry.update(architecture=native_arch, imports=dependencies)
            queue.extend((dependency, name) for dependency in dependencies)
    return {"executable": str(executable), "sha256": digest(executable),
            "architecture": architecture, "runtime_directories": list(map(str, runtime_directories)),
            "system_directory": str(system_directory), "inspector": str(inspector),
            "imports": direct, "libraries": sorted(libraries.values(), key=lambda row: row["name"].casefold()),
            "evidence_class": "static-native-import-closure", "relocation_verified": False,
            "dynamic_loads_verified": False, "distribution_notices_verified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--runtime-directory", action="append", required=True, type=Path)
    parser.add_argument("--system-directory", required=True, type=Path)
    parser.add_argument("--inspector", type=Path, default=shutil.which("llvm-readobj"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.inspector is None:
        parser.error("llvm-readobj is required")
    report = audit(args.executable, args.runtime_directory, args.system_directory, args.inspector)
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps({"architecture": report["architecture"], "libraries": len(report["libraries"]),
                      "report": str(args.output)}))
