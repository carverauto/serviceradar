"""Fail-closed `@carverauto/serviceradar-cli` driver with isolated scratch HOME."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Mapping

from integration_tests.vantage_ml import vantage_contracts
from integration_tests.vantage_ml.drivers import env_probe


def resolve_cli_entrypoint(repo: Path | None = None) -> Path:
    """Locate the ServiceRadar CLI Node entrypoint or fail closed."""
    root = repo or vantage_contracts.repo_root()
    candidates = (
        root / "js/cli/bin/serviceradar-cli.js",
        root / "js/cli/dist/cli.js",
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError(
        "serviceradar-cli entrypoint not found at js/cli/bin/serviceradar-cli.js or js/cli/dist/cli.js"
    )


def run_cli(
    args: list[str],
    *,
    cwd: Path | None = None,
    extra_env: Mapping[str, str] | None = None,
    timeout: float = 60.0,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Invoke `node js/cli/...` with isolated HOME/XDG directories under scratch."""
    node_bin = env_probe.probe_binary("node")
    entrypoint = resolve_cli_entrypoint()
    cli_home = env_probe.get_scratch_dir("cli-home")
    xdg_config = env_probe.get_scratch_dir("cli-home/xdg-config")
    xdg_data = env_probe.get_scratch_dir("cli-home/xdg-data")
    xdg_cache = env_probe.get_scratch_dir("cli-home/xdg-cache")

    env = dict(os.environ)
    env["HOME"] = str(cli_home)
    env["XDG_CONFIG_HOME"] = str(xdg_config)
    env["XDG_DATA_HOME"] = str(xdg_data)
    env["XDG_CACHE_HOME"] = str(xdg_cache)
    if extra_env:
        env.update(extra_env)

    proc = subprocess.run(
        [str(node_bin), str(entrypoint), *args],
        cwd=str(cwd or vantage_contracts.repo_root()),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"serviceradar-cli {args!r} exited {proc.returncode}: "
            f"stdout={proc.stdout.strip()} stderr={proc.stderr.strip()}"
        )
    return proc
