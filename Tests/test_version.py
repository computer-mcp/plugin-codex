import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("plugin_version", Path(__file__).resolve().parents[1] / "Scripts/version.py")
version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(version)


class PluginVersionTests(unittest.TestCase):
    def fixture(self, root, value="0.2.3"):
        (root / version.MANIFEST).write_text(f'version = "{value}"\n')
        metadata = root / version.GENERATED
        metadata.parent.mkdir(parents=True)
        metadata.write_text(version.generated(value))

    def test_generated_metadata_cannot_hide_version_regression(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            with patch.object(version, "git", return_value='version = "0.2.4"'):
                with self.assertRaisesRegex(ValueError, "backwards"):
                    version.check(root, base="base")
            with patch.object(version, "git", return_value='version = "0.2.3"'):
                self.assertEqual(version.check(root, base="base"), "0.2.3")

    def test_tag_requires_both_manifest_version_and_exact_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            with self.assertRaisesRegex(ValueError, "manifest"):
                version.check(root, tag="v9.9.9")
            with patch.object(version, "git", side_effect=["old-commit", "new-commit"]):
                with self.assertRaisesRegex(ValueError, "checked commit"):
                    version.check(root, tag="v0.2.3")
            with patch.object(version, "git", return_value="accepted-commit"):
                self.assertEqual(version.check(root, tag="v0.2.3"), "0.2.3")

    def test_pre_stable_patch_is_compatible_and_breaking_change_advances_minor(self):
        self.assertEqual(version.next_version("0.2.3", "fix"), "0.2.4")
        self.assertEqual(version.next_version("0.2.3", "feature"), "0.3.0")
        self.assertEqual(version.next_version("0.2.3", "breaking"), "0.3.0")
        self.assertEqual(version.next_version("2.3.4", "breaking"), "3.0.0")

    def test_nested_dependency_version_does_not_replace_plugin_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / version.MANIFEST
            manifest.write_text("version = '0.2.3'\n[[dependencies]]\nid = 'vendor'\nversion = '9.8.7'\n")
            self.assertEqual(version.read(root), "0.2.3")
            metadata = root / version.GENERATED
            metadata.parent.mkdir(parents=True)
            metadata.write_text(version.generated("9.8.7"))
            with self.assertRaises(ValueError):
                version.check(root)
            self.assertIn("9.8.7", metadata.read_text())


if __name__ == "__main__":
    unittest.main()
