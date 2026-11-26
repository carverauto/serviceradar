"""Fail-closed environment and prerequisite probes for Mode B E2E drivers."""

from __future__ import annotations

import os
import shutil
import socket
import uuid
from pathlib import Path
from typing import Any

DEFAULT_SCRATCH_DIR = Path("/Volumes/Build/scratch/vantage-ml-e2e")
DEFAULT_SDK_VANTAGE_DIR = Path("/Users/mfreeman/src/serviceradar-sdk-vantage")


def get_scratch_dir(subdir: str | None = None) -> Path:
    """Return a verified-writable scratch directory under VANTAGE_E2E_SCRATCH_DIR."""
    raw = os.environ.get("VANTAGE_E2E_SCRATCH_DIR", "").strip()
    base = Path(raw) if raw else DEFAULT_SCRATCH_DIR
    target = (base / subdir) if subdir else base
    try:
        target.mkdir(parents=True, exist_ok=True)
        probe = target / f".write_probe_{os.getpid()}_{uuid.uuid4().hex[:8]}"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        raise RuntimeError(
            f"Mode B scratch directory {target} is not writable: {exc}"
        ) from exc
    return target


def probe_binary(name: str) -> Path:
    """Resolve an executable binary on PATH or fail closed with RuntimeError."""
    if not name or not name.strip():
        raise RuntimeError("binary name must be non-empty")
    resolved = shutil.which(name)
    if not resolved:
        raise RuntimeError(f"required Mode B binary {name!r} was not found on PATH")
    return Path(resolved)


def probe_path(path: Path | str, *, must_be_dir: bool = False) -> Path:
    """Verify a required filesystem path exists (and is a directory if requested)."""
    p = Path(path)
    if not p.exists():
        raise RuntimeError(f"required Mode B path does not exist: {p}")
    if must_be_dir and not p.is_dir():
        raise RuntimeError(f"required Mode B path is not a directory: {p}")
    return p


def probe_env_vars(*names: str) -> dict[str, str]:
    """Verify that every named environment variable is set and non-empty."""
    values: dict[str, str] = {}
    missing: list[str] = []
    for name in names:
        val = os.environ.get(name, "").strip()
        if not val:
            missing.append(name)
        else:
            values[name] = val
    if missing:
        raise RuntimeError(
            f"missing required Mode B environment variable(s): {', '.join(missing)}"
        )
    return values


def probe_tcp(host: str, port: int, timeout: float = 2.0) -> None:
    """Verify a TCP endpoint accepts connections or fail closed."""
    if not host or port <= 0 or port > 65535:
        raise RuntimeError(f"invalid TCP endpoint {host!r}:{port}")
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return
    except OSError as exc:
        raise RuntimeError(f"Mode B TCP endpoint {host}:{port} unreachable: {exc}") from exc


def probe_sdk_repo(path: Path | str | None = None) -> Path:
    """Verify the companion `serviceradar-sdk-vantage` checkout exists."""
    raw = os.environ.get("SERVICERADAR_SDK_VANTAGE_DIR", "").strip()
    candidate = Path(path) if path is not None else (Path(raw) if raw else DEFAULT_SDK_VANTAGE_DIR)
    probe_path(candidate, must_be_dir=True)
    if not (candidate / "Cargo.toml").is_file():
        raise RuntimeError(
            f"companion SDK directory {candidate} is missing Cargo.toml"
        )
    return candidate


def probe_mode_b_environment(*, require_services: bool = False) -> dict[str, Any]:
    """Probe binaries, scratch dir, and optional live service env vars (fail closed)."""
    scratch = get_scratch_dir()
    binaries: dict[str, str] = {}
    for tool in ("node", "cargo", "uv", "ffmpeg", "psql", "nats", "mix"):
        binaries[tool] = str(probe_binary(tool))

    services: dict[str, str] = {}
    if require_services:
        services = probe_env_vars(
            "SERVICERADAR_E2E_WEB_URL",
            "SERVICERADAR_E2E_NATS_URL",
            "SERVICERADAR_E2E_DATABASE_URL",
        )
        services["sdk_repo"] = str(probe_sdk_repo())

    return {
        "scratch_dir": str(scratch),
        "binaries": binaries,
        "services": services,
    }
