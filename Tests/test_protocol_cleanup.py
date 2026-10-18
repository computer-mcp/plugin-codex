import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "native_protocol_check", Path(__file__).parent / "WindowsAdapter/ProtocolCheck.py")
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)


class ProtocolCleanupTests(unittest.TestCase):
    def test_read_only_git_objects_are_removed_from_the_private_home(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "private"
            objects = root / "codex/.tmp/plugins-clone/.git/objects/pack"
            objects.mkdir(parents=True)
            index = objects / "pack-fixture.idx"
            index.write_bytes(b"private fixture")
            index.chmod(stat.S_IREAD)
            protocol.remove_private_state(root)
            self.assertFalse(root.exists())

    def test_windows_read_only_failure_retries_only_the_owned_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = root / "pack-fixture.idx"
            index.write_bytes(b"private fixture")
            index.chmod(stat.S_IREAD)

            def failed_unlink(path, onerror):
                self.assertEqual(path, root)
                error = PermissionError("Windows read-only object")
                onerror(os.unlink, str(index), (PermissionError, error, None))

            with patch.object(protocol.shutil, "rmtree", side_effect=failed_unlink):
                self.assertEqual(protocol.remove_private_state(root), 1)
            self.assertFalse(index.exists())

    def test_an_acl_denial_is_not_reported_as_success_or_made_more_permissive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "writable"
            file.write_bytes(b"retained evidence")
            mode = file.stat().st_mode
            error = PermissionError("ACL denies cleanup")

            def denied(path, onerror):
                onerror(os.unlink, str(file), (PermissionError, error, None))

            with patch.object(protocol.shutil, "rmtree", side_effect=denied):
                with self.assertRaises(PermissionError):
                    protocol.remove_private_state(root)
            self.assertEqual(file.stat().st_mode, mode)
            self.assertEqual(file.read_bytes(), b"retained evidence")
