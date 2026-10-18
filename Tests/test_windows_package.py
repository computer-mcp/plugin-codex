import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import windows_package


class WindowsPackageNoticesTests(unittest.TestCase):
    def test_staging_copies_open_source_closure_and_records_external_runtime_floor(self):
        repo = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, binary, notices, include = [root / name for name in ("runtime", "bin", "notices", "include")]
            for path in (source, binary, notices, include):
                path.mkdir()
            (source / "swiftCore.dll").write_bytes(b"swift")
            (source / "VCRUNTIME140.dll").write_bytes(b"microsoft")
            (binary / "codex-mcp-adapter.exe").write_bytes(b"adapter")
            header = include / "sqlite3.h"
            header.write_bytes(b"sqlite header")
            rows = []
            for path in source.iterdir():
                rows.append({"name": path.name, "role": "external-msvc-runtime" if path.name.startswith("VC") else "runtime",
                             "path": str(path), "sha256": windows_package.windows_runtime.digest(path),
                             "bytes": path.stat().st_size, "architecture": "x86_64", "version": "14.44.35211.0"})
            report = {"architecture": "x86_64", "libraries": rows}
            sqlite = {"includeDirectory": str(include), "receipt": {"source": "fixture",
                      "librarySHA256": "0" * 64, "headerSHA256": windows_package.windows_runtime.digest(header)}}
            with patch.dict("os.environ", {"PATH": str(source), "SystemRoot": str(root)}), \
                    patch.object(windows_package.shutil, "which", return_value="inspector"), \
                    patch.object(windows_package.windows_runtime, "audit", return_value=report):
                result = windows_package.stage_runtime(repo, binary, notices, sqlite, "swift",
                    lambda *_: "Swift version 6.2.3", shutil.copyfile, shutil.copytree)
            self.assertEqual([row["file"] for row in result["libraries"]], ["swiftCore.dll"])
            self.assertFalse((binary / "VCRUNTIME140.dll").exists())
            self.assertEqual(result["external_prerequisites"][0]["minimum_version"], "14.44.35211.0")
            self.assertEqual(result["system_imports"], [])

    def test_notice_bytes_and_component_coverage_bind_to_the_owned_sources(self):
        source = Path(__file__).resolve().parents[1] / "Vendor/SwiftWindowsRuntime"
        original = windows_package.notice_sources(source)
        self.assertEqual(len(original["runtime_libraries"]), 19)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "notices"
            shutil.copytree(source, root)
            selected = root / original["sources"][0]["file"]
            selected.write_bytes(selected.read_bytes() + b"modified")
            with self.assertRaisesRegex(ValueError, "differs from its upstream"):
                windows_package.notice_sources(root)
            shutil.copyfile(source / original["sources"][0]["file"], selected)
            changed = json.loads((root / "sources.json").read_text())
            changed["runtime_libraries"]["swiftcore.dll"]["sources"] = ["missing/LICENSE"]
            (root / "sources.json").write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, "incomplete notice"):
                windows_package.notice_sources(root)
