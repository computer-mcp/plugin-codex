import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ProtocolCheckoutTests(unittest.TestCase):
    def test_windows_checkout_preserves_hash_bound_resource_bytes(self):
        repository = Path(__file__).resolve().parents[1]
        relatives = [Path('Sources/CodexAdapter/Resources/Protocol'), Path('Vendor/SwiftWindowsRuntime')]
        originals = {path.relative_to(repository): path.read_bytes()
                     for relative in relatives for path in (repository / relative).rglob('*') if path.is_file()}
        manifest = Path('computer-mcp-plugin.toml')
        originals[manifest] = (repository / manifest).read_bytes()
        self.assertTrue(originals)
        with tempfile.TemporaryDirectory(prefix='protocol-checkout-') as directory:
            root = Path(directory)
            index_root = root / 'index'
            checkout = root / 'checkout'
            index_root.mkdir()
            checkout.mkdir()
            shutil.copy2(repository / '.gitattributes', index_root / '.gitattributes')
            for path, data in originals.items():
                target = index_root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            def git(*arguments):
                subprocess.run(['git', '-c', 'core.autocrlf=true', *arguments], cwd=index_root,
                               check=True, capture_output=True)
            git('init', '--quiet')
            git('add', '--', '.gitattributes', manifest.as_posix(), *(relative.as_posix() for relative in relatives))
            git('checkout-index', '--all', '--prefix=' + str(checkout) + os.sep)
            for path, expected in originals.items():
                with self.subTest(resource=path.as_posix()):
                    self.assertEqual((checkout / path).read_bytes(), expected)
