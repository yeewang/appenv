#!/usr/bin/env python3
"""Opt-in real-app test. Opens four disposable windows; never uses default profiles."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--cli", type=Path, required=True)
parser.add_argument("--run-apps", action="store_true", required=True)
args = parser.parse_args()
cli = str(args.cli.resolve())

with tempfile.TemporaryDirectory(prefix="AppEnv-Integration-") as scratch:
    root = Path(scratch) / "storage"
    env = dict(os.environ, APPENV_HOME=str(root))

    def run(*arguments, ok=True):
        result = subprocess.run([cli, *arguments], env=env, capture_output=True, text=True, timeout=60)
        if ok and result.returncode:
            raise AssertionError(f"{arguments}: {result.stderr}")
        if not ok and not result.returncode:
            raise AssertionError(f"Expected refusal: {arguments}")
        return result.stdout.strip()

    def state():
        return {item["name"]: item for item in json.loads(run("list", "--json"))}

    def pids(item):
        return {app["adapter"]: app["instance"]["pid"] for app in item["apps"] if app.get("instance")}

    names = ["Integration A", "Integration B"]
    try:
        for name in names:
            run("create", name)
            for app in ["chrome", "vscode"]:
                print(run("run", "--env", name, "--app", app), flush=True)
        live = state()
        first, second = pids(live[names[0]]), pids(live[names[1]])
        assert len(set(first.values()) | set(second.values())) == 4
        run("duplicate", names[0], "Must Fail", ok=False)
        run("delete", names[0], "--yes", ok=False)
        for app in ["chrome", "vscode"]:
            run("run", "--env", names[0], "--app", app)
        assert pids(state()[names[0]]) == first, "Reopening must reuse the same instance"
        print("PASS: four distinct instances; focus reuses instances; running data protected", flush=True)

        registry_file = root / "registry.json"
        registry = json.loads(registry_file.read_text())
        for item in registry["environments"]:
            for app in item["apps"]:
                app.pop("instance", None)
        registry_file.write_text(json.dumps(registry))
        recovered = state()
        assert pids(recovered[names[0]]) == first
        assert pids(recovered[names[1]]) == second
        print("PASS: lost launch receipts recovered from exact process arguments", flush=True)

        run("stop", names[0])
        assert not pids(state()[names[0]])
        assert pids(state()[names[1]]) == second
        print("PASS: stopping one environment leaves the other running", flush=True)

        source_path = Path(run("path", names[0]))
        sentinel = source_path / "persistence-test.txt"
        sentinel.write_text("persistent")
        for app in ["chrome", "vscode"]:
            run("run", "--env", names[0], "--app", app)
        assert sentinel.read_text() == "persistent"
        run("stop", names[0])
        run("duplicate", names[0], "Integration Copy")
        copy_path = Path(run("path", "Integration Copy"))
        (copy_path / sentinel.name).write_text("independent")
        assert sentinel.read_text() == "persistent"
        run("export", "Integration Copy", str(Path(scratch) / "backup.zip"))
        assert (Path(scratch) / "backup.zip").stat().st_size > 0
        print("PASS: restart persistence, independent duplication, and ZIP export", flush=True)
    finally:
        for name in names:
            subprocess.run([cli, "stop", name, "--force"], env=env, capture_output=True, timeout=30)
        # Wait for app-owned helper processes to finish before deleting temporary profiles.
        time.sleep(2)
        aliases = Path(f"/tmp/appenv-{os.getuid()}")
        if aliases.is_dir():
            for alias in aliases.iterdir():
                if alias.is_symlink() and os.readlink(alias).startswith(str(root) + "/"):
                    alias.unlink()
    assert all(not pids(item) for item in state().values())
    print("PASS: all test instances stopped; temporary profiles removed", flush=True)
