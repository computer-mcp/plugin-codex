import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location("plugin_package", Path(__file__).resolve().parents[1] / "Scripts/package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageOwnershipTests(unittest.TestCase):
    def make_repository(self, root):
        repo = root / "repo"
        built = repo / ".build/debug"
        bundle = built / "codex-plugin_CodexAdapter.bundle"
        bundle.mkdir(parents=True)
        (bundle / "schema.json").write_text("{}")
        (built / "codex-mcp-adapter").write_bytes(b"fixture executable")
        for name in ("computer-mcp-plugin.toml", "README.md", "CONTRIBUTING.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            (repo / name).write_text("fixture content\n")
        (repo / "computer-mcp-plugin.toml").write_text(
            "id = 'codex'\nversion = '1.2.3'\n\n[compatibility]\narchitectures = ['arm64']\n"
        )
        (repo / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "swift-codex"}]}))
        documentation = repo / "Documentation"
        documentation.mkdir()
        (documentation / "README.md").write_text("fixture documentation")
        checkout = repo / ".build/checkouts/swift-codex"
        schema = checkout / "Vendor/CodexAppServerProtocolSchema"
        schema.mkdir(parents=True)
        (checkout / "LICENSE").write_text("fixture dependency license")
        for name in ("LICENSE", "NOTICE"):
            (schema / name).write_text("fixture schema notice")
        return repo, built

    def test_package_preserves_manifest_bytes_in_archive_and_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, built = self.make_repository(root)
            manifest = (repo / "computer-mcp-plugin.toml").read_bytes()

            def command(arguments, cwd):
                if "--show-bin-path" in arguments:
                    return str(built)
                if "-archs" in arguments:
                    return "arm64"
                return ""

            with patch.object(package, "__file__", str(repo / "Scripts/package.py")), patch.object(
                package, "command", side_effect=command
            ):
                result = package.package(root / "output", "debug")
            with zipfile.ZipFile(result["archive"]) as archive:
                self.assertEqual(archive.read("computer-mcp-plugin.toml"), manifest)
            receipt = json.loads(Path(result["receipt"]).read_text())
            self.assertEqual(receipt["architectures"], ["arm64"])
            self.assertEqual(receipt["files"]["computer-mcp-plugin.toml"], package.hashlib.sha256(manifest).hexdigest())

    def test_architecture_declaration_is_explicit_and_matches_all_slices(self):
        declarations = [
            "", "compatibility = 'arm64'", "[compatibility]\narchitectures = 'arm64'",
            "[compatibility]\narchitectures = []", "[compatibility]\narchitectures = [1]",
            "[compatibility]\narchitectures = ['arm64', 'arm64']",
            "[compatibility]\narchitectures = ['arm64', 'x86_64']",
        ]
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.toml"
            for declaration in declarations:
                with self.subTest(declaration=declaration):
                    manifest.write_text(declaration)
                    with self.assertRaisesRegex(ValueError, "architectures"):
                        package.validate_architectures(manifest, ["arm64"])
            manifest.write_text("[compatibility]\narchitectures = ['x86_64', 'arm64']")
            package.validate_architectures(manifest, ["arm64", "x86_64"])

    def test_package_rejects_slice_mismatch_and_manifest_mutation_before_publication(self):
        for failure in ("slice_mismatch", "manifest_mutation"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo, built = self.make_repository(root)
                original = (repo / "computer-mcp-plugin.toml").read_bytes()

                def command(arguments, cwd):
                    if "--show-bin-path" in arguments:
                        return str(built)
                    if "-archs" in arguments:
                        return "x86_64" if failure == "slice_mismatch" else "arm64"
                    if "--help" in arguments:
                        self.assertNotEqual(failure, "slice_mismatch")
                        manifest = Path(cwd) / "package/computer-mcp-plugin.toml"
                        manifest.write_bytes(original + b"\n# changed declaration bytes\n")
                    return ""

                with patch.object(package, "__file__", str(repo / "Scripts/package.py")), patch.object(
                    package, "command", side_effect=command
                ):
                    with self.assertRaises(ValueError):
                        package.package(root / "output", "debug")
                self.assertFalse((root / "output").exists())
                self.assertEqual(list(root.glob("codex-package-*")), [])
                self.assertEqual((repo / "computer-mcp-plugin.toml").read_bytes(), original)

    def test_package_rejects_links_before_signing_or_running_payload(self):
        for relative in ("README.md", "Documentation/link", ".build/debug/codex-plugin_CodexAdapter.bundle/link"):
            with self.subTest(input=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo, built = self.make_repository(root)
                outside = root / "outside"
                outside.write_bytes(b"user owned")
                link = repo / relative
                if link.exists():
                    link.unlink()
                link.symlink_to(outside)
                with patch.object(package, "__file__", str(repo / "Scripts/package.py")), patch.object(
                    package, "command", side_effect=["", str(built)]
                ) as commands:
                    with self.assertRaises(ValueError):
                        package.package(root / "output", "debug")
                self.assertEqual(commands.call_count, 2)
                self.assertFalse((root / "output").exists())
                self.assertEqual(list(root.glob("codex-package-*")), [])
                self.assertEqual(outside.read_bytes(), b"user owned")

    def test_package_does_not_replace_destination_created_during_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, built = self.make_repository(root)
            output = root / "output"

            def command(arguments, cwd):
                if "--show-bin-path" in arguments:
                    output.mkdir()
                    return str(built)
                if "-archs" in arguments:
                    return "arm64"
                return ""

            with patch.object(package, "__file__", str(repo / "Scripts/package.py")), patch.object(
                package, "command", side_effect=command
            ):
                with self.assertRaises(FileExistsError):
                    package.package(output, "debug")
            self.assertTrue(output.is_dir())
            self.assertEqual(list(output.iterdir()), [])
            self.assertEqual(list(root.glob("codex-package-*")), [])

    def test_regular_files_preserve_bytes_and_executable_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_bytes(b"owned program")
            source.chmod(0o755)
            target = root / "target"
            package.copy_file(source, target)
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            package.validate_payload(root)

    def test_file_links_and_special_files_are_rejected_without_reading_their_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside"
            outside.write_bytes(b"user owned")
            link = root / "link"
            link.symlink_to(outside)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            for source in (link, fifo):
                with self.subTest(source=source.name), self.assertRaises(ValueError):
                    package.copy_file(source, root / "target")
                self.assertFalse((root / "target").exists())
            self.assertEqual(outside.read_bytes(), b"user owned")

    def test_nested_file_directory_and_dangling_links_are_not_dereferenced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            outside = root / "outside"
            outside.mkdir()
            (outside / "sentinel").write_bytes(b"user owned")
            for name, target in (("file", outside / "sentinel"), ("directory", outside), ("dangling", root / "missing")):
                with self.subTest(name=name):
                    link = source / name
                    link.symlink_to(target)
                    copied = root / ("copied-" + name)
                    package.copy_tree(source, copied)
                    self.assertTrue((copied / name).is_symlink())
                    with self.assertRaises(ValueError):
                        package.validate_payload(copied)
                    link.unlink()
            self.assertEqual((outside / "sentinel").read_bytes(), b"user owned")

    def test_linked_tree_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "link"
            source.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                package.copy_tree(source, root / "target")
            self.assertFalse((root / "target").exists())

    def test_exclusive_publication_preserves_every_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "stage"
            source.mkdir()
            (source / "artifact").write_bytes(b"new artifact")
            empty = root / "empty"
            empty.mkdir()
            occupied = root / "occupied"
            occupied.mkdir()
            (occupied / "sentinel").write_bytes(b"user owned")
            link = root / "link"
            link.symlink_to(root / "absent")
            file = root / "file"
            file.write_bytes(b"user owned")
            for target in (empty, occupied, link, file):
                with self.subTest(target=target.name), self.assertRaises(FileExistsError):
                    package.publish_directory(source, target)
                self.assertEqual((source / "artifact").read_bytes(), b"new artifact")
            self.assertEqual(list(empty.iterdir()), [])
            self.assertEqual((occupied / "sentinel").read_bytes(), b"user owned")
            self.assertTrue(link.is_symlink())
            self.assertEqual(file.read_bytes(), b"user owned")
            package.publish_directory(source, root / "published")
            self.assertFalse(source.exists())
            self.assertEqual((root / "published/artifact").read_bytes(), b"new artifact")


if __name__ == "__main__":
    unittest.main()
