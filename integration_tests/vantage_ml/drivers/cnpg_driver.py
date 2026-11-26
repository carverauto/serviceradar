"""Fail-closed CNPG (`psql`) and Mix runner adapter for Mode B E2E verification."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Mapping

from integration_tests.vantage_ml import vantage_contracts
from integration_tests.vantage_ml.drivers import env_probe


def require_database_url(database_url: str | None = None) -> str:
    """Resolve `SERVICERADAR_E2E_DATABASE_URL` or `DATABASE_URL` (fails closed if unset)."""
    url = (
        database_url
        or os.environ.get("SERVICERADAR_E2E_DATABASE_URL", "")
        or os.environ.get("DATABASE_URL", "")
    ).strip()
    if not url:
        raise RuntimeError(
            "SERVICERADAR_E2E_DATABASE_URL / DATABASE_URL is not set; Mode B CNPG access requires a live DSN"
        )
    return url


def run_psql(
    sql: str,
    *,
    database_url: str | None = None,
    tuples_only: bool = True,
    timeout: float = 30.0,
) -> str:
    """Execute a SQL statement via `psql -v ON_ERROR_STOP=1` and return stdout."""
    psql_bin = env_probe.probe_binary("psql")
    dsn = require_database_url(database_url)
    cmd = [str(psql_bin), dsn, "-X", "-v", "ON_ERROR_STOP=1"]
    if tuples_only:
        cmd.extend(["-t", "-A"])
    cmd.extend(["-c", sql])
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(
            f"psql failed (rc={proc.returncode}): {proc.stderr.strip()}"
        )
    return proc.stdout.strip()


def run_mix_eval(
    app_dir: str,
    elixir_expr: str,
    *,
    extra_env: Mapping[str, str] | None = None,
    timeout: float = 120.0,
) -> subprocess.CompletedProcess[str]:
    """Execute `mix run -e ...` inside an Elixir app directory under repo root."""
    mix_bin = env_probe.probe_binary("mix")
    target_dir = env_probe.probe_path(vantage_contracts.repo_root() / app_dir, must_be_dir=True)
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(
        [str(mix_bin), "run", "-e", elixir_expr],
        cwd=str(target_dir),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"mix run in {app_dir} failed (rc={proc.returncode}): {proc.stderr.strip()}"
        )
    return proc
