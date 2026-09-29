import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

scripts = Path(__file__).resolve().parents[1] / "Scripts"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("check_package", scripts / "check-package.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ArchiveAcceptanceTests(unittest.TestCase):
    def fixture(self, root, additions=()):
        manifest = root / "manifest.toml"
        manifest.write_bytes(b"id = 'codex'\nversion = '1.2.3'\n[compatibility]\narchitectures = ['arm64']\n")
        archive = root / "codex-plugin.zip"
        rows = [("computer-mcp-plugin.toml", manifest.read_bytes(), stat.S_IFREG | 0o644),
                ("bin/adapter", b"executable bytes", stat.S_IFREG | 0o755), *additions]
        inventory = {}
        with zipfile.ZipFile(archive, "w") as zipped:
            for name, data, mode in rows:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                zipped.writestr(info, data)
                if not name.endswith("/"):
                    inventory[name] = hashlib.sha256(data).hexdigest()
        receipt = root / "receipt.json"
        receipt.write_text(json.dumps({"files": inventory, "plugin_id": "codex", "platform": "macos",
            "architectures": ["arm64"], "archive": archive.name, "archive_bytes": archive.stat().st_size,
            "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}))
        return archive, receipt, manifest

    def test_exact_archive_relocates_with_manifest_bytes_and_executable_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = self.fixture(root)
            result = checker.verify(*arguments, root / "relocated")
            self.assertEqual(result["files_verified"], 2)
            self.assertEqual((root / "relocated/computer-mcp-plugin.toml").read_bytes(), arguments[2].read_bytes())
            self.assertEqual((root / "relocated/bin/adapter").read_bytes(), b"executable bytes")
            if os.name != "nt":
                self.assertEqual((root / "relocated/bin/adapter").stat().st_mode & 0o777, 0o755)

    def test_unsafe_names_links_modes_and_case_aliases_fail_before_extraction(self):
        cases = [(name, b"content", stat.S_IFREG | 0o644) for name in (
            "../outside", "/absolute", "C:/outside", "bin\\outside", "bin/../outside",
            "bin/./outside", "bin/file.", "bin/file ", "bin/NUL", "BIN/other")]
        cases += [("bin/link", b"../outside", stat.S_IFLNK | 0o777),
                  ("bin/privileged", b"content", stat.S_IFREG | 0o4755),
                  ("bin/pipe", b"", stat.S_IFIFO | 0o644),
                  ("BIN/ADAPTER", b"collision", stat.S_IFREG | 0o644),
                  ("bin", b"file/directory collision", stat.S_IFREG | 0o644),
                  ("unknown/", b"", stat.S_IFDIR | 0o755)]
        for row in cases:
            with self.subTest(row=row), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                arguments = self.fixture(root, [row])
                with self.assertRaises(ValueError):
                    checker.verify(*arguments, root / "relocated")
                self.assertFalse((root / "relocated").exists())

    def test_archive_inventory_and_manifest_tampering_are_detected(self):
        for case in ["archive", "file", "omitted", "manifest"]:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive, receipt, manifest = self.fixture(root)
                if case == "archive":
                    with archive.open("ab") as stream:
                        stream.write(b"unaccepted bytes")
                elif case == "manifest":
                    with manifest.open("ab") as stream:
                        stream.write(b"# different declaration\n")
                else:
                    data = json.loads(receipt.read_text())
                    if case == "file":
                        data["files"]["bin/adapter"] = "0" * 64
                    else:
                        del data["files"]["bin/adapter"]
                    receipt.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    checker.verify(archive, receipt, manifest, root / "relocated")
                self.assertFalse((root / "relocated").exists())

    def test_relocation_preserves_destination_created_during_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = self.fixture(root)
            destination = root / "relocated"
            original = checker.publish_directory

            def publish(stage, output):
                output.mkdir()
                (output / "sentinel").write_bytes(b"user owned")
                original(stage, output)

            with patch.object(checker, "publish_directory", side_effect=publish), self.assertRaises(FileExistsError):
                checker.verify(*arguments, destination)
            self.assertEqual((destination / "sentinel").read_bytes(), b"user owned")
            self.assertEqual(list(root.glob("codex-relocation-*")), [])
            with self.assertRaises(ValueError):
                checker.verify(*arguments, destination)


if __name__ == "__main__":
    unittest.main()
