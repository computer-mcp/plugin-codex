"""Argument and evidence validation for the public-host runtime acceptance driver."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-host.py"
spec = importlib.util.spec_from_file_location("host_acceptance", SCRIPT)
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class HostAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.executable = self.root / "executable with spaces"
        self.executable.write_text("#!/bin/sh\nexit 99\n")
        self.executable.chmod(0o700)
        self.arguments = ["--host", str(self.executable), "--adapter", str(self.executable),
                          "--codex", str(self.executable), "--output-directory", str(self.root / "output")]

    def invalid(self, arguments):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            acceptance.parse_arguments(arguments)
        self.assertEqual(error.exception.code, 2)
        self.assertFalse((self.root / "output").exists(), "Parsing must not create runtime state")

    def test_fixture_arguments_do_not_launch_or_create_state(self):
        parsed = acceptance.parse_arguments(self.arguments + ["--mode", "fixture"])
        self.assertEqual(parsed.host, self.executable)
        self.assertEqual(parsed.mode, "fixture")
        self.assertFalse(parsed.output_directory.exists())

    def test_full_requires_explicit_authentication_and_model(self):
        self.invalid(self.arguments)
        auth = self.root / "auth.json"
        auth.write_text("{}")
        self.invalid(self.arguments + ["--auth-file", str(auth)])
        self.invalid(self.arguments + ["--model", "selected-model"])
        parsed = acceptance.parse_arguments(self.arguments + ["--auth-file", str(auth), "--model", "selected-model"])
        self.assertEqual(parsed.mode, "full")
        self.invalid(self.arguments + ["--auth-file", str(auth), "--model", "  "])
        self.invalid(self.arguments + ["--auth-file", str(auth), "--model", "bad\nmodel"])
        self.invalid(self.arguments + ["--mode", "fixture", "--auth-file", str(auth)])
        self.invalid(self.arguments + ["--mode", "fixture", "--model", "unused"])

    def test_inputs_reject_relative_missing_directory_and_nonexecutable(self):
        unavailable = self.root / "unavailable"
        unavailable.write_text("not executable")
        for flag in ("--host", "--adapter", "--codex"):
            for path in ("relative", str(self.root / "missing"), str(self.root), str(unavailable)):
                with self.subTest(flag=flag, path=path):
                    self.invalid(self.arguments + ["--mode", "fixture", flag, path])
        self.invalid(self.arguments + ["--auth-file", "relative", "--model", "model"])

    def test_output_must_be_new_and_absolute_even_for_dangling_symlink(self):
        link = self.root / "link"
        link.symlink_to(self.root / "absent")
        for path in ("relative", str(self.root), str(self.executable), str(link)):
            with self.subTest(path=path):
                self.invalid(self.arguments + ["--mode", "fixture", "--output-directory", path])

    def test_timeout_is_bounded(self):
        for value in ("0", "-1", "901", "nan", "1.5"):
            self.invalid(self.arguments + ["--mode", "fixture", "--timeout-seconds", value])
        for value in (1, 900):
            parsed = acceptance.parse_arguments(self.arguments + ["--mode", "fixture", "--timeout-seconds", str(value)])
            self.assertEqual(parsed.timeout_seconds, value)

    def test_nested_tool_errors_cannot_be_success(self):
        payload = {"thread": {"id": "native"}}
        result = {"isError": False, "structuredContent": {"result": payload}}
        indirect = {"structuredContent": {"result": result}}
        self.assertEqual(acceptance.unwrap(result), payload)
        self.assertEqual(acceptance.unwrap(indirect, indirect=True), payload)
        for failure in ({"isError": True, "content": []},
                        {"structuredContent": {"result": {"isError": True}}}):
            with self.assertRaises(RuntimeError):
                acceptance.unwrap(failure, indirect="structuredContent" in failure)

    def test_archive_requires_success_or_exact_missing_rollout_identity(self):
        success = {"structuredContent": {"result": {}}}
        self.assertEqual(acceptance.archive_disposition(success, "thread-1"), "archived")
        for detail in ("no rollout found for thread id thread-1", "native error: no rollout found for thread id thread-1"):
            result = {"isError": True, "structuredContent": {"error": {"message": detail}}}
            self.assertEqual(acceptance.archive_disposition(result, "thread-1"), "already-absent")
        for detail in (None, "", "no rollout found for thread id thread-2", "no rollout found for thread id thread-1-extra",
                       "no rollout found for thread id thread-1; denied", "thread not found", "permission denied"):
            result = {"isError": True, "structuredContent": {"error": {"message": detail}}}
            self.assertEqual(acceptance.archive_disposition(result, "thread-1"), "failed")
        for thread in ("", "thread with space", "thread\n1", None):
            self.assertEqual(acceptance.archive_disposition(success, thread), "failed")
        self.assertEqual(acceptance.archive_disposition({}, "thread-1"), "failed")

    def test_turn_completion_must_match_thread_turn_and_terminal_state(self):
        payload = {"method": "turn/completed", "params": {"threadId": "thread", "turn": {"id": "turn", "status": "completed"}}}
        page = {"missed_events": 0, "events": [{"payload": payload}]}
        self.assertTrue(acceptance.completed_turn(page, "thread", "turn", "completed"))
        self.assertFalse(acceptance.completed_turn(page, "sibling", "turn", "completed"))
        self.assertFalse(acceptance.completed_turn(page, "thread", "other", "completed"))
        with self.assertRaises(AssertionError):
            acceptance.completed_turn(page, "thread", "turn", "interrupted")
        page["missed_events"] = 1
        with self.assertRaises(AssertionError):
            acceptance.completed_turn(page, "thread", "turn", "completed")

    def test_command_status_is_evidence_not_a_substring_success(self):
        self.assertEqual(acceptance.command_exit("Process exited with code 0\nOutput: ok"), 0)
        self.assertEqual(acceptance.command_exit("Process exited with code -9"), -9)
        with self.assertRaises(AssertionError):
            acceptance.command_exit("No command ran")

    def test_failure_injection_requires_owned_descendant(self):
        parents = {5: 4, 4: 3, 3: 2, 9: 9}
        self.assertTrue(acceptance.descendant(5, 3, parents.get))
        for pid in (3, 1, 9, 100, None):
            self.assertFalse(acceptance.descendant(pid, 3, parents.get))
        self.assertFalse(acceptance.descendant(5, 8, parents.get))
        self.assertFalse(acceptance.descendant(100, 2, lambda value: value - 1))

    def failed_authenticated_fixture(self):
        auth = self.root / "fake-auth.json"
        auth.write_text('{"fake_credential":"unit-test-only"}')
        options = acceptance.parse_arguments(self.arguments + ["--auth-file", str(auth), "--model", "fake-model"])
        return acceptance.Fixture(options)

    def run_authenticated_failure(self, fixture):
        copied_auth = fixture.home / "auth.json"
        output = io.StringIO()

        def fail_configuration(*args, **kwargs):
            self.assertEqual(copied_auth.read_text(), fixture.options.auth_file.read_text())
            raise RuntimeError("Authenticated run failed")

        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(acceptance, "Fixture", return_value=fixture))
            stack.enter_context(patch.object(acceptance.subprocess, "run", return_value=Mock(stdout="fake-version")))
            launch = stack.enter_context(patch.object(acceptance.subprocess, "Popen",
                                                      side_effect=AssertionError("Unexpected process launch")))
            for phase in ("setup", "catalog_and_diagnostics", "directories", "native_permissions", "handoff",
                          "sibling_workspace", "recovery", "app_lifecycle", "exec_lifecycle", "host_callbacks"):
                stack.enter_context(patch.object(fixture, phase))
            configure = stack.enter_context(patch.object(fixture, "configure", side_effect=fail_configuration))
            stack.enter_context(contextlib.redirect_stdout(output))
            self.assertEqual(acceptance.run(fixture.options), 1)
            configure.assert_called_once()
            launch.assert_not_called()
        self.assertFalse(copied_auth.exists())
        self.assertEqual(fixture.options.auth_file.read_text(), '{"fake_credential":"unit-test-only"}')
        report = json.loads((fixture.root / "report.json").read_text())
        summary = json.loads(output.getvalue())
        self.assertFalse(report["passed"])
        self.assertFalse(summary["passed"])
        self.assertEqual(report["failure"], "Authenticated run failed")
        self.assertEqual(summary["failure"], report["failure"])
        self.assertEqual(summary["cleanup_errors"], report["cleanup_errors"])
        return report

    def test_credential_recreated_during_process_exit_wait_is_removed(self):
        fixture = self.failed_authenticated_fixture()
        copied_auth = fixture.home / "auth.json"

        def refresh_credential(*args, **kwargs):
            self.assertFalse(copied_auth.exists())
            copied_auth.write_text('{"fake_credential":"refreshed-unit-test-only"}')
            return True

        with patch.object(acceptance, "wait_until", side_effect=refresh_credential) as wait:
            report = self.run_authenticated_failure(fixture)
        wait.assert_called_once()
        self.assertEqual(report["cleanup_errors"], [])

    def test_malformed_launch_receipt_removes_copied_auth_and_reports_failure(self):
        fixture = self.failed_authenticated_fixture()
        (fixture.root / "launches.jsonl").write_text("{malformed receipt}\n")
        with patch.object(acceptance, "wait_until", return_value=True) as wait:
            report = self.run_authenticated_failure(fixture)
        wait.assert_called_once()
        self.assertEqual(len(report["cleanup_errors"]), 1)
        self.assertIn("Launch receipts: Expecting property name", report["cleanup_errors"][0])
        self.assertTrue(report["binary_digests_unchanged"])

    def test_unreadable_launch_receipt_removes_copied_auth_and_reports_failure(self):
        fixture = self.failed_authenticated_fixture()
        (fixture.root / "launches.jsonl").mkdir()
        report = self.run_authenticated_failure(fixture)
        self.assertEqual(len(report["cleanup_errors"]), 1)
        self.assertIn("Launch receipts:", report["cleanup_errors"][0])

    def test_raising_teardown_steps_run_independently_after_credential_removal(self):
        fixture = self.failed_authenticated_fixture()
        fixture.hosts = [Mock(log=Mock(closed=False)), Mock(log=Mock(closed=False))]
        fixture.model = Mock()
        fixture.model_log = Mock()
        (fixture.root / "launches.jsonl").write_text(json.dumps({"pid": 123, "cwd": str(fixture.root / "primary")}) + "\n")

        def failure(message):
            def raise_after_removal(*args, **kwargs):
                self.assertFalse((fixture.home / "auth.json").exists())
                raise RuntimeError(message)
            return raise_after_removal

        actions = [(host.close, f"host {index} failed") for index, host in enumerate(fixture.hosts)]
        actions += [(fixture.model.stdin.close, "stdin failed"), (fixture.model.wait, "model wait failed"),
                    (fixture.model_log.close, "model log failed")]
        for action, message in actions:
            action.side_effect = failure(message)
        with patch.object(acceptance, "wait_until", side_effect=failure("process exit check failed")) as wait:
            report = self.run_authenticated_failure(fixture)
        wait.assert_called_once()
        self.assertEqual(fixture.pids, {123})
        self.assertEqual(len(report["cleanup_errors"]), len(actions) + 1)
        for action, message in actions:
            action.assert_called_once()
            self.assertTrue(any(message in error for error in report["cleanup_errors"]))
        self.assertIn("process exit check failed", report["cleanup_errors"])

    def test_raising_cleanup_and_digest_check_still_emit_failure_report(self):
        fixture = self.failed_authenticated_fixture()

        def teardown():
            self.assertFalse((fixture.home / "auth.json").exists())
            (fixture.home / "auth.json").write_text('{"fake_credential":"refreshed-unit-test-only"}')
            self.executable.unlink()
            raise RuntimeError("Fixture teardown failed")

        with patch.object(fixture, "cleanup", side_effect=teardown) as cleanup:
            report = self.run_authenticated_failure(fixture)
        cleanup.assert_called_once()
        self.assertFalse(report["binary_digests_unchanged"])
        self.assertEqual(len(report["cleanup_errors"]), 2)
        self.assertEqual(report["cleanup_errors"][0], "Fixture cleanup: Fixture teardown failed")
        self.assertIn("Binary digest verification:", report["cleanup_errors"][1])


if __name__ == "__main__":
    unittest.main()
