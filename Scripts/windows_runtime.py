#!/usr/bin/env python3
"""Inspect a Windows executable's recursive runtime imports without loading it."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def regular_file(path):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode)
            or getattr(metadata, "st_file_attributes", 0) & 0x400):
        raise ValueError(f"Runtime input is a link or special file: {path}")


def is_msvc_runtime(name):
    return re.fullmatch(r"(?:vcruntime|msvcp|concrt|vccorlib)\d[a-z0-9_]*\.dll", name.casefold()) is not None


def pe_architecture(path):
    regular_file(path)
    with path.open("rb") as source:
        header = source.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError(f"Missing PE header: {path}")
        source.seek(struct.unpack_from("<I", header, 60)[0])
        coff = source.read(6)
    if len(coff) != 6 or coff[:4] != b"PE\0\0":
        raise ValueError(f"Invalid PE header: {path}")
    architecture = {0x8664: "x86_64", 0xAA64: "aarch64"}.get(struct.unpack_from("<H", coff, 4)[0])
    if architecture is None:
        raise ValueError(f"Unsupported PE architecture: {path}")
    return architecture


def file_version(path):
    """Read the fixed native version resource without executing the DLL."""
    if os.name != "nt":
        raise ValueError("Native file version observation requires Windows")
    from ctypes import wintypes
    version = ctypes.WinDLL("version", use_last_error=True)
    version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
    version.GetFileVersionInfoW.restype = wintypes.BOOL
    version.VerQueryValueW.argtypes = [wintypes.LPCVOID, wintypes.LPCWSTR,
                                      ctypes.POINTER(wintypes.LPVOID), ctypes.POINTER(wintypes.UINT)]
    version.VerQueryValueW.restype = wintypes.BOOL
    size = version.GetFileVersionInfoSizeW(str(path), None)
    if not size or size > 1024 * 1024:
        raise ValueError(f"Missing or oversized file version resource: {path}")
    buffer = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(str(path), 0, size, buffer):
        raise ctypes.WinError(ctypes.get_last_error())
    pointer, length = wintypes.LPVOID(), wintypes.UINT()
    if not version.VerQueryValueW(buffer, "\\", ctypes.byref(pointer), ctypes.byref(length)) or length.value < 52:
        raise ValueError(f"Missing fixed file version: {path}")
    fields = ctypes.cast(pointer, ctypes.POINTER(wintypes.DWORD))
    if fields[0] != 0xFEEF04BD:
        raise ValueError(f"Invalid fixed file version signature: {path}")
    return ".".join(map(str, (fields[2] >> 16, fields[2] & 0xFFFF, fields[3] >> 16, fields[3] & 0xFFFF)))


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{1,5}(?:\.\d{1,5}){3}", value):
        raise ValueError("Runtime version must have four numeric components")
    result = tuple(map(int, value.split(".")))
    if max(result) > 65535:
        raise ValueError("Runtime version component exceeds its native bound")
    return result


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
        return ("external-msvc-runtime" if is_msvc_runtime(name) else "runtime"), candidates[0]
    if key in system_files:
        # Visual C++ redistributables are not Windows OS components, even in System32.
        role = ("external-msvc-runtime" if is_msvc_runtime(name)
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
            if role == "external-msvc-runtime":
                entry["version"] = file_version(path)
            queue.extend((dependency, name) for dependency in dependencies)
    return {"executable": str(executable), "sha256": digest(executable),
            "architecture": architecture, "runtime_directories": list(map(str, runtime_directories)),
            "system_directory": str(system_directory), "inspector": str(inspector),
            "imports": direct, "libraries": sorted(libraries.values(), key=lambda row: row["name"].casefold()),
            "evidence_class": "static-native-import-closure", "relocation_verified": False,
            "dynamic_loads_verified": False, "distribution_notices_verified": False}


def loaded_modules(pid):
    """Observe the live process through a retained handle, independent of PATH."""
    if os.name != "nt":
        raise ValueError("Native module observation requires Windows")
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    kernel.K32EnumProcessModulesEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE),
                                             wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]
    kernel.K32EnumProcessModulesEx.restype = wintypes.BOOL
    kernel.K32GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE,
                                            wintypes.LPWSTR, wintypes.DWORD]
    kernel.K32GetModuleFileNameExW.restype = wintypes.DWORD
    handle = kernel.OpenProcess(0x0400 | 0x0010, False, pid)  # QUERY_INFORMATION | VM_READ
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        count = 128
        for _ in range(4):
            modules = (wintypes.HMODULE * count)()
            needed = wintypes.DWORD()
            if not kernel.K32EnumProcessModulesEx(handle, modules, ctypes.sizeof(modules),
                                                  ctypes.byref(needed), 3):
                raise ctypes.WinError(ctypes.get_last_error())
            if needed.value <= ctypes.sizeof(modules):
                break
            count = needed.value // ctypes.sizeof(wintypes.HMODULE) + 32
            if count > 4096:
                raise ValueError("Native module inventory exceeds the observation bound")
        else:
            raise ValueError("Native module inventory changed during observation")
        paths = []
        for module in modules[:needed.value // ctypes.sizeof(wintypes.HMODULE)]:
            buffer = ctypes.create_unicode_buffer(32768)
            length = kernel.K32GetModuleFileNameExW(handle, module, buffer, len(buffer))
            if not length:
                raise ctypes.WinError(ctypes.get_last_error())
            if length >= len(buffer):
                raise ValueError("Native module path was truncated")
            paths.append(Path(buffer.value))
        return paths
    finally:
        kernel.CloseHandle(handle)


def verify_prerequisites(executable, system_directory, requirements):
    local = directory_files(executable.parent)
    if any(is_msvc_runtime(name) for name in local):
        raise ValueError("Microsoft runtime DLLs must be installed separately, not bundled")
    architecture = pe_architecture(executable)
    system = directory_files(system_directory)
    result, seen = [], set()
    if not requirements:
        raise ValueError("Missing Microsoft runtime prerequisite declarations")
    for requirement in requirements:
        name = requirement["name"].casefold()
        if not is_msvc_runtime(name) or name in seen:
            raise ValueError("Invalid or duplicate Microsoft runtime prerequisite")
        seen.add(name)
        minimum = version_tuple(requirement["minimum_version"])
        path = system.get(name)
        if path is None:
            raise ValueError(f"Install the official Microsoft Visual C++ runtime: missing {name}")
        if pe_architecture(path) != architecture:
            raise ValueError(f"Microsoft runtime architecture mismatch: {path}")
        current = file_version(path)
        if version_tuple(current) < minimum:
            raise ValueError(f"Update the official Microsoft Visual C++ runtime: {name} {current} < {requirement['minimum_version']}")
        result.append({"name": name, "path": str(path), "version": current,
                       "minimum_version": requirement["minimum_version"], "architecture": architecture,
                       "sha256": digest(path), "role": "external-msvc-runtime"})
    return result


def verify_app_local_modules(modules, executable, system_directory, prerequisites=()):
    local = directory_files(executable.parent)
    if any(is_msvc_runtime(name) for name in local):
        raise ValueError("Microsoft runtime DLLs must be installed separately, not bundled")
    external = {row["name"].casefold(): row for row in prerequisites}
    observed = set()
    result = []
    for path in modules:
        name = path.name.casefold()
        regular_file(path)
        if is_msvc_runtime(name):
            expected = external.get(name)
            if expected is None or not path.samefile(Path(expected["path"])) or digest(path) != expected["sha256"]:
                raise ValueError(f"Process loaded an unverified Microsoft runtime: {path}")
            role = "external-msvc-runtime"
        elif name in local:
            if not path.samefile(local[name]):
                raise ValueError(f"Packaged runtime was loaded from outside the package: {path}")
            role = "app-local-runtime"
            observed.add(name)
        elif path.samefile(executable):
            role = "adapter"
        elif path.parent.samefile(system_directory):
            role = "windows-system"
        else:
            raise ValueError(f"Process loaded an undeclared external module: {path}")
        result.append({"path": str(path), "role": role, "sha256": digest(path)})
    if "swiftcore.dll" not in observed:
        raise ValueError("No app-local Swift runtime was observed")
    return result


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
