import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import windows_package


class WindowsPackageNoticesTests(unittest.TestCase):
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
