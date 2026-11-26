"""Fail-closed Rust & Python `serviceradar-sdk-vantage` build/test driver."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Mapping

from integration_tests.vantage_ml.drivers import env_probe


def _sdk_env(sdk_dir: Path, extra_env: Mapping[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ)
    cargo_target = env.get("CARGO_TARGET_DIR", "").strip()
    if not cargo_target:
        cargo_target = str(env_probe.get_scratch_dir("cargo-target-sdk"))
    env["CARGO_TARGET_DIR"] = cargo_target
    env["UV_CACHE_DIR"] = str(env_probe.get_scratch_dir("uv-cache"))
    if extra_env:
        env.update(extra_env)
    return env


def run_cargo_test(
    args: list[str] | None = None,
    *,
    sdk_dir: Path | None = None,
    extra_env: Mapping[str, str] | None = None,
    timeout: float = 300.0,
) -> subprocess.CompletedProcess[str]:
    """Run `cargo test` inside `serviceradar-sdk-vantage` (fails closed)."""
    cargo_bin = env_probe.probe_binary("cargo")
    repo = env_probe.probe_sdk_repo(sdk_dir)
    cmd = [str(cargo_bin), "test", *(args or [])]
    proc = subprocess.run(
        cmd,
        cwd=str(repo),
        env=_sdk_env(repo, extra_env),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"SDK cargo test {cmd!r} failed (rc={proc.returncode}): "
            f"stdout={proc.stdout.strip()} stderr={proc.stderr.strip()}"
        )
    return proc


def ensure_sdk_python_venv(
    *,
    sdk_dir: Path | None = None,
    timeout: float = 300.0,
) -> Path:
    """Create a `uv venv` strictly under scratch dir and return its python executable."""
    uv_bin = env_probe.probe_binary("uv")
    repo = env_probe.probe_sdk_repo(sdk_dir)
    venv_dir = env_probe.get_scratch_dir("sdk-venv")
    py_bin = venv_dir / "bin" / "python"
    if not py_bin.is_file():
        proc = subprocess.run(
            [str(uv_bin), "venv", str(venv_dir)],
            cwd=str(repo),
            env=_sdk_env(repo),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"uv venv {venv_dir} failed (rc={proc.returncode}): {proc.stderr.strip()}"
            )
    if not py_bin.is_file():
        raise RuntimeError(f"uv venv python missing at {py_bin}")
    return py_bin


def run_python_in_sdk_venv(
    args: list[str],
    *,
    sdk_dir: Path | None = None,
    extra_env: Mapping[str, str] | None = None,
    timeout: float = 300.0,
) -> subprocess.CompletedProcess[str]:
    """Run Python inside the scratch `sdk-venv` against `serviceradar-sdk-vantage`."""
    repo = env_probe.probe_sdk_repo(sdk_dir)
    py_bin = ensure_sdk_python_venv(sdk_dir=repo)
    proc = subprocess.run(
        [str(py_bin), *args],
        cwd=str(repo),
        env=_sdk_env(repo, extra_env),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"SDK venv python {args!r} failed (rc={proc.returncode}): "
            f"stdout={proc.stdout.strip()} stderr={proc.stderr.strip()}"
        )
    return proc
