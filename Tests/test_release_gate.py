import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SDKReleaseGateTests(unittest.TestCase):
    def run_gate(self, requirement='exact: "2.3.4"', version="2.3.4",
                 revision="a" * 40, remote=None, remote_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            source = Path(__file__).resolve().parents[1] / "Scripts/verify-swift-codex-release-gate.sh"
            shutil.copy2(source, scripts / source.name)
            (root / "Package.swift").write_text(
                '.package(\n url: "https://github.com/swift-library/swift-codex.git",\n '
                + requirement + '\n)\n'
            )
            (root / "Package.resolved").write_text(json.dumps({"pins": [{
                "identity": "swift-codex", "location": "https://github.com/swift-library/swift-codex.git",
                "state": {"version": version, "revision": revision}
            }]}))
            git = root / "git"
            git.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_REMOTE_REFS"\nexit "$TEST_REMOTE_STATUS"\n')
            git.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       TEST_REMOTE_REFS=remote or "a" * 40 + "\trefs/tags/v2.3.4",
                       TEST_REMOTE_STATUS=str(remote_status))
            return subprocess.run(["/bin/zsh", str(scripts / source.name)], env=env,
                                  capture_output=True, text=True)

    def test_exact_version_accepts_lightweight_and_annotated_tags(self):
        self.assertEqual(self.run_gate().returncode, 0)
        remote = "b" * 40 + "\trefs/tags/v2.3.4\n" + "a" * 40 + "\trefs/tags/v2.3.4^{}"
        self.assertEqual(self.run_gate(remote=remote).returncode, 0)

    def test_non_exact_or_inconsistent_resolution_is_rejected(self):
        for arguments in ({"requirement": 'branch: "main"'},
                          {"requirement": 'revision: "' + "a" * 40 + '"'},
                          {"version": "2.3.5"}, {"revision": "b" * 40}):
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.run_gate(**arguments).returncode, 0)

    def test_missing_remote_tag_is_rejected(self):
        result = self.run_gate(remote_status=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public SDK tag is unavailable", result.stderr)
