#!/usr/bin/env python3
"""
Mock server for Google STS and external account credential sources.

This server provides:
- GET  /token  : returns an OIDC subject token in JSON format
- POST /v1/token : accepts RFC 8693 token exchange via application/x-www-form-urlencoded
- POST */:generateAccessToken : simulates IAMCredentials generateAccessToken (optional)

It is intended for local testing with services/google/testdata/test_external_account.json.
"""

import json
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs


def _read_body(handler: BaseHTTPRequestHandler) -> bytes:
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0:
        return b""
    return handler.rfile.read(length)


class StsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/token":
            self._handle_subject_token()
            return

        self.send_error(404, "Not Found")

    def do_POST(self):
        if self.path == "/v1/token":
            self._handle_sts_token_exchange()
            return

        if self.path.endswith(":generateAccessToken"):
            self._handle_generate_access_token()
            return

        self.send_error(404, "Not Found")

    def _handle_subject_token(self):
        token_response = {
            "id_token": "mock-oidc-subject-token",
        }
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(token_response).encode())

    def _handle_sts_token_exchange(self):
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("application/x-www-form-urlencoded"):
            self.send_error(
                415,
                "Content-Type must be application/x-www-form-urlencoded for STS token exchange",
            )
            return

        body = _read_body(self).decode("utf-8", errors="replace")
        values = {k: v[0] for k, v in parse_qs(body, keep_blank_values=True).items()}

        required = [
            "grant_type",
            "requested_token_type",
            "audience",
            "scope",
            "subject_token",
            "subject_token_type",
        ]
        missing = [k for k in required if not values.get(k)]
        if missing:
            self.send_error(400, f"Missing required form fields: {', '.join(missing)}")
            return

        if values["grant_type"] != "urn:ietf:params:oauth:grant-type:token-exchange":
            self.send_error(400, "Invalid grant_type")
            return
        if values["requested_token_type"] != "urn:ietf:params:oauth:token-type:access_token":
            self.send_error(400, "Invalid requested_token_type")
            return

        token_response = {
            "access_token": f"mock-sts-access-token-{int(time.time())}",
            "expires_in": 3600,
            "token_type": "Bearer",
        }
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(token_response).encode())

    def _handle_generate_access_token(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self.send_error(401, "Authorization: Bearer <token> required")
            return

        expires_in = 3600
        expire_time = datetime.now(timezone.utc) + timedelta(seconds=expires_in)
        token_response = {
            "accessToken": f"mock-impersonated-access-token-{int(time.time())}",
            "expireTime": expire_time.isoformat().replace("+00:00", "Z"),
        }
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(token_response).encode())

    def log_message(self, format, *args):
        sys.stderr.write(
            f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {format % args}\n"
        )


def run_server(port: int = 5000):
    server_address = ("127.0.0.1", port)
    httpd = HTTPServer(server_address, StsHandler)
    print(f"Mock Google STS Server running on http://127.0.0.1:{port}")
    print("Press Ctrl+C to stop")
    print("")
    print("Endpoints:")
    print(f"  GET  http://127.0.0.1:{port}/token")
    print(f"  POST http://127.0.0.1:{port}/v1/token")
    print(
        f"  POST http://127.0.0.1:{port}/v1/projects/-/serviceAccounts/test@example.com:generateAccessToken"
    )
    httpd.serve_forever()


if __name__ == "__main__":
    port = 5000
    if len(sys.argv) > 1:
        port = int(sys.argv[1])
    run_server(port)
