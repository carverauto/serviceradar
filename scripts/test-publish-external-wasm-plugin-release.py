#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


ASSET_NAME = "serviceradar-wasm-plugin-index.json"


class State:
    def __init__(self):
        self.exists = False
        self.draft = False
        self.asset = None


def release_document(server, state):
    assets = []
    if state.asset is not None:
        host, port = server.server_address
        assets.append(
            {
                "id": 11,
                "name": ASSET_NAME,
                "browser_download_url": f"http://{host}:{port}/download/{ASSET_NAME}",
            }
        )
    return {"id": 7, "tag_name": "v0.1.0", "draft": state.draft, "assets": assets}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    @property
    def state(self):
        return self.server.state

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.endswith("/releases/tags/v0.1.0"):
            if not self.state.exists or self.state.draft:
                self.send_json(404, {"message": "not found"})
                return
            self.send_json(200, release_document(self.server, self.state))
            return
        if parsed.path.endswith("/releases") and parsed.query == "draft=true&limit=100":
            releases = [release_document(self.server, self.state)] if self.state.exists and self.state.draft else []
            self.send_json(200, releases)
            return
        if parsed.path.endswith("/releases/7"):
            self.send_json(200, release_document(self.server, self.state))
            return
        if parsed.path == f"/download/{ASSET_NAME}" and self.state.asset is not None:
            self.send_response(200)
            self.send_header("Content-Length", str(len(self.state.asset)))
            self.end_headers()
            self.wfile.write(self.state.asset)
            return
        self.send_json(404, {"message": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if parsed.path.endswith("/releases"):
            payload = json.loads(body)
            self.state.exists = True
            self.state.draft = payload["draft"]
            self.send_json(201, release_document(self.server, self.state))
            return
        if parsed.path.endswith("/releases/7/assets"):
            boundary = self.headers["Content-Type"].split("boundary=", 1)[1].strip().strip('"')
            for part in body.split(("--" + boundary).encode()):
                if b'name="attachment"' in part and b"\r\n\r\n" in part:
                    self.state.asset = part.split(b"\r\n\r\n", 1)[1].removesuffix(b"\r\n")
                    self.send_json(201, {"id": 11, "name": ASSET_NAME})
                    return
            self.send_json(400, {"message": "missing attachment"})
            return
        self.send_json(404, {"message": "not found"})

    def do_DELETE(self):
        self.state.asset = None
        self.send_response(204)
        self.end_headers()

    def do_PATCH(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.state.draft = payload["draft"]
        self.send_json(200, release_document(self.server, self.state))


def run(script, index, server, expect_success):
    host, port = server.server_address
    env = os.environ.copy()
    env.update(
        {
            "FORGEJO_URL": f"http://{host}:{port}",
            "EXTERNAL_PLUGIN_FORGEJO_PUBLISH_TOKEN": "test-token",
            "EXTERNAL_PLUGIN_TARGET_COMMITISH": "a" * 40,
        }
    )
    result = subprocess.run(
        [str(script), "carverauto/serviceradar-plugin-hpna", "v0.1.0", str(index)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if expect_success != (result.returncode == 0):
        raise AssertionError(result.stderr or result.stdout)


def main():
    script = Path(__file__).with_name("publish-external-wasm-plugin-release.sh")
    state = State()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.state = state
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            index = Path(temp_dir) / ASSET_NAME
            original = json.dumps(
                {"schema_version": 1, "release_tag": "v0.1.0", "plugins": [{}]},
                sort_keys=True,
            ).encode() + b"\n"
            index.write_bytes(original)
            run(script, index, server, True)
            assert state.asset == original and not state.draft
            run(script, index, server, True)
            index.write_text('{"schema_version":1,"release_tag":"v0.1.0","plugins":[{"changed":true}]}\n')
            run(script, index, server, False)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("external Wasm Forgejo release contract verified")


if __name__ == "__main__":
    main()
