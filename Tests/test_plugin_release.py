"""Offline release verification, publication, interruption and recovery tests."""

import base64
from contextlib import redirect_stderr, redirect_stdout
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/plugin_release.py"
WORKFLOW = ROOT / ".github/workflows/release.yml"
spec = importlib.util.spec_from_file_location("plugin_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
REPOSITORY = "example/plugin-codex"
API_ROOT = "/repos/" + REPOSITORY
COMMIT = "a" * 40
WORKFLOW_SHA = "b" * 40
WORKFLOW_REF = REPOSITORY + "/" + release.WORKFLOW + "refs/heads/master"
TAG = "v0.2.0"
ARCHIVE = "codex-plugin-macos-arm64.zip"
NATIVE = ARCHIVE[:-4] + ".receipt.json"
MANIFEST = (b'id = "codex"\nversion = "0.2.0"\nplugin_api = 1\n[compatibility]\n'
            b'minimum_host = "0.1.0"\nplatforms = ["macos"]\narchitectures = ["arm64"]\n'
            b'[[compatibility.artifacts]]\nname = "codex-plugin-macos-arm64.zip"\n'
            b'platforms = ["macos"]\narchitectures = ["arm64"]\n')


def native_files(manifest=MANIFEST, payload=b"owned", name=ARCHIVE, architecture="arm64"):
    contents = {"computer-mcp-plugin.toml": manifest, "bin/tool": payload}
    data = zip_bytes(contents)
    receipt = {"plugin_id": "codex", "platform": "macos", "architectures": [architecture],
               "archive": name, "archive_sha256": release.sha256(data), "archive_bytes": len(data),
               "files": {name: release.sha256(data) for name, data in contents.items()}}
    return {name: data, name[:-4] + ".receipt.json": release.canonical(receipt)}



def workflow_job(name):
    return re.search(r"(?ms)^  " + name + r":\n(.*?)(?=^  [a-z_-]+:\n|\Z)", WORKFLOW.read_text())[1]


def python_step(job):
    return textwrap.dedent(workflow_job(job).split("<<'PY'\n", 1)[1].split("\n          PY", 1)[0])


def zip_bytes(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(entry, data)
    return output.getvalue()


class FakeGitHub:
    """The same four-operation API boundary as the real REST transport."""

    def __init__(self, archives):
        self.calls = []
        self.writes = []
        self.manifest = MANIFEST
        self.runs = {10: self.run()}
        self.attempts = {(10, 1): self.run()}
        self.artifacts = {}
        self.artifact_bytes = {}
        self.releases = {}
        self.assets = {}
        self.asset_bytes = {}
        self.next_id = 100
        self.fail = None
        self.tag_type = "tag"
        self.tag_commit = COMMIT
        self.verified = True
        self.reason = "valid"
        self.immutability = {"enabled": True, "enforced_by_owner": False}
        self.install_artifact(20, archives)

    def run(self, **changes):
        run = {"id": 10, "run_attempt": 1, "event": "push", "head_branch": "main",
               "head_sha": COMMIT, "head_repository": {"full_name": REPOSITORY},
               "path": ".github/workflows/ci.yml", "status": "completed", "conclusion": "success",
               "run_started_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:10:00Z"}
        run.update(changes)
        return run

    def install_artifact(self, artifact_id, archives, **changes):
        name = next(name for name in archives if name.endswith(".zip"))
        data = zip_bytes({name: archives[name], "receipt.json": archives[name[:-4] + ".receipt.json"]})
        artifact = {"id": artifact_id, "name": name[:-4] + "-" + COMMIT, "expired": False,
                    "digest": "sha256:" + release.sha256(data), "created_at": "2026-01-01T00:05:00Z",
                    "workflow_run": {"id": 10, "head_sha": COMMIT}}
        artifact.update(changes)
        self.artifacts[artifact_id] = artifact
        self.artifact_bytes[artifact_id] = data

    def rerun_ci(self, archives):
        self.runs[10] = self.run(run_attempt=2, run_started_at="2026-01-02T00:00:00Z",
                                updated_at="2026-01-02T00:10:00Z")
        self.attempts[10, 2] = copy.deepcopy(self.runs[10])
        self.install_artifact(21, archives, created_at="2026-01-02T00:05:00Z")

    def _record(self, method, path):
        self.calls.append((method, path))
        assert path.startswith(API_ROOT), path
        return path[len(API_ROOT):]

    def get(self, path):
        route = self._record("GET", path)
        if route == "":
            result = {"default_branch": "main"}
        elif route == "/immutable-releases":
            result = self.immutability
        elif route.startswith("/contents/computer-mcp-plugin.toml?"):
            assert parse_qs(urlsplit(route).query) == {"ref": [self.tag_commit]}
            result = {"type": "file", "encoding": "base64", "content": base64.b64encode(self.manifest).decode()}
        elif route.startswith("/git/ref/tags/"):
            result = {"object": {"type": self.tag_type, "sha": "c" * 40}}
        elif route.startswith("/git/tags/"):
            result = {"tag": TAG, "object": {"type": "commit", "sha": self.tag_commit},
                      "verification": {"verified": self.verified, "reason": self.reason}}
        elif route.startswith("/commits/"):
            result = {"sha": COMMIT}
        elif route.startswith("/actions/runs/"):
            parts = route.split("/")
            run_id = int(parts[3])
            if "/attempts/" in route:
                key = run_id, int(parts[5])
                if key not in self.attempts:
                    raise release.APIError(404, path)
                result = self.attempts[key]
            else:
                result = self.runs[run_id]
        elif route.startswith("/actions/artifacts/"):
            artifact_id = int(route.split("/")[3])
            if artifact_id not in self.artifacts:
                raise release.APIError(404, path)
            result = self.artifacts[artifact_id]
        elif route.startswith("/releases/"):
            result = self.releases[int(route.split("/")[2])]
        else:
            raise AssertionError(("GET", route))
        return copy.deepcopy(result)

    def list(self, path, key=None):
        route = self._record("LIST", path)
        if route.startswith("/actions/workflows/ci.yml/runs?"):
            assert key == "workflow_runs"
            result = list(self.runs.values())
        elif route.endswith("/artifacts"):
            assert key == "artifacts"
            run_id = int(route.split("/")[3])
            result = [item for item in self.artifacts.values() if item["workflow_run"]["id"] == run_id]
        elif route == "/releases":
            result = list(self.releases.values())
        elif route.endswith("/assets"):
            release_id = int(route.split("/")[2])
            result = [item for item in self.assets.values() if item["release_id"] == release_id]
        else:
            raise AssertionError(("LIST", route))
        return copy.deepcopy(result)

    def download(self, path):
        route = self._record("DOWNLOAD", path)
        if route.startswith("/actions/artifacts/"):
            return self.artifact_bytes[int(route.split("/")[3])]
        if route.startswith("/releases/assets/"):
            return self.asset_bytes[int(route.split("/")[3])]
        raise AssertionError(("DOWNLOAD", route))

    def _failure(self, step, when):
        if self.fail == (step, when):
            self.fail = None
            raise release.APIError(502, "injected " + step + " " + when)

    def add_draft(self):
        self.releases[50] = {"id": 50, "tag_name": TAG, "target_commitish": COMMIT, "name": TAG,
                             "draft": True, "immutable": False, "prerelease": False,
                             "body": "Operator acceptance notes"}
        return self.releases[50]

    def publish_release(self, release_id=50):
        item = self.releases[release_id]
        if item["draft"]:
            item.update(draft=False, immutable=self.immutability.get("enabled") is True)
        return item

    def add_asset(self, name, data=b"", state="uploaded", release_id=50):
        self.next_id += 1
        asset = {"id": self.next_id, "release_id": release_id, "name": name, "state": state,
                 "digest": "sha256:" + release.sha256(data), "size": len(data)}
        self.assets[asset["id"]] = asset
        self.asset_bytes[asset["id"]] = data
        return asset

    def send(self, method, path, data=None, content_type="application/json"):
        route = self._record(method, path)
        if method == "POST" and route == "/releases":
            step = "draft"
        elif method == "POST" and "/assets?" in route:
            step = parse_qs(urlsplit(route).query)["name"][0]
        elif method == "PATCH":
            step = "publish"
        elif method == "DELETE":
            step = "delete"
        else:
            raise AssertionError((method, route))
        self._failure(step, "before")
        if step != "draft":
            release_id = (self.assets[int(route.split("/")[3])]["release_id"] if step == "delete"
                          else int(route.split("/")[2]))
            if self.releases[release_id].get("immutable") is True:
                raise release.APIError(422, path)
        self.writes.append((step, copy.deepcopy(data)))
        if step == "draft":
            result = self.add_draft()
            result.update(data)
        elif step == "publish":
            result = self.releases[int(route.split("/")[2])]
            if data.get("draft") is False:
                self.publish_release(result["id"])
            result.update(data)
        elif step == "delete":
            asset_id = int(route.split("/")[3])
            del self.assets[asset_id]
            del self.asset_bytes[asset_id]
            result = None
        else:
            release_id = int(route.split("/")[2])
            assert not any(item["name"] == step for item in self.assets.values())
            result = self.add_asset(step, data, release_id=release_id)
        self._failure(step, "after")
        return copy.deepcopy(result)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="native release ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "assets"
        self.native = native_files()
        self.api = FakeGitHub(self.native)

    def verify(self, **changes):
        arguments = dict(api=self.api, repository=REPOSITORY, source_run=10, tag=TAG, publish=True,
                         workflow_ref=WORKFLOW_REF, workflow_sha=WORKFLOW_SHA, output=self.output)
        arguments.update(changes)
        result = release.verify(**arguments)
        self.asset_digests = result["asset_digests"]
        return result

    def publish(self):
        return release.publish_bundle(self.api, REPOSITORY, self.output, self.asset_digests)

    def files(self, output=None):
        return {path.name: path.read_bytes() for path in (output or self.output).iterdir()}

    def verify_again(self, **changes):
        return self.verify(output=self.root / "recovered", **changes)

    def frozen_draft(self):
        self.verify()
        self.api.add_draft()
        self.api.add_asset(release.RECEIPT, (self.output / release.RECEIPT).read_bytes())

    def assert_no_writes(self, function, pattern):
        before = copy.deepcopy(self.api.writes)
        with self.assertRaisesRegex((release.ReleaseError, ValueError), pattern):
            function()
        self.assertEqual(self.api.writes, before)

    def test_first_publication_order_fields_checksums_and_notes(self):
        outputs = self.verify()
        self.assertEqual(self.api.writes, [])
        self.assertEqual(self.publish(), {"published": "true", "release_id": "50", "tag": TAG})
        self.assertIs(self.api.releases[50]["immutable"], True)
        self.assertEqual([step for step, _ in self.api.writes],
                         ["draft", release.RECEIPT, ARCHIVE, NATIVE, release.SUMS, "publish"])
        self.assertEqual(self.api.releases[50]["body"], "Operator acceptance notes")
        files = self.files()
        receipt = json.loads(files[release.RECEIPT])
        self.assertEqual(set(receipt), {"schema", "plugin_id", "version", "plugin_api", "compatibility",
                                      "tag", "commit", "archives", "ci", "workflow", "reproduction"})
        self.assertEqual((receipt["schema"], receipt["plugin_id"], receipt["version"], receipt["plugin_api"]),
                         (1, "codex", "0.2.0", 1))
        self.assertEqual(receipt["ci"], {"run_id": 10, "run_attempt": 1,
                                        "artifacts": [{"id": 20, "digest": self.api.artifacts[20]["digest"]}]})
        self.assertEqual(receipt["workflow"], {"ref": WORKFLOW_REF, "sha": WORKFLOW_SHA})
        self.assertEqual(receipt["reproduction"], "ci-artifact-promotion")
        self.assertEqual(receipt["archives"], [dict(release.file_record(ARCHIVE, files[ARCHIVE]),
            native_receipt=release.file_record(NATIVE, files[NATIVE]))])
        self.assertEqual(files[release.RECEIPT], release.canonical(receipt))
        self.assertEqual(json.loads(outputs["asset_digests"]), {name: release.sha256(data) for name, data in files.items()})
        self.assertEqual(files[release.SUMS], release.checksums({name: data for name, data in files.items()
                                                              if name != release.SUMS}))
        self.assertEqual({item["name"]: self.api.asset_bytes[item["id"]] for item in self.api.assets.values()}, files)

    def test_failures_before_and_after_every_publication_step_are_recoverable(self):
        self.verify()
        expected = self.files()
        for step in ("draft", release.RECEIPT, NATIVE, ARCHIVE, release.SUMS, "publish"):
            for when in ("before", "after"):
                with self.subTest(step=step, when=when):
                    self.api = FakeGitHub(self.native)
                    self.api.fail = (step, when)
                    with self.assertRaises(release.APIError):
                        self.publish()
                    self.assertEqual(self.publish()["published"], "true")
                    self.assertEqual({item["name"]: self.api.asset_bytes[item["id"]]
                                      for item in self.api.assets.values()}, expected)

    def test_partial_upload_then_ci_rerun_recovers_identical_frozen_bundle(self):
        self.verify()
        original = self.files()
        self.api.fail = (ARCHIVE, "before")
        with self.assertRaises(release.APIError):
            self.publish()
        self.api.rerun_ci(native_files(payload=b"new CI bytes"))
        self.api.runs[10]["conclusion"] = "failure"
        self.api.calls.clear()
        self.verify_again(source_run=999, workflow_ref=WORKFLOW_REF + "-updated", workflow_sha="d" * 40)
        self.assertEqual(self.files(self.root / "recovered"), original)
        self.assertIn(("GET", API_ROOT + "/actions/runs/10/attempts/1"), self.api.calls)
        self.assertIn(("DOWNLOAD", API_ROOT + "/actions/artifacts/20/zip"), self.api.calls)
        self.assertFalse(any(path.endswith("/actions/runs/10") or "/attempts/2" in path
                             or "/actions/runs/999" in path for _, path in self.api.calls))
        self.output = self.root / "recovered"
        self.publish()
        self.assertEqual([name for name, _ in self.api.writes].count(release.RECEIPT), 1)

    def test_recovery_refuses_invalid_or_missing_historical_attempt(self):
        self.frozen_draft()
        for field, value in (("event", "workflow_dispatch"), ("head_branch", "other"),
                             ("head_sha", "d" * 40), ("path", ".github/workflows/other.yml"),
                             ("head_repository", {"full_name": "fork/plugin"}),
                             ("conclusion", "failure"), ("status", "in_progress"),
                             ("id", 99), ("run_attempt", 99)):
            with self.subTest(field=field), patch.dict(self.api.attempts[10, 1], {field: value}):
                self.assert_no_writes(self.verify_again, "CI must|Recorded CI attempt")
        del self.api.attempts[10, 1]
        self.assert_no_writes(self.verify_again, "Cannot validate recorded CI attempt.*404")

    def test_recovery_refuses_artifact_outside_recorded_attempt(self):
        self.frozen_draft()
        self.api.artifacts[20]["created_at"] = "2026-01-02T00:05:00Z"
        self.assert_no_writes(self.verify_again, "not created within the recorded CI attempt")

    def test_starters_at_every_upload_position_are_replaced_only_in_drafts(self):
        self.verify()
        files = self.files()
        for name in (release.RECEIPT, ARCHIVE, NATIVE, release.SUMS):
            with self.subTest(name=name):
                self.api = FakeGitHub(self.native)
                self.api.add_draft()
                if name != release.RECEIPT:
                    self.api.add_asset(release.RECEIPT, files[release.RECEIPT])
                self.api.add_asset(name, b"partial", state="starter")
                self.publish()
                self.assertIn("delete", [step for step, _ in self.api.writes])
                self.assertEqual({item["name"]: self.api.asset_bytes[item["id"]]
                                  for item in self.api.assets.values()}, files)

    def test_starter_deletion_failure_before_and_after_is_recoverable(self):
        self.frozen_draft()
        for when in ("before", "after"):
            with self.subTest(when=when):
                self.api.add_asset(ARCHIVE, state="starter")
                self.api.fail = ("delete", when)
                with self.assertRaises(release.APIError):
                    self.publish()
                self.publish()
                self.api = FakeGitHub(self.native)
                self.api.add_draft()
                self.api.add_asset(release.RECEIPT, self.files()[release.RECEIPT])

    def test_completed_conflicting_digest_size_or_state_is_never_replaced(self):
        self.verify()
        for name in (release.RECEIPT, ARCHIVE, NATIVE, release.SUMS):
            for field, value in (("digest", "sha256:" + "0" * 64), ("size", 999), ("state", "unknown")):
                with self.subTest(name=name, field=field):
                    self.api = FakeGitHub(self.native)
                    self.api.add_draft()
                    self.api.add_asset(name, self.files()[name])[field] = value
                    self.assert_no_writes(self.publish, "conflicts")

    def test_expired_or_missing_recorded_artifact_reports_explicit_recovery(self):
        self.frozen_draft()
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.api.artifacts[20]["expired"] = True
                if missing:
                    del self.api.artifacts[20]
                self.assert_no_writes(self.verify_again, "delete the unpublished draft.*fresh successful CI")

    def test_published_rerun_needs_no_ci_retention_and_performs_no_writes(self):
        self.verify()
        expected = self.files()
        self.publish()
        self.api.artifacts.clear()
        self.api.attempts.clear()
        self.api.calls.clear()
        self.api.writes.clear()
        self.verify_again(source_run=999, workflow_sha="d" * 40)
        self.assertEqual(self.files(self.root / "recovered"), expected)
        self.output = self.root / "recovered"
        self.assertEqual(self.publish()["published"], "true")
        self.assertEqual(self.api.writes, [])
        self.assertFalse(any("/actions/" in path for _, path in self.api.calls))

    def test_published_assets_cannot_be_incomplete_conflicting_or_unexpected(self):
        self.verify()
        self.publish()
        self.api.writes.clear()
        original = copy.deepcopy(self.api.assets)
        for change in ("starter", "missing", "unexpected", "digest"):
            with self.subTest(change=change):
                self.api.assets = copy.deepcopy(original)
                asset = next(iter(self.api.assets.values()))
                if change == "starter":
                    asset["state"] = "starter"
                elif change == "missing":
                    del self.api.assets[asset["id"]]
                elif change == "unexpected":
                    self.api.add_asset("unexpected")
                else:
                    asset["digest"] = "sha256:" + "0" * 64
                self.assert_no_writes(self.publish, "incomplete|conflicts|unexpected")

    def test_repository_immutability_must_be_verifiable_and_enabled(self):
        self.verify()
        for enabled in (False, None):
            with self.subTest(enabled=enabled):
                self.api.immutability["enabled"] = enabled
                self.assert_no_writes(self.publish, "Enable release immutability")
        original = self.api.get
        def get(path):
            if path.endswith("/immutable-releases"):
                raise release.APIError(403, path)
            return original(path)
        with patch.object(self.api, "get", side_effect=get):
            self.assert_no_writes(self.publish, "Cannot verify repository release immutability")

    def test_public_but_mutable_release_is_refused_even_after_setting_enabled(self):
        self.verify()
        self.api.immutability["enabled"] = False
        self.api.add_draft()
        self.api.publish_release()
        self.api.immutability["enabled"] = True
        self.assert_no_writes(self.publish, "public but mutable")
        self.assert_no_writes(self.verify_again, "public but mutable")

    def test_publish_requires_immutable_true_in_publication_response(self):
        self.verify()
        original = self.api.send
        def send(method, path, data=None, content_type="application/json"):
            result = original(method, path, data, content_type)
            if method == "PATCH":
                result["immutable"] = False
            return result
        with patch.object(self.api, "send", side_effect=send):
            with self.assertRaisesRegex(release.ReleaseError, "public but mutable"):
                self.publish()

    def test_publication_race_is_blocked_by_immutable_release_server(self):
        self.verify()
        self.api.add_draft()
        original = self.api.send
        def send(method, path, data=None, content_type="application/json"):
            if method == "POST" and "/assets?" in path:
                self.api.publish_release()
            return original(method, path, data, content_type)
        with patch.object(self.api, "send", side_effect=send), self.assertRaises(release.APIError):
            self.publish()
        self.assertEqual(self.api.assets, {})

    def test_tag_signature_annotation_and_exact_target_are_required(self):
        for field, value, pattern in (("tag_type", "commit", "annotated"),
                                     ("verified", False, "signature"), ("reason", "unknown_key", "signature"),
                                     ("tag_commit", "d" * 40, "CI must")):
            with self.subTest(field=field), patch.object(self.api, field, value):
                self.assert_no_writes(self.verify, pattern)

    def test_tag_move_after_verification_is_refused(self):
        self.verify()
        self.api.tag_commit = "d" * 40
        self.assert_no_writes(self.publish, "tag moved")

    def test_manifest_version_plugin_api_and_archive_declarations_are_validated(self):
        for manifest in (MANIFEST.replace(b"0.2.0", b"0.3.0"),
                         MANIFEST.replace(b"plugin_api = 1", b"plugin_api = 0"),
                         MANIFEST.replace(b"plugin_api = 1", b"plugin_api = true"),
                         MANIFEST.replace(b"plugin_api = 1\n", b""),
                         MANIFEST.replace(ARCHIVE.encode(), b"../unsafe.zip")):
            with self.subTest(manifest=manifest), patch.object(self.api, "manifest", manifest):
                self.assert_no_writes(self.verify, "Manifest")

    def test_latest_ci_run_identity_attempt_and_artifact_are_checked(self):
        for field, value in (("event", "workflow_dispatch"), ("head_branch", "other"),
                             ("path", ".github/workflows/other.yml"), ("head_sha", "d" * 40),
                             ("head_repository", {"full_name": "fork/plugin"}),
                             ("status", "in_progress"), ("conclusion", "failure")):
            with self.subTest(field=field), patch.dict(self.api.runs[10], {field: value}):
                self.assert_no_writes(self.verify, "CI must|Latest CI attempt")
        self.api.rerun_ci(self.native)
        self.api.artifacts[21]["created_at"] = "2026-01-01T00:05:00Z"
        self.assert_no_writes(self.verify, "exactly one named CI artifact")

    def test_artifact_id_digest_ownership_and_download_bytes_are_checked(self):
        for field, value in (("id", 99), ("digest", "bad"), ("expired", True),
                             ("workflow_run", {"id": 11, "head_sha": COMMIT})):
            with self.subTest(field=field), patch.dict(self.api.artifacts[20], {field: value}):
                self.assert_no_writes(self.verify, "digest|expired|another|404|exactly one")
        self.api.artifact_bytes[20] += b"tampered"
        self.assert_no_writes(self.verify, "Downloaded CI artifact digest mismatch")

    def test_native_receipt_inventory_and_manifest_are_checked_as_data(self):
        for change in ("inventory", "manifest", "receipt", "name"):
            with self.subTest(change=change):
                files = native_files(manifest=MANIFEST + b"\n# different bytes\n") if change == "manifest" else native_files()
                if change == "inventory":
                    receipt = json.loads(files[NATIVE])
                    receipt["files"]["bin/tool"] = "0" * 64
                    files[NATIVE] = release.canonical(receipt)
                elif change == "receipt":
                    files[NATIVE] = b"{}"
                self.api = FakeGitHub(files)
                if change == "name":
                    self.api.artifacts[20]["name"] = "another-name"
                with self.assertRaises((ValueError, KeyError)):
                    self.verify()
                self.assertEqual(self.api.writes, [])

    def test_multiple_archives_record_every_artifact_and_native_receipt(self):
        name = "codex-plugin-macos-x86_64.zip"
        manifest = MANIFEST.replace(b'architectures = ["arm64"]\n', b'architectures = ["arm64", "x86_64"]\n', 1)
        manifest += (b'[[compatibility.artifacts]]\nname = "codex-plugin-macos-x86_64.zip"\n'
                     b'platforms = ["macos"]\narchitectures = ["x86_64"]\n')
        self.api = FakeGitHub(native_files(manifest=manifest))
        self.api.manifest = manifest
        self.api.install_artifact(19, native_files(manifest=manifest, name=name, architecture="x86_64"))
        self.verify()
        receipt = json.loads(self.files()[release.RECEIPT])
        self.assertEqual([item["id"] for item in receipt["ci"]["artifacts"]], [19, 20])
        self.assertEqual([item["name"] for item in receipt["archives"]], sorted([name, ARCHIVE]))
        self.publish()
        self.assertEqual(len(self.api.assets), 6)

    def test_duplicate_unexpected_assets_and_draft_target_conflicts_are_refused(self):
        self.verify()
        self.api.add_draft()
        self.api.releases[50]["target_commitish"] = "d" * 40
        self.assert_no_writes(self.publish, "target differs")
        self.api.releases[50]["target_commitish"] = COMMIT
        self.api.add_asset("unexpected")
        self.assert_no_writes(self.publish, "unexpected")
        self.api.add_asset("unexpected")
        self.assert_no_writes(self.publish, "Duplicate")

    def test_bundle_tampering_extra_file_and_checksum_mismatch_are_refused(self):
        self.verify()
        original = self.files()
        for name in (ARCHIVE, NATIVE, release.RECEIPT, release.SUMS, "extra"):
            with self.subTest(name=name):
                path = self.output / name
                path.write_bytes(b"tampered")
                self.assert_no_writes(self.publish, "verify job's digests")
                if name in original:
                    path.write_bytes(original[name])
                else:
                    path.unlink()
        (self.output / release.SUMS).write_bytes(b"bad sums")
        self.asset_digests = json.dumps({name: release.sha256(data) for name, data in self.files().items()})
        self.assert_no_writes(self.publish, "checksums differ")

    def test_upload_response_digest_mismatch_prevents_publication(self):
        self.verify()
        original = self.api.send
        def send(method, path, data=None, content_type="application/json"):
            result = original(method, path, data, content_type)
            if "/assets?" in path:
                result["digest"] = "sha256:" + "0" * 64
            return result
        with patch.object(self.api, "send", side_effect=send), self.assertRaisesRegex(release.ReleaseError, "conflicts"):
            self.publish()
        self.assertTrue(self.api.releases[50]["draft"])
        self.assertEqual([name for name, _ in self.api.writes], ["draft", release.RECEIPT])

    def test_dry_run_checks_native_bytes_without_tags_writes_or_catalog(self):
        self.api.tag_type = "commit"
        self.api.verified = False
        self.verify(publish=False, tag="")
        receipt = json.loads(self.files()[release.RECEIPT])
        self.assertIsNone(receipt["tag"])
        self.assertEqual(self.api.writes, [])
        self.assertFalse(any("/git/" in path for _, path in self.api.calls))
        self.assert_no_writes(self.publish, "untagged dry-run")

    def test_dry_run_cli_reports_publication_conditions(self):
        arguments = [str(SCRIPT), "verify", "--repository", REPOSITORY, "--source-run", "10", "--publish", "false",
                     "--workflow-ref", WORKFLOW_REF, "--workflow-sha", WORKFLOW_SHA, "--output", str(self.output)]
        output = io.StringIO()
        with patch.object(sys, "argv", arguments), patch.dict(os.environ, {"GH_TOKEN": "fake"}), \
                patch.object(release, "GitHub", return_value=self.api), redirect_stdout(output):
            self.assertEqual(release.main(), 0)
        self.assertIn("signed annotated v0.2.0", output.getvalue())
        self.assertIn("immutable published Release", output.getvalue())
        self.assertEqual(self.api.writes, [])

    def test_receipt_validation_rejects_noncanonical_or_invalid_provenance(self):
        self.verify()
        data = self.files()[release.RECEIPT]
        receipt = json.loads(data)
        self.assertEqual(release.validate_receipt(data), receipt)
        with self.assertRaises(release.ReleaseError):
            release.validate_receipt(data.rstrip())
        for key, value in (("schema", True), ("reproduction", "rebuild"), ("plugin_api", True),
                           ("ci", {"run_id": 10, "run_attempt": 1, "artifacts": []}),
                           ("workflow", {"ref": "invalid", "sha": WORKFLOW_SHA})):
            with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                release.validate_receipt(release.canonical(dict(receipt, **{key: value})))


class ReleaseWorkflowTests(unittest.TestCase):
    def test_job_graph_permissions_and_frozen_output_checks(self):
        spec = importlib.util.spec_from_file_location("workflow_check", ROOT / "scripts/check-workflow.py")
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        self.assertTrue(checker.check_release_workflow(ROOT)["release_workflow_verified"])
        source = WORKFLOW.read_text()
        mutations = [
            ("      contents: read", "      contents: write"),
            ("    if: inputs.publish\n", "    if: always()\n"),
            ("needs.verify.outputs.artifact_id", "github.run_attempt"),
            ("needs.verify.outputs.asset_digests", "inputs.asset_digests"),
            ("needs.publish.outputs.published == 'true'", "always()"),
            ("helper.is_symlink()", "False"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / ".github/workflows/release.yml"
            target.parent.mkdir(parents=True)
            for before, after in mutations:
                with self.subTest(before=before):
                    target.write_text(source.replace(before, after))
                    with self.assertRaises(ValueError):
                        checker.check_release_workflow(root)

    def test_publish_only_retry_uses_original_artifact_id_and_digests(self):
        case = ReleaseTests()
        case.setUp()
        self.addCleanup(case.doCleanups)
        case.verify()
        expected = case.files()
        artifact_id = "901"
        case.api.artifact_bytes[901] = zip_bytes({"plugin_release.py": SCRIPT.read_bytes(),
            **{"assets/" + name: data for name, data in expected.items()}})
        job = workflow_job("publish")
        self.assertIn("artifact-ids: ${{ needs.verify.outputs.artifact_id }}", job)
        self.assertNotIn("github.run_attempt", job)
        script = python_step("publish")
        for attempt in (1, 2):
            runner = case.root / ("publisher-" + str(attempt))
            bundle = runner / "plugin-release"
            bundle.mkdir(parents=True)
            data = case.api.download(API_ROOT + "/actions/artifacts/" + artifact_id + "/zip")
            for name, content in release.zip_entries(data).items():
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            def run_helper(arguments, check):
                self.assertTrue(check)
                self.assertEqual(arguments[:3], [sys.executable, "-I", str(bundle / "plugin_release.py")])
                with patch.object(sys, "argv", arguments[2:]), patch.object(release, "GitHub", return_value=case.api):
                    status = release.main()
                if status:
                    raise subprocess.CalledProcessError(status, arguments)
            environment = {"RUNNER_TEMP": str(runner), "GH_TOKEN": "fake", "GH_REPOSITORY": REPOSITORY,
                           "GITHUB_OUTPUT": str(runner / "output"), "GITHUB_RUN_ATTEMPT": str(attempt),
                           "RELEASE_HELPER_DIGEST": release.sha256(SCRIPT.read_bytes()),
                           "RELEASE_ASSET_DIGESTS": case.asset_digests}
            with patch.dict(os.environ, environment), patch.object(subprocess, "run", side_effect=run_helper), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                if attempt == 1:
                    case.api.fail = (release.SUMS, "before")
                    with self.assertRaises(subprocess.CalledProcessError):
                        exec(compile(script, str(WORKFLOW), "exec"), {})
                else:
                    exec(compile(script, str(WORKFLOW), "exec"), {})
                    self.assertIn("published=true", (runner / "output").read_text())
        self.assertEqual({item["name"]: case.api.asset_bytes[item["id"]]
                          for item in case.api.assets.values()}, expected)

    def test_publish_rejects_changed_helper_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "plugin-release"
            root.mkdir()
            (root / "plugin_release.py").write_bytes(b"unverified helper")
            environment = {"RUNNER_TEMP": directory, "RELEASE_HELPER_DIGEST": release.sha256(SCRIPT.read_bytes())}
            with patch.dict(os.environ, environment), patch.object(subprocess, "run") as run:
                with self.assertRaisesRegex(SystemExit, "helper differs"):
                    exec(compile(python_step("publish"), str(WORKFLOW), "exec"), {})
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
