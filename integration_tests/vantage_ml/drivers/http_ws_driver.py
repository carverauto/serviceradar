"""Fail-closed HTTP & Phoenix Channels WebSocket driver for Mode B E2E tests."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Mapping

from integration_tests.vantage_ml import vantage_contracts


def require_web_url(base_url: str | None = None) -> str:
    """Resolve `SERVICERADAR_E2E_WEB_URL` or fail closed."""
    url = (base_url or os.environ.get("SERVICERADAR_E2E_WEB_URL", "")).strip().rstrip("/")
    if not url:
        raise RuntimeError(
            "SERVICERADAR_E2E_WEB_URL is not set; Mode B HTTP/WebSocket tests require a live web-ng URL"
        )
    return url


def http_request(
    method: str,
    path_or_url: str,
    *,
    base_url: str | None = None,
    headers: Mapping[str, str] | None = None,
    json_body: Any = None,
    raw_body: bytes | None = None,
    timeout: float = 15.0,
) -> tuple[int, dict[str, str], bytes]:
    """Execute an HTTP request returning `(status_code, lowercased_headers, body_bytes)`."""
    if path_or_url.startswith(("http://", "https://")):
        url = path_or_url
    else:
        root = require_web_url(base_url)
        path = path_or_url if path_or_url.startswith("/") else f"/{path_or_url}"
        url = f"{root}{path}"

    req_headers = {k: v for k, v in (headers or {}).items()}
    data = raw_body
    if json_body is not None:
        data = json.dumps(json_body, separators=(",", ":")).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json")

    req = urllib.request.Request(url, data=data, headers=req_headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, resp_headers, resp.read()
    except urllib.error.HTTPError as err:
        resp_headers = {k.lower(): v for k, v in err.headers.items()} if err.headers else {}
        return err.code, resp_headers, err.read()
    except (urllib.error.URLError, OSError, ssl.SSLError) as exc:
        raise RuntimeError(f"HTTP {method} {url} failed: {exc}") from exc


def request_worker_read_grant(
    *,
    job_id: str,
    catalog_entry_id: str,
    descriptor_sha256: str,
    control_plane_token: str,
    deployment_ref: str,
    media_worker_generation: int,
    base_url: str | None = None,
    schema_version: int = 1,
    validate_200: bool = True,
) -> tuple[int, dict[str, str], dict[str, Any]]:
    """Call `POST /v1/media/workers/read-grants` using the exact control-plane headers."""
    body = {
        "schema_version": schema_version,
        "job_id": job_id,
        "catalog_entry_id": catalog_entry_id,
        "descriptor_sha256": descriptor_sha256,
    }
    headers = {
        "Content-Type": "application/json",
        "X-ServiceRadar-Control-Plane-Authorization": f"Bearer {control_plane_token}",
        "X-ServiceRadar-Deployment-Ref": deployment_ref,
        "X-ServiceRadar-Media-Worker-Generation": str(media_worker_generation),
    }
    status, resp_headers, raw = http_request(
        "POST",
        "/v1/media/workers/read-grants",
        base_url=base_url,
        headers=headers,
        json_body=body,
    )
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(
            f"read-grants HTTP {status} returned non-JSON body: {exc}"
        ) from exc
    if validate_200 and status == 200:
        vantage_contracts.validate_read_grant_response(decoded)
    return status, resp_headers, decoded


class PhoenixChannelClient:
    """Minimal stdlib RFC 6455 WebSocket client for Phoenix Channels (`vsn=2.0.0`)."""

    def __init__(
        self,
        ws_url: str,
        *,
        headers: Mapping[str, str] | None = None,
        timeout: float = 10.0,
    ) -> None:
        parsed = urllib.parse.urlparse(ws_url)
        if parsed.scheme not in ("ws", "wss"):
            raise RuntimeError(f"expected ws:// or wss:// URL, got {ws_url!r}")
        host = parsed.hostname
        if not host:
            raise RuntimeError(f"missing hostname in WebSocket URL {ws_url!r}")
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

        self._sock: socket.socket | None = None
        raw_sock: socket.socket | None = None
        try:
            raw_sock = socket.create_connection((host, port), timeout=timeout)
            if parsed.scheme == "wss":
                ctx = ssl.create_default_context()
                self._sock = ctx.wrap_socket(raw_sock, server_hostname=host)
            else:
                self._sock = raw_sock
            self._sock.settimeout(timeout)

            ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
            req_lines = [
                f"GET {path} HTTP/1.1",
                f"Host: {host}:{port}",
                "Upgrade: websocket",
                "Connection: Upgrade",
                f"Sec-WebSocket-Key: {ws_key}",
                "Sec-WebSocket-Version: 13",
            ]
            for k, v in (headers or {}).items():
                req_lines.append(f"{k}: {v}")
            req_lines.extend(["", ""])
            self._sock.sendall("\r\n".join(req_lines).encode("ascii"))

            buf = bytearray()
            while b"\r\n\r\n" not in buf:
                chunk = self._sock.recv(4096)
                if not chunk:
                    raise RuntimeError("WebSocket handshake closed before response headers")
                buf.extend(chunk)
            header_end = buf.index(b"\r\n\r\n")
            header_text = buf[:header_end].decode("latin-1")
            status_line = header_text.splitlines()[0] if header_text.splitlines() else ""
            if " 101 " not in status_line:
                raise RuntimeError(f"WebSocket handshake failed: {status_line}")
            expected_accept = base64.b64encode(
                hashlib.sha1(
                    (ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
                ).digest()
            ).decode("ascii")
            if expected_accept not in header_text:
                raise RuntimeError("WebSocket Sec-WebSocket-Accept mismatch")
            self._rx_buf = bytearray(buf[header_end + 4 :])
            self._ref = 1
        except (OSError, ssl.SSLError) as exc:
            self._close_quietly(self._sock or raw_sock)
            self._sock = None
            raise RuntimeError(f"WebSocket connection to {ws_url!r} failed: {exc}") from exc
        except Exception:
            self._close_quietly(self._sock or raw_sock)
            self._sock = None
            raise

    @staticmethod
    def _close_quietly(sock: socket.socket | None) -> None:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def close(self) -> None:
        self._close_quietly(self._sock)
        self._sock = None

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self._sock is None:
            raise RuntimeError("WebSocket connection is closed")
        mask_key = os.urandom(4)
        header = bytearray([0x80 | (opcode & 0x0F)])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", n))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", n))
        header.extend(mask_key)
        masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        try:
            self._sock.sendall(bytes(header) + masked)
        except (OSError, ssl.SSLError) as exc:
            raise RuntimeError(f"WebSocket send failed: {exc}") from exc

    def _send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def _recv_exact(self, n: int) -> bytes:
        if self._sock is None:
            raise RuntimeError("WebSocket connection is closed")
        while len(self._rx_buf) < n:
            try:
                chunk = self._sock.recv(4096)
            except (OSError, ssl.SSLError) as exc:
                raise RuntimeError(f"WebSocket receive failed: {exc}") from exc
            if not chunk:
                raise RuntimeError("WebSocket connection closed unexpectedly")
            self._rx_buf.extend(chunk)
        out = bytes(self._rx_buf[:n])
        del self._rx_buf[:n]
        return out

    def recv_json(self) -> Any:
        while True:
            b0, b1 = self._recv_exact(2)
            opcode = b0 & 0x0F
            masked = bool(b1 & 0x80)
            length = b1 & 0x7F
            if length == 126:
                (length,) = struct.unpack("!H", self._recv_exact(2))
            elif length == 127:
                (length,) = struct.unpack("!Q", self._recv_exact(8))
            mask = self._recv_exact(4) if masked else b""
            payload = self._recv_exact(length)
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise RuntimeError("WebSocket closed by remote peer")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0x1:
                return json.loads(payload.decode("utf-8"))

    def join(self, topic: str, payload: Mapping[str, Any] | None = None) -> Any:
        ref = str(self._ref)
        self._ref += 1
        frame = [ref, ref, topic, "phx_join", dict(payload or {})]
        self._send_text(json.dumps(frame))
        return self.recv_json()
