from contextlib import redirect_stderr
import importlib.util
import io
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
        metadata.parent.mkdir(parents=True, exist_ok=True)
        metadata.write_text(version.generated(value))

    def commit(self, root, message):
        version.git(root, "add", version.MANIFEST, version.GENERATED)
        version.git(root, "-c", "user.name=Version Test", "-c", "user.email=version@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message)
        return version.git(root, "rev-parse", "HEAD")

    def test_generated_metadata_cannot_hide_version_regression(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version.git(root, "init")
            self.fixture(root, "0.2.4")
            base = self.commit(root, "Base version")
            self.commit(root, "Current commit")
            self.fixture(root)
            with self.assertRaisesRegex(ValueError, "backwards"):
                version.check(root, base=base)
            for value in ("0.2.4", "0.2.5"):
                with self.subTest(value=value):
                    self.fixture(root, value)
                    self.assertEqual(version.check(root, base=base), value)

    def test_root_commit_checks_current_version_without_comparing_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version.git(root, "init")
            self.fixture(root, "0.2.4")
            base = self.commit(root, "Root version")
            self.fixture(root)
            output = io.StringIO()
            with redirect_stderr(output):
                self.assertEqual(version.check(root, base=base), "0.2.3")
            self.assertIn("HEAD has no parents", output.getvalue())
            (root / version.GENERATED).write_text(version.generated("0.2.4"))
            with self.assertRaisesRegex(ValueError, "metadata differs"):
                version.check(root, base=base)

    def test_unavailable_base_checks_current_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version.git(root, "init")
            self.fixture(root)
            self.commit(root, "Root version")
            self.commit(root, "Current commit")
            output = io.StringIO()
            with redirect_stderr(output):
                self.assertEqual(version.check(root, base="0" * 40), "0.2.3")
            self.assertIn("is unavailable", output.getvalue())

    def test_non_ancestor_base_checks_current_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version.git(root, "init")
            self.fixture(root)
            ancestor = self.commit(root, "Root version")
            self.fixture(root, "0.2.4")
            base = self.commit(root, "Other branch version")
            version.git(root, "checkout", "-b", "current", ancestor)
            self.commit(root, "Current commit")
            output = io.StringIO()
            with redirect_stderr(output):
                self.assertEqual(version.check(root, base=base), "0.2.3")
            self.assertIn("is not an ancestor of HEAD", output.getvalue())

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
