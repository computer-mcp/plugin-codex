"""Stage inspected Windows runtime inputs and their original source notices."""

import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil

import windows_runtime


def notice_sources(root):
    metadata = json.loads((root / "sources.json").read_text(encoding="utf-8"))
    if metadata.get("schema_version") != 1 or not metadata.get("sources"):
        raise ValueError("Missing Windows runtime notice provenance")
    names = set()
    for source in metadata["sources"]:
        name = source["file"]
        if not isinstance(name, str):
            raise ValueError("Invalid Windows runtime notice path")
        path = PurePosixPath(name)
        if (path.is_absolute() or path.as_posix() != name
                or any(part in {"", ".", ".."} for part in name.split("/"))
                or ":" in name or "\\" in name or name.casefold() in names):
            raise ValueError("Invalid Windows runtime notice path")
        names.add(name.casefold())
        local = root.joinpath(*path.parts)
        windows_runtime.regular_file(local)
        if local.stat().st_size != source["bytes"] or windows_runtime.digest(local) != source["sha256"]:
            raise ValueError(f"Windows runtime notice differs from its upstream source: {name}")
    coverage = metadata.get("runtime_libraries", {})
    if not coverage:
        raise ValueError("Missing runtime library notice mapping")
    for name, declaration in coverage.items():
        if not re.fullmatch(r"[a-z0-9_.-]+\.dll", name):
            raise ValueError("Invalid runtime library notice name")
        scope = declaration.get("license_scope")
        sources = declaration.get("sources")
        if (not isinstance(sources, list)
                or any(not isinstance(source, str) or source.casefold() not in names for source in sources)
                or scope not in {"open-source", "Microsoft Visual C++ Redistributable"}
                or (scope == "open-source" and not sources)):
            raise ValueError("Runtime library has incomplete notice coverage")
    return metadata


def stage_runtime(repo, binary_directory, notices, sqlite, swift, command, copy_file, copy_tree):
    notice_root = repo / "Vendor/SwiftWindowsRuntime"
    metadata = notice_sources(notice_root)
    version = re.search(r"Swift version (\d+\.\d+\.\d+)", command([swift, "--version"], repo))
    if version is None or version[1] != metadata["swift_release"]:
        raise ValueError("Swift runtime version must match the reviewed notice provenance")
    runtime_directories = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        directory = Path(entry)
        if entry and (directory / "swiftCore.dll").is_file() and directory not in runtime_directories:
            runtime_directories.append(directory)
    inspector = shutil.which("llvm-readobj")
    if not runtime_directories or inspector is None:
        raise ValueError("Selected Swift runtime directories and llvm-readobj are required")
    report = windows_runtime.audit(binary_directory / "codex-mcp-adapter.exe", runtime_directories,
                                   Path(os.environ["SystemRoot"]) / "System32", Path(inspector))
    if any(row["role"] == "external-msvc-runtime" for row in report["libraries"]):
        raise ValueError("Runtime inputs must come from the selected toolchain, not System32 redistributables")
    coverage = metadata["runtime_libraries"]
    copied = []
    for row in report["libraries"]:
        if row["role"] != "runtime":
            continue
        name = row["name"].casefold()
        declaration = coverage.get(name)
        if declaration is None:
            raise ValueError(f"Runtime library lacks reviewed notice coverage: {row['name']}")
        source = Path(row["path"])
        target = binary_directory / source.name
        if os.path.lexists(target):
            raise ValueError("Runtime DLL collides with the product payload")
        copy_file(source, target)
        if windows_runtime.digest(target) != row["sha256"]:
            raise ValueError("Copied runtime DLL differs from its inspected source")
        copied.append({"file": target.name, "sha256": row["sha256"], "bytes": row["bytes"],
                       "notice_coverage": declaration})
    if not any(row["file"].casefold() == "swiftcore.dll" for row in copied):
        raise ValueError("The native adapter must include its Swift runtime")
    copy_tree(notice_root, notices / "windows-runtime")
    # The original SQLite header retains its public-domain statement verbatim.
    sqlite_notices = notices / "sqlite"
    sqlite_notices.mkdir()
    header = Path(sqlite["includeDirectory"]) / "sqlite3.h"
    if windows_runtime.digest(header) != sqlite["receipt"]["headerSHA256"]:
        raise ValueError("SQLite notice input differs from the compiled source")
    copy_file(header, sqlite_notices / header.name)
    copy_file(repo / "Scripts/windows-sqlite.json", sqlite_notices / "source.json")
    return {"architecture": {"aarch64": "arm64", "x86_64": "x86_64"}[report["architecture"]],
            "swift_version": version[1], "libraries": copied,
            "sqlite_source": sqlite["receipt"]["source"],
            "sqlite_library_sha256": sqlite["receipt"]["librarySHA256"],
            "notice_metadata_sha256": windows_runtime.digest(notice_root / "sources.json"),
            "system_imports": [row["name"] for row in report["libraries"] if row["role"] != "runtime"]}
