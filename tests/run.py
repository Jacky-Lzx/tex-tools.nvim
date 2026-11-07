"""Run explicitly registered Neovim tests with isolated state and retained failures.

Self-contained, standard-library-only test infrastructure. The same version is
vendored in sibling plugins so standalone checkouts and CI need no manager/config.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import string
import subprocess
import sys
import tempfile
import time
from pathlib import Path

VERSION = 1
ROOT = Path(__file__).resolve().parents[1]
SUFFIXES = {".lua", ".py", ".sh"}


def expand(value, root, directory, env):
    value = value.replace("{root}", str(root)).replace("{tmp}", str(directory))
    value = value.replace("{nvim}", env.get("NVIM_BIN", "nvim"))
    value = value.replace("{python}", sys.executable)
    return string.Template(value).safe_substitute(env)


def validate(root, manifest):
    if manifest.get("version") != VERSION:
        raise ValueError("Unsupported test manifest version")
    cases = manifest["cases"]
    names, registered = set(), set()
    for case in cases:
        name = case["suite"] + "/" + case["name"]
        if name in names:
            raise ValueError("Duplicate test: " + name)
        names.add(name)
        if not case.get("command") or not all(
            isinstance(s, str) for s in case["command"]
        ):
            raise ValueError("Missing command: " + name)
        if case.get("timeout", 90) <= 0:
            raise ValueError("Invalid timeout: " + name)
        for path in case["files"]:
            if not (root / path).is_file():
                raise ValueError("Registered test file is missing: " + path)
            registered.add(path)
    for category in ("support", "manual"):
        for path, reason in manifest.get(category, {}).items():
            if not reason.strip() or not (root / path).is_file():
                raise ValueError("Missing file or reason in " + category + ": " + path)
            if path in registered:
                raise ValueError("Test has two roles: " + path)
            registered.add(path)
    present = {
        p.relative_to(root).as_posix()
        for p in (root / "tests").rglob("*")
        if p.is_file()
        and p.suffix in SUFFIXES
        and not {".git", "__pycache__"}.intersection(p.parts)
    }
    present.discard("tests/run.py")
    missing = sorted(present - registered)
    if missing:
        raise ValueError(
            "Unregistered test files (add a case or an explicit support/manual reason): "
            + ", ".join(missing)
        )
    known = {case["suite"] for case in cases}
    if not set(manifest["default"]) <= known:
        raise ValueError("Unknown default suite")


def environment(root, directory, manifest, case, inherited=None):
    env = dict(os.environ if inherited is None else inherited)
    # NVIM is an RPC socket in :terminal/jobs, never the executable override.
    for key in ("NVIM", "NVIM_LISTEN_ADDRESS", "NVIM_APPNAME", "VIMINIT", "EXINIT"):
        env.pop(key, None)
    for name in ("DATA", "STATE", "CACHE", "CONFIG"):
        path = directory / name.lower()
        path.mkdir(parents=True, exist_ok=True)
        env["XDG_" + name + "_HOME"] = str(path)
    temporary = directory / "tmp"
    temporary.mkdir(parents=True, exist_ok=True)
    runtime = directory / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    env.update(
        TMPDIR=str(temporary),
        XDG_RUNTIME_DIR=str(runtime),
        NVIM_LOG_FILE=str(directory / "nvim.log"),
        NVIM_TEST_TMP=str(directory),
        PYTHONDONTWRITEBYTECODE="1",
    )
    if env.get("NVIM_BIN"):
        executable = shutil.which(env["NVIM_BIN"], path=env.get("PATH"))
        if executable:
            binaries = directory / "bin"
            binaries.mkdir(exist_ok=True)
            (binaries / "nvim").symlink_to(Path(executable).resolve())
            env["PATH"] = str(binaries) + os.pathsep + env.get("PATH", "")
    for key, value in manifest.get("defaults", {}).items():
        env.setdefault(key, expand(value, root, directory, env))
    for key, value in case.get("env", {}).items():
        env[key] = expand(value, root, directory, env)
    return env


def missing_requirements(root, directory, env, requirements):
    missing = []
    for requirement in requirements:
        kind, value = requirement.split(":", 1)
        value = expand(value, root, directory, env)
        if kind == "exe":
            exists = shutil.which(value, path=env.get("PATH")) is not None
        elif kind == "env":
            exists = bool(env.get(value))
        elif kind == "path":
            exists = Path(value).exists()
        else:
            raise ValueError("Unknown requirement: " + requirement)
        if not exists:
            missing.append(requirement + " -> " + value)
    return missing


def stop(process):
    # Descendants may create their own sessions (PTY tests do). Snapshot their
    # groups before killing the parent so they do not become untraceable orphans.
    groups = {process.pid}
    try:
        listing = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,pgid="],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        rows = [tuple(map(int, line.split())) for line in listing.stdout.splitlines()]
        owned = {process.pid}
        while True:
            children = {pid for pid, parent, _ in rows if parent in owned}
            if children <= owned:
                break
            owned.update(children)
        groups.update(group for pid, _, group in rows if pid in owned)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    for group in groups - {os.getpgrp()}:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def execute(root, directory, manifest, case):
    directory.mkdir(parents=True)
    env = environment(root, directory, manifest, case)
    command = [expand(arg, root, directory, env) for arg in case["command"]]
    record = {
        "name": case["name"],
        "suite": case["suite"],
        "command": command,
        "directory": str(directory),
        "status": "fail",
        "seconds": 0,
    }
    missing = missing_requirements(
        root, directory, env, manifest.get("requires", []) + case.get("requires", [])
    )
    if missing:
        record["reason"] = "Missing required fixtures/tools: " + "; ".join(missing)
        (directory / "output.log").write_text(record["reason"] + "\n")
        return record
    started = time.monotonic()
    try:
        with (directory / "output.log").open("wb") as log:
            process = subprocess.Popen(
                command,
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                code = process.wait(timeout=case.get("timeout", 90))
                record.update(status="pass" if code == 0 else "fail", exit_code=code)
                if code:
                    record["reason"] = "exit " + str(code)
            except subprocess.TimeoutExpired:
                stop(process)
                record["reason"] = "timeout after " + str(case.get("timeout", 90)) + "s"
            except BaseException:
                stop(process)
                raise
    except OSError as error:
        record["reason"] = str(error)
    record["seconds"] = round(time.monotonic() - started, 3)
    return record


def git(root, *args):
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def fixture_records(root, manifest):
    env = dict(os.environ)
    for key, value in manifest.get("defaults", {}).items():
        env.setdefault(key, expand(value, root, root, env))
    records = {}
    for name, fixture in manifest.get("fixtures", {}).items():
        path = Path(expand(fixture["path"], root, root, env)).resolve()
        records[name] = {
            "path": str(path),
            "expected": fixture["revision"],
            "commit": git(path, "rev-parse", "HEAD"),
            "changes": git(path, "status", "--short"),
        }
    return records


def install_fixtures(root, manifest):
    # Network access is confined to this explicitly requested operation.
    for name, fixture in manifest.get("fixtures", {}).items():
        if not re.fullmatch(
            r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", fixture["repository"]
        ) or not re.fullmatch(r"[0-9a-f]{40}", fixture["revision"]):
            raise ValueError("Invalid fixture source or revision: " + name)
        record = fixture_records(root, manifest)[name]
        path = Path(record["path"])
        if path.exists():
            if record["commit"] != record["expected"] or record["changes"]:
                raise ValueError(
                    "Refusing to replace existing fixture checkout: " + str(path)
                )
            print("Verified existing fixture: " + name, flush=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="nvim-test-fixture-", dir=path.parent
        ) as temporary:
            stage = Path(temporary) / name
            commands = [
                ["git", "init", "-q", str(stage)],
                [
                    "git",
                    "-C",
                    str(stage),
                    "remote",
                    "add",
                    "origin",
                    "https://github.com/" + fixture["repository"] + ".git",
                ],
                [
                    "git",
                    "-C",
                    str(stage),
                    "fetch",
                    "-q",
                    "--depth=1",
                    "origin",
                    fixture["revision"],
                ],
                ["git", "-C", str(stage), "checkout", "-q", "--detach", "FETCH_HEAD"],
            ]
            for command in commands:
                subprocess.run(command, check=True, timeout=180)
            if git(stage, "rev-parse", "HEAD") != fixture["revision"]:
                raise ValueError("Fixture revision mismatch: " + name)
            stage.rename(path)
        print(
            "Installed pinned fixture: " + name + " " + fixture["revision"], flush=True
        )


def main(argv=None, root=ROOT):
    manifest = json.loads((root / "tests/cases.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", nargs="?", default="default")
    parser.add_argument("--filter", default="", help="Substring of suite/name")
    parser.add_argument(
        "--list",
        action="store_true",
        help="Validate registration and list selected commands",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate registration only; never execute tests",
    )
    parser.add_argument("--keep", action="store_true")
    parser.add_argument(
        "--locked",
        action="store_true",
        help="Require the exact clean sibling revisions recorded in cases.json",
    )
    parser.add_argument(
        "--output", type=Path, help="Retain artifacts in a new directory"
    )
    arguments = list(sys.argv[1:] if argv is None else argv)
    for index, argument in enumerate(arguments):
        if argument in manifest.get("aliases", {}):
            arguments[index] = manifest["aliases"][argument]
    args = parser.parse_args(arguments)
    try:
        validate(root, manifest)
    except (KeyError, TypeError, ValueError) as error:
        parser.error(str(error))
    if args.suite == "fixtures":
        try:
            install_fixtures(root, manifest)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            parser.error(str(error))
        return 0
    known = {case["suite"] for case in manifest["cases"]}
    suites = (
        manifest["default"]
        if args.suite == "default"
        else (
            [
                s
                for s in known
                if not s.startswith(("acceptance", "benchmark", "compatibility"))
            ]
            if args.suite == "all"
            else args.suite.split(",")
        )
    )
    if not set(suites) <= known:
        parser.error("Unknown suite; available: " + ", ".join(sorted(known)))
    if args.check:
        print("Test registration passed: " + str(len(manifest["cases"])) + " cases")
        return 0
    cases = [
        case
        for case in manifest["cases"]
        if case["suite"] in suites and args.filter in case["suite"] + "/" + case["name"]
    ]
    if not cases:
        parser.error("No matching tests")
    if args.list:
        for case in cases:
            print(
                case["suite"] + "/" + case["name"] + " " + json.dumps(case["command"])
            )
        return 0
    fixtures = fixture_records(root, manifest)
    if args.locked:
        invalid = [
            name
            for name, fixture in fixtures.items()
            if fixture["commit"] != fixture["expected"] or fixture["changes"]
        ]
        if invalid:
            parser.error(
                "Pinned fixtures are absent, changed or at another revision: "
                + ", ".join(invalid)
            )
    if args.output:
        directory = args.output.resolve()
        directory.mkdir(parents=True, exist_ok=False)
    else:
        directory = Path(tempfile.mkdtemp(prefix=root.name + "-tests-"))
    summary = {
        "runner_version": VERSION,
        "root": str(root),
        "commit": git(root, "rev-parse", "HEAD"),
        "changes": git(root, "status", "--short"),
        "suites": suites,
        "results": [],
    }
    try:
        nvim = subprocess.run(
            [os.environ.get("NVIM_BIN", "nvim"), "--version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        summary["nvim"] = (nvim.stdout.splitlines() or [nvim.stderr])[0]
    except (OSError, subprocess.SubprocessError) as error:
        summary["nvim"] = str(error)
    fixtures = {}
    for case in cases:
        for req in manifest.get("requires", []) + case.get("requires", []):
            if req.startswith("path:"):
                env = dict(os.environ)
                for key, value in manifest.get("defaults", {}).items():
                    env.setdefault(key, expand(value, root, directory, env))
                path = Path(expand(req[5:], root, directory, env))
                owner = path if path.is_dir() else path.parent
                fixtures[str(path)] = {
                    "commit": git(owner, "rev-parse", "HEAD"),
                    "changes": git(owner, "status", "--short"),
                }
    summary["requirements"] = fixtures
    summary["fixtures"] = fixture_records(root, manifest)
    omitted = sorted(known - set(suites))
    print("Artifacts: " + str(directory), flush=True)
    if omitted:
        print("Suites not selected (run explicitly): " + ", ".join(omitted), flush=True)
    for index, case in enumerate(cases, 1):
        label = case["suite"] + "/" + case["name"]
        print("[" + str(index) + "/" + str(len(cases)) + "] " + label, flush=True)
        folder = directory / (
            str(index).zfill(3) + "-" + re.sub(r"[^a-zA-Z0-9_.-]", "-", label)
        )
        try:
            record = execute(root, folder, manifest, case)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            record = {
                "name": case["name"],
                "suite": case["suite"],
                "status": "fail",
                "directory": str(folder),
                "seconds": 0,
                "reason": str(error),
            }
        summary["results"].append(record)
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(
            "  "
            + record["status"].upper()
            + " ("
            + str(record["seconds"])
            + "s) "
            + record.get("reason", ""),
            flush=True,
        )
        log = folder / "output.log"
        if log.exists():
            content = log.read_text(errors="replace")
            print(
                content[-12000:] if record["status"] == "fail" else content,
                end="",
                flush=True,
            )
    failed = sum(record["status"] != "pass" for record in summary["results"])
    print(
        "\nChecks: " + str(len(cases) - failed) + " passed, " + str(failed) + " failed."
    )
    if failed or args.keep or args.output:
        print("Logs and summary retained: " + str(directory))
    else:
        shutil.rmtree(directory)
    return int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())
