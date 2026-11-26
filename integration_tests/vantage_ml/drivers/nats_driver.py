"""Fail-closed NATS JetStream driver for Mode B E2E execution."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Mapping

from integration_tests.vantage_ml.drivers import env_probe


def require_nats_url(nats_url: str | None = None) -> str:
    """Resolve and verify NATS URL or fail closed."""
    url = (nats_url or os.environ.get("SERVICERADAR_E2E_NATS_URL", "")).strip()
    if not url:
        raise RuntimeError(
            "SERVICERADAR_E2E_NATS_URL is not set; Mode B NATS JetStream requires a live server"
        )
    return url


def run_nats_cli(
    args: list[str],
    *,
    nats_url: str | None = None,
    stdin_bytes: bytes | None = None,
    timeout: float = 30.0,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    """Execute `nats` CLI against the target server (fails closed on missing binary/error)."""
    nats_bin = env_probe.probe_binary("nats")
    url = require_nats_url(nats_url)
    proc = subprocess.run(
        [str(nats_bin), "--server", url, *args],
        input=stdin_bytes,
        capture_output=True,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"nats {args!r} exited {proc.returncode}: {stderr}")
    return proc


def publish_json(
    subject: str,
    payload: Mapping[str, Any],
    *,
    msg_id: str | None = None,
    headers: Mapping[str, str] | None = None,
    nats_url: str | None = None,
) -> None:
    """Publish a JSON payload with optional `Nats-Msg-Id` idempotency header."""
    if not subject or not subject.strip():
        raise RuntimeError("NATS subject must be non-empty")
    cmd = ["pub", subject]
    if msg_id:
        cmd.extend(["-H", f"Nats-Msg-Id:{msg_id}"])
    if headers:
        for k, v in sorted(headers.items()):
            cmd.extend(["-H", f"{k}:{v}"])
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    run_nats_cli(cmd, nats_url=nats_url, stdin_bytes=body)


def stream_info(stream: str, *, nats_url: str | None = None) -> dict[str, Any]:
    """Fetch JetStream stream info JSON (fails closed if stream or server missing)."""
    proc = run_nats_cli(["stream", "info", stream, "--json"], nats_url=nats_url)
    try:
        return json.loads(proc.stdout.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"failed to parse nats stream info JSON for {stream!r}: {exc}") from exc


def start_ephemeral_jetstream(
    port: int = 14222,
    timeout: float = 5.0,
) -> tuple[subprocess.Popen[bytes], str, Path]:
    """Start an isolated `nats-server -js` instance storing state in scratch dir."""
    if timeout <= 0:
        raise RuntimeError(f"nats-server startup timeout must be > 0, got {timeout}")
    server_bin = env_probe.probe_binary("nats-server")
    store_dir = env_probe.get_scratch_dir(f"nats/js-{port}")
    proc = subprocess.Popen(
        [
            str(server_bin),
            "-a",
            "127.0.0.1",
            "-p",
            str(port),
            "-js",
            "-sd",
            str(store_dir),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + timeout
    last_exc: Exception | None = None
    try:
        while True:
            rc = proc.poll()
            if rc is not None:
                stderr_out = ""
                if proc.stderr is not None:
                    stderr_out = proc.stderr.read().decode("utf-8", errors="replace").strip()
                raise RuntimeError(
                    f"nats-server exited prematurely with code {rc}: {stderr_out}"
                )
            remaining = deadline - time.monotonic()
            attempt_timeout = min(0.25, max(0.05, remaining))
            try:
                env_probe.probe_tcp("127.0.0.1", port, timeout=attempt_timeout)
                return proc, f"nats://127.0.0.1:{port}", store_dir
            except RuntimeError as exc:
                last_exc = exc
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"nats-server failed to bind 127.0.0.1:{port} within {timeout:.2f}s: {last_exc}"
                    ) from exc
                time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    except Exception:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        raise
