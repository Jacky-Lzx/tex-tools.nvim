"""Regression checks for failure reporting, registration and process isolation."""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run import environment, execute, main, validate


class RunnerChecks(unittest.TestCase):
    def manifest(self, root, cases):
        (root / "tests").mkdir(exist_ok=True)
        (root / "tests/case.py").write_text("# Registered fixture\n")
        return {
            "version": 1,
            "default": ["unit"],
            "cases": [
                dict(suite="unit", files=["tests/case.py"], **case) for case in cases
            ],
        }

    def test_registration_rejects_new_missing_and_duplicate_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest(
                root, [{"name": "one", "command": [sys.executable, "tests/case.py"]}]
            )
            validate(root, manifest)
            (root / "tests/forgotten.lua").write_text("error('must be registered')\n")
            with self.assertRaisesRegex(ValueError, "Unregistered"):
                validate(root, manifest)
            manifest["manual"] = {
                "tests/forgotten.lua": "Explicit interactive acceptance fixture"
            }
            validate(root, manifest)
            (root / "tests/case.py").unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                validate(root, manifest)

    def test_missing_fixture_and_broken_case_do_not_hide_following_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest(
                root,
                [
                    {
                        "name": "fixture",
                        "command": [
                            sys.executable,
                            "-c",
                            "raise AssertionError('must not run')",
                        ],
                        "requires": ["path:{root}/missing-checkout"],
                    },
                    {
                        "name": "broken",
                        "command": [
                            sys.executable,
                            "-c",
                            "print('evidence');raise SystemExit(7)",
                        ],
                    },
                    {
                        "name": "next",
                        "command": [sys.executable, "-c", "print('completed')"],
                    },
                ],
            )
            (root / "tests/cases.json").write_text(json.dumps(manifest))
            output = root / "artifacts"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["--output", str(output)], root), 1)
            result = json.loads((output / "summary.json").read_text())["results"]
            self.assertEqual(
                [case["status"] for case in result], ["fail", "fail", "pass"]
            )
            self.assertIn("Missing required", result[0]["reason"])
            self.assertEqual(result[1]["exit_code"], 7)
            self.assertIn(
                "evidence", (Path(result[1]["directory"]) / "output.log").read_text()
            )
            self.assertIn(
                "completed", (Path(result[2]["directory"]) / "output.log").read_text()
            )
            with (
                self.assertRaises(FileExistsError),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                main(["--output", str(output)], root)

    def test_case_state_and_rpc_environment_are_isolated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inherited = dict(
                os.environ,
                NVIM="/tmp/rpc.sock",
                NVIM_APPNAME="personal",
                NVIM_BIN="custom-nvim",
            )
            first = environment(root, root / "one", {}, {}, inherited)
            second = environment(root, root / "two", {}, {}, inherited)
            self.assertNotIn("NVIM", first)
            self.assertNotIn("NVIM_APPNAME", first)
            self.assertEqual(first["NVIM_BIN"], "custom-nvim")
            for key in (
                "XDG_STATE_HOME",
                "XDG_DATA_HOME",
                "XDG_CACHE_HOME",
                "XDG_CONFIG_HOME",
                "TMPDIR",
                "NVIM_LOG_FILE",
            ):
                self.assertNotEqual(first[key], second[key])
            self.assertEqual(inherited["NVIM"], "/tmp/rpc.sock")

    def test_locked_fixtures_fail_before_tests_and_installer_preserves_existing_paths(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest(
                root, [{"name": "one", "command": [sys.executable, "tests/case.py"]}]
            )
            existing = root / "existing"
            existing.mkdir()
            (existing / "user-work").write_text("preserve this")
            manifest["fixtures"] = {
                "example": {
                    "repository": "example/example",
                    "revision": "0" * 40,
                    "path": str(existing),
                }
            }
            (root / "tests/cases.json").write_text(json.dumps(manifest))
            for arguments in (["--locked"], ["fixtures"]):
                with (
                    self.assertRaises(SystemExit),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    main(arguments, root)
            self.assertEqual((existing / "user-work").read_text(), "preserve this")
            self.assertFalse((existing / ".git").exists())

    def test_fixture_installation_publishes_the_pinned_revision_and_replays_offline(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "source", root / "installed"
            source.mkdir()
            (source / "module.lua").write_text("return { answer = 42 }\n")
            real_run = subprocess.run
            for command in (
                ["git", "init", "-q", str(source)],
                ["git", "-C", str(source), "add", "module.lua"],
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "fixture",
                ],
            ):
                real_run(command, check=True)
            revision = real_run(
                ["git", "-C", str(source), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            manifest = self.manifest(
                root, [{"name": "one", "command": [sys.executable, "tests/case.py"]}]
            )
            manifest["fixtures"] = {
                "example": {
                    "repository": "example/example",
                    "revision": revision,
                    "path": str(destination),
                }
            }
            (root / "tests/cases.json").write_text(json.dumps(manifest))
            fetches = []

            def local_transport(command, **kwargs):
                # Keep the real staging/publication path; only the transport
                # source is replaced with a local Git fixture.
                command = list(command)
                if command[-2:] == ["origin", "https://github.com/example/example.git"]:
                    command[-1] = str(source)
                if "fetch" in command:
                    fetches.append(command)
                return real_run(command, **kwargs)

            with (
                patch("run.subprocess.run", side_effect=local_transport),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(main(["fixtures"], root), 0)
                self.assertEqual(main(["fixtures"], root), 0)
            self.assertEqual(len(fetches), 1)
            self.assertEqual(
                (destination / "module.lua").read_text(), "return { answer = 42 }\n"
            )
            self.assertEqual(
                real_run(
                    ["git", "-C", str(destination), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip(),
                revision,
            )

    def test_timeout_stops_children_even_when_they_create_a_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_pid = root / "child.pid"
            program = (
                "import subprocess,sys,time;from pathlib import Path;"
                "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True);"
                "Path(sys.argv[1]).write_text(str(child.pid));time.sleep(30)"
            )
            result = execute(
                root,
                root / "case",
                {},
                {
                    "name": "timeout",
                    "suite": "unit",
                    "timeout": 0.3,
                    "command": [sys.executable, "-c", program, str(child_pid)],
                },
            )
            self.assertEqual(result["status"], "fail")
            self.assertIn("timeout", result["reason"])
            self.assertTrue(child_pid.exists(), "Child process never started")
            status = subprocess.run(
                ["ps", "-p", child_pid.read_text(), "-o", "stat="],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertTrue(
                not status.stdout.strip() or status.stdout.strip().startswith("Z"),
                status.stdout,
            )


if __name__ == "__main__":
    unittest.main()
