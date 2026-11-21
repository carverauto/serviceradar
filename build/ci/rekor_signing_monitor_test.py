"""The Rekor signing monitor against a synthetic log and a synthetic GitHub API.

Every key is a throwaway generated per run; the log, its signed tree head, the workflow runs,
their signing-ledger artifacts and the issue tracker are local stand-ins on loopback.
Owner: build/ci/rekor_signing_monitor.py.
"""

import base64
import contextlib
import hashlib
import http.server
import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import rekor_signing_monitor as monitor  # noqa: E402

NOW = datetime(2027, 1, 10, 12, 0, tzinfo=timezone.utc)
REPOSITORY = "example/repo"


def openssl_key(directory, name):
    private, public = directory / f"{name}.key", directory / f"{name}.pub"
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-out", str(private)], check=True, capture_output=True)
    subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                   check=True, capture_output=True)
    return private, public


def sign(private, data):
    return subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private)], input=data,
                          check=True, capture_output=True).stdout


def rfc6962_root(entries):
    """MTH from RFC 6962 section 2.1, written from the RFC: the test's oracle for the log's root."""
    if not entries:
        return hashlib.sha256().digest()
    if len(entries) == 1:
        return hashlib.sha256(b"\x00" + entries[0]).digest()
    split = 1 << ((len(entries) - 1).bit_length() - 1)
    return hashlib.sha256(b"\x01" + rfc6962_root(entries[:split]) + rfc6962_root(entries[split:])).digest()


# The Certificate Transparency reference implementation's Merkle tree test vectors: the inputs
# and the root of each prefix of 1 to 8 of them.
CT_INPUTS = ["", "00", "10", "2021", "3031", "40414243", "5051525354555657",
             "606162636465666768696a6b6c6d6e6f"]
CT_ROOTS = [
    "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
    "fac54203e7cc696cf0dfcb42c92a1d9dbaf70ad9e621f4bd8d98662f00e3c125",
    "aeb6bcfe274b70a14fb067a5e5578264db0fa9b51af5e0ba159158f329e06e77",
    "d37ee418976dd95753c1c73862b9398fa2a2cf9b4ff0fdfe8b30cd95209614b7",
    "4e3bbb1f7b478dcfe71fb631631519a3bca12c9aefca1612bfce4c13a86264d4",
    "76e67dadbcdf1e10e1b74ddc608abd2f98dfb16fbce75277b5232a127f2087ef",
    "ddb89be403809e325750d3d263cd78929c2942b7942a34b77e122c9594a74c8c",
    "5dc9da79a70659a9ad559cb701ded9a2ab9d823aad2f4960cfe370eff4604328",
]


class World:
    """The synthetic log and GitHub API one HTTP server answers for."""

    def __init__(self, root):
        self.root = root
        self.log_key, self.log_pub = openssl_key(root, "log")
        self.release_key, self.release_pub = openssl_key(root, "release")
        self.other_key, self.other_pub = openssl_key(root, "other")
        self.served_key = self.log_pub.read_text()
        self.bodies = []
        self.runs = {}
        self.ledgers = {}
        self.issues = []
        self.labels = {"security"}
        self.discord = []
        self.discord_status = 204
        self.state_zips = {}
        self.truncated_ledgers = set()
        self.filler_artifacts = 0
        self.blob_requests_with_auth = 0
        self.artifact_accepts = []
        self.failing_paths = {}

    def add_entry(self, payload, key_pub=None, when=NOW - timedelta(hours=3)):
        digest = hashlib.sha256(payload).hexdigest()
        body = json.dumps({"apiVersion": "0.0.1", "kind": "hashedrekord", "spec": {
            "data": {"hash": {"algorithm": "sha256", "value": digest}},
            "signature": {"content": "c2ln", "publicKey": {
                "content": base64.b64encode((key_pub or self.release_pub).read_bytes()).decode()}}}}).encode()
        self.bodies.append((body, int(when.timestamp())))
        index = len(self.bodies) - 1
        return {"log_index": index, "payload_sha256": digest, "integrated_time": int(when.timestamp()),
                "uuid": self.uuid(index)}

    def uuid(self, index):
        return "0000000000000001" + hashlib.sha256(b"\x00" + self.bodies[index][0]).hexdigest()

    def add_run(self, workflow, run_id, start, end, ledger=None, ref="refs/heads/staging"):
        runs = self.runs.setdefault(workflow, [])
        runs.insert(0, {"id": run_id, "created_at": f"{start:%Y-%m-%dT%H:%M:%SZ}",
                        "updated_at": f"{(end or NOW):%Y-%m-%dT%H:%M:%SZ}",
                        "status": "completed" if end else "in_progress",
                        "head_branch": ref.split("/", 2)[2], "display_title": ref,
                        "html_url": f"https://github.example/run/{run_id}"})
        if ledger is not None:
            self.ledgers[run_id] = ledger

    def log_info(self):
        root = rfc6962_root([body for body, _when in self.bodies])
        note = f"test-log - 1\n{len(self.bodies)}\n{base64.b64encode(root).decode()}\n"
        signature = sign(self.log_key, note.encode())
        return {"treeSize": len(self.bodies), "rootHash": root.hex(), "treeID": "1",
                "signedTreeHead": note + "\n— test-log " + base64.b64encode(b"hint" + signature).decode() + "\n"}

    def entry(self, index):
        body, when = self.bodies[index]
        return {self.uuid(index): {"body": base64.b64encode(body).decode(), "integratedTime": when,
                                   "logIndex": index, "logID": "x"}}

    def ledger_zip(self, run_id):
        if run_id in self.truncated_ledgers:
            return b"PK\x03\x04 truncated download"
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("signing-ledger.jsonl", "".join(json.dumps(line) + "\n" for line in self.ledgers[run_id]))
        return buffer.getvalue()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, payload=None, raw=None, headers=()):
        body = raw if raw is not None else json.dumps(payload).encode() if payload is not None else b""
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def github_rejects(self):
        """Like the GitHub REST API: 415 for an Accept it does not serve (application/zip included)."""
        if not self.path.startswith("/repos/"):
            return False
        accept = self.headers.get("Accept", "")
        if any(kind in accept for kind in ("application/json", "application/vnd.github+json", "*/*")):
            return False
        self.reply(415, {"message": f"Unsupported 'Accept' header: '{accept}'. Must accept 'application/json'."})
        return True

    def injected_failure(self, path):
        failure = self.server.world.failing_paths.get(path)
        if failure is None:
            return False
        if failure == "drop":
            self.close_connection = True
            return True
        status, location = failure
        self.reply(status, {}, headers=[("Location", location)] if location else ())
        return True

    @staticmethod
    def page(items, query):
        per_page, page = int(query.get("per_page", ["30"])[0]), int(query.get("page", ["1"])[0])
        return items[(page - 1) * per_page:page * per_page]

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else None

    def do_GET(self):
        world, path = self.server.world, self.path.split("?")[0]
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        prefix = f"/repos/{REPOSITORY}"
        if self.injected_failure(path) or self.github_rejects():
            return None
        if path == "/api/v1/log":
            return self.reply(200, world.log_info())
        if path == "/api/v1/log/publicKey":
            return self.reply(200, raw=world.served_key.encode())
        if path.startswith(prefix + "/actions/workflows/"):
            # Like GitHub: newest first, `created=>=T` drops runs created before T, paged.
            runs = world.runs.get(path.split("/")[-2], [])
            if "created" in query:
                since = monitor.parse_time(query["created"][0].removeprefix(">="))
                runs = [run for run in runs if monitor.parse_time(run["created_at"]) >= since]
            return self.reply(200, {"workflow_runs": self.page(runs, query)})
        if path.startswith(prefix + "/labels/"):
            name = urllib.parse.unquote(path.split("/")[-1])
            return self.reply(200, {"name": name}) if name in world.labels else self.reply(404, {})
        if path.startswith("/state/"):
            return self.reply(200, raw=world.state_zips[int(path.split("/")[-1])])
        if path.startswith(prefix + "/actions/runs/"):
            run_id = int(path.split("/")[-2])
            artifacts = [{"name": f"build-output-{number}", "expired": False, "archive_download_url": "unused"}
                         for number in range(world.filler_artifacts)]
            if run_id in world.state_zips:
                artifacts.append({
                    "name": monitor.STATE_ARTIFACT, "expired": False,
                    "archive_download_url": f"http://127.0.0.1:{self.server.server_port}{prefix}/actions/artifacts/s{run_id}/zip"})
            elif run_id in world.ledgers:
                artifacts.append({
                    "name": f"signing-ledger-x-publish-{run_id}-1", "expired": False,
                    "archive_download_url": f"http://127.0.0.1:{self.server.server_port}{prefix}/actions/artifacts/{run_id}/zip"})
            return self.reply(200, {"artifacts": self.page(artifacts, query)})
        if path.startswith(prefix + "/actions/artifacts/"):
            world.artifact_accepts.append(self.headers.get("Accept"))
            artifact_id = path.split("/")[-2]
            target = f"/state/{artifact_id[1:]}" if artifact_id.startswith("s") else f"/blob/{artifact_id}"
            return self.reply(302, headers=[("Location", f"http://127.0.0.1:{self.server.server_port}{target}")])
        if path.startswith("/blob/"):
            if self.headers.get("Authorization"):
                world.blob_requests_with_auth += 1
            return self.reply(200, raw=world.ledger_zip(int(path.split("/")[-1])))
        if path == prefix + "/issues":
            # Like GitHub: newest first, paged.
            return self.reply(200, self.page([issue for issue in reversed(world.issues) if issue["state"] == "open"],
                                             query))
        self.reply(404, {})

    def do_POST(self):
        world, path = self.server.world, self.path.split("?")[0]
        prefix = f"/repos/{REPOSITORY}"
        payload = self.body()
        if self.injected_failure(path) or self.github_rejects():
            return None
        if path == "/api/v1/log/entries/retrieve":
            return self.reply(200, [world.entry(index) for index in payload["logIndexes"]])
        if path == prefix + "/labels":
            world.labels.add(payload["name"])
            return self.reply(201, payload)
        if path == prefix + "/issues":
            if not set(payload["labels"]) <= world.labels:
                return self.reply(422, {"message": "Validation Failed"})
            issue = {"number": len(world.issues) + 1, "title": payload["title"], "body": payload["body"],
                     "labels": payload["labels"], "state": "open", "comments": [], "html_url": "https://issue"}
            world.issues.append(issue)
            return self.reply(201, issue)
        if path.startswith(prefix + "/issues/") and path.endswith("/comments"):
            world.issues[int(path.split("/")[-2]) - 1]["comments"].append(payload["body"])
            return self.reply(201, {})
        if path == "/discord":
            if world.discord_status == "truncated":
                self.send_response(200)
                self.send_header("Content-Length", "100")
                self.end_headers()
                self.wfile.write(b"{")
                return None
            if world.discord_status == 204:
                world.discord.append(payload["content"])
            return self.reply(world.discord_status)
        self.reply(404, {})

    def do_PATCH(self):
        world, path = self.server.world, self.path.split("?")[0]
        payload = self.body()
        if self.github_rejects():
            return None
        world.issues[int(path.split("/")[-1]) - 1]["state"] = payload["state"]
        self.reply(200, {})


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.world = World(self.root)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.world = self.world
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.acknowledged = self.root / "acknowledged.json"
        self.acknowledged.write_text(json.dumps({"entries": []}))
        self.state = self.root / "state.json"
        # An entry from before the monitor existed is judged too; this one is someone else's.
        self.world.add_entry(b"historical", key_pub=self.world.other_pub, when=NOW - timedelta(hours=12))
        self.assertEqual(self.run_monitor(bootstrap=True, now=NOW - timedelta(hours=10)), 0)

    def run_monitor(self, bootstrap=False, now=NOW):
        out = self.root / f"state-{len(list(self.root.glob('state-*')))}.json"
        args = ["--rekor-url", self.base, "--github-api", self.base, "--rekor-key", str(self.world.log_pub),
                "--release-key", str(self.world.release_pub), "--acknowledged", str(self.acknowledged),
                "--state-out", str(out)]
        if self.state.is_file():
            args += ["--state-in", str(self.state)]
        if bootstrap:
            args.append("--bootstrap")
        environ = {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": "synthetic-token",
                   "CI_FAILURE_DISCORD_WEBHOOK_URL": self.base + "/discord"}
        status = monitor.main(args, environ, now=now)
        if status == 0:
            out.replace(self.state)
        return status

    def move_first_checkpoint(self, when):
        state = json.loads(self.state.read_text())
        state["first_integrated_time"] = int(when.timestamp())
        self.state.write_text(json.dumps(state))

    def titles(self, state="open"):
        return [issue["title"] for issue in self.world.issues if issue["state"] == state]

    def test_merkle_root_matches_the_certificate_transparency_vectors(self):
        inputs = [bytes.fromhex(item) for item in CT_INPUTS]
        for size in range(1, len(inputs) + 1):
            with self.subTest(size=size):
                leaves = [hashlib.sha256(b"\x00" + item).digest() for item in inputs[:size]]
                self.assertEqual(monitor.merkle_root(leaves).hex(), CT_ROOTS[size - 1])
                self.assertEqual(rfc6962_root(inputs[:size]).hex(), CT_ROOTS[size - 1])

    def test_unexplained_release_key_entry_opens_one_issue_and_alerts(self):
        entry = self.world.add_entry(b"signed outside any run")
        self.world.add_entry(b"someone else's signature", key_pub=self.world.other_pub)
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])
        self.assertEqual(self.world.issues[0]["labels"], ["security", "signing-monitor"])
        self.assertIn("signing-monitor", self.world.labels, "the missing label was not created")
        self.assertEqual(len(self.world.discord), 1)
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(len(self.world.issues), 1, "the same entry was reported twice")
        self.assertEqual(len(self.world.discord), 1, "the same entry was posted twice")

    def test_an_undelivered_discord_alert_is_retried_until_accepted(self):
        entry = self.world.add_entry(b"signed outside any run")
        self.world.discord_status = 500
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(len(self.world.issues), 1)
        self.world.discord_status = 204
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(len(self.world.discord), 1)
        self.assertIn(entry["uuid"], self.world.discord[0])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(len(self.world.discord), 1, "a delivered alert was posted again")
        self.assertEqual(len(self.world.issues), 1)

    def test_entry_in_the_ledger_of_a_long_running_release_is_explained(self):
        entry = self.world.add_entry(b"release payload", when=NOW - timedelta(hours=3))
        # Created ten days ago (a release waiting on its environment, then re-run).
        self.world.add_run("release.yml", 11, NOW - timedelta(days=10), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])

    def test_entry_during_a_long_running_release_in_progress_is_pending(self):
        self.world.add_entry(b"mid-run payload", when=NOW - timedelta(hours=3))
        self.world.add_run("release.yml", 12, NOW - timedelta(days=10), None)
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])

    def certificate(self, private, name):
        path = self.root / f"{name}.crt"
        subprocess.run(["openssl", "req", "-x509", "-new", "-key", str(private), "-subj", f"/CN={name}",
                        "-days", "1", "-out", str(path)], check=True, capture_output=True)
        return path

    def test_a_release_key_inside_a_certificate_is_judged(self):
        entry = self.world.add_entry(b"signed with a wrapped release key",
                                     key_pub=self.certificate(self.world.release_key, "wrapped"))
        self.world.add_entry(b"someone else's certificate", key_pub=self.certificate(self.world.other_key, "other"))
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])

    def test_a_certificate_that_cannot_be_decoded_fails_the_scan(self):
        garbage = self.root / "garbage.crt"
        garbage.write_text("-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----\n")
        self.world.add_entry(b"unreadable certificate", key_pub=garbage)
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn("certificate cannot be decoded", self.world.discord[-1])

    def test_entry_in_a_finished_runs_ledger_is_explained(self):
        entries = {}
        for run_id, workflow, ref in [(7, "release.yml", "refs/tags/v1"),
                                      (8, "publish-media-worker-cuda.yml", "refs/heads/staging"),
                                      (9, "publish-media-worker-cuda.yml", "refs/heads/test/demo-test-12")]:
            entry = self.world.add_entry(f"synthetic payload {run_id}".encode())
            entries[entry["uuid"]] = run_id
            self.world.add_run(workflow, run_id, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                               [{"event": "sign", "payload_sha256": entry["payload_sha256"]}], ref=ref)
        self.assertEqual(self.run_monitor(), 0)
        state = json.loads(self.state.read_text())
        for uuid, run_id in entries.items():
            self.assertEqual(state["decisions"][uuid]["status"], "explained")
            self.assertIn(str(run_id), state["canary_checked"])
        self.assertEqual(self.world.issues, [])
        self.assertEqual(self.world.blob_requests_with_auth, 0, "the GitHub token followed the artifact redirect")

    def test_build_only_cuda_runs_cannot_explain_or_defer_an_alert(self):
        entry = self.world.add_entry(b"unexplained during CUDA builds")
        workflow = "publish-media-worker-cuda.yml"
        start = NOW - timedelta(hours=4)
        for run_id, ref in enumerate(("refs/heads/feature", "refs/heads/test/demo-test-x",
                                      "refs/tags/staging", "refs/tags/test/demo-test-7"), start=10):
            self.world.add_run(workflow, run_id, start, None, ref=ref)
        self.world.add_run(workflow, 14, start, NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}],
                           ref="refs/heads/feature")
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])
        self.assertNotIn("14", json.loads(self.state.read_text())["canary_checked"])

    def test_an_explained_entry_stays_explained_after_its_run_ages_out(self):
        entry = self.world.add_entry(b"release payload")
        self.world.add_run("release.yml", 7, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.assertEqual(self.run_monitor(), 0)
        self.world.runs["release.yml"].clear()
        self.world.ledgers.clear()
        self.assertEqual(self.run_monitor(now=NOW + timedelta(days=30)), 0)
        self.assertEqual(self.world.issues, [])

    def test_a_release_key_entry_from_before_the_first_checkpoint_is_judged(self):
        entry = self.world.add_entry(b"old unexplained", when=NOW - timedelta(days=2))
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])

    def test_entry_during_a_run_in_progress_waits_and_is_then_explained_or_reported(self):
        entry = self.world.add_entry(b"mid-run payload")
        self.world.add_run("wasm-plugins.yml", 8, NOW - timedelta(hours=4), None)
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])
        # The run ends without that payload in its ledger: now it is unexplained.
        self.world.runs["wasm-plugins.yml"].clear()
        self.world.add_run("wasm-plugins.yml", 8, NOW - timedelta(hours=4), NOW - timedelta(minutes=30), [])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])

    def test_issue_closes_when_a_later_scan_finds_the_entry_acknowledged(self):
        entry = self.world.add_entry(b"manual demo signature")
        self.assertEqual(self.run_monitor(), 0)
        self.acknowledged.write_text(json.dumps({"entries": [
            {"uuid": entry["uuid"], "log_index": entry["log_index"], "run": "n/a", "reason": "manual demo signing"}]}))
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles("open"), [])
        self.assertIn("manual demo signing", self.world.issues[0]["comments"][0])

    def test_a_ledger_match_outlives_an_acknowledgement_and_its_ledger(self):
        entry = self.world.add_entry(b"signed during a release")
        self.world.add_run("release.yml", 21, NOW - timedelta(hours=4), None)
        self.acknowledged.write_text(json.dumps({"entries": [
            {"uuid": entry["uuid"], "log_index": entry["log_index"], "run": "21", "reason": "release in progress"}]}))
        self.assertEqual(self.run_monitor(), 0)
        self.world.runs["release.yml"].clear()
        # Ended an hour ago: too recent for the canary, so only the acknowledged entry needs its ledger.
        self.world.add_run("release.yml", 21, NOW - timedelta(hours=4), NOW - timedelta(hours=1),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.assertEqual(self.run_monitor(), 0)
        self.world.runs["release.yml"].clear()
        self.world.ledgers.clear()
        self.acknowledged.write_text(json.dumps({"entries": []}))
        self.assertEqual(self.run_monitor(now=NOW + timedelta(days=91)), 0)
        self.assertEqual(self.world.issues, [])
        self.assertEqual(self.world.discord, [])

    def test_retracting_an_acknowledgement_restores_detection(self):
        entry = self.world.add_entry(b"acknowledged then retracted")
        self.acknowledged.write_text(json.dumps({"entries": [
            {"uuid": entry["uuid"], "log_index": entry["log_index"], "run": "n/a", "reason": "manual"}]}))
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])
        self.acknowledged.write_text(json.dumps({"entries": []}))
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])

    def test_a_bootstrap_dispatch_still_checks_an_existing_checkpoint(self):
        self.world.add_entry(b"first")
        self.assertEqual(self.run_monitor(), 0)
        self.world.bodies[1] = (b'{"kind":"rekord"}', self.world.bodies[1][1])
        self.assertEqual(self.run_monitor(bootstrap=True), 1)
        self.assertIn("rewrote entries", self.world.discord[-1])

    def test_rewritten_history_fails_and_alerts(self):
        self.world.add_entry(b"first")
        self.assertEqual(self.run_monitor(), 0)
        self.world.bodies[1] = (b'{"kind":"rekord"}', self.world.bodies[1][1])
        self.world.add_entry(b"second")
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn("Rekor signing monitor run failed", self.titles())
        self.assertIn("rewrote entries", self.world.discord[-1])

    def test_a_changed_log_key_fails(self):
        self.world.served_key = self.world.other_pub.read_text()
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn("public key other than", self.world.discord[-1])

    def test_a_tree_head_the_pinned_key_did_not_sign_fails(self):
        self.world.log_key = self.world.other_key
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn("does not verify", self.world.discord[-1])

    def test_a_truncated_ledger_download_fails_and_alerts(self):
        entry = self.world.add_entry(b"release payload")
        self.world.add_run("release.yml", 22, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.world.truncated_ledgers.add(22)
        before = self.state.read_text()
        self.assertEqual(self.run_monitor(), 1)
        self.assertEqual(self.titles(), ["Rekor signing monitor run failed"])
        self.assertIn("BadZipFile", self.world.discord[-1])
        self.assertEqual(self.state.read_text(), before)

    def test_an_unreadable_checkpoint_artifact_fails_and_alerts(self):
        self.world.runs[monitor.MONITOR_WORKFLOW] = [{"id": 45, "head_branch": "staging", "event": "schedule"}]
        self.world.state_zips = {45: b"not a zip archive"}
        out = self.root / "fetched.json"
        status = monitor.main(["--github-api", self.base, "--fetch-state", "--state-out", str(out)],
                              {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": "synthetic-token",
                               "CI_FAILURE_DISCORD_WEBHOOK_URL": self.base + "/discord"})
        self.assertEqual(status, 1)
        self.assertFalse(out.exists())
        self.assertEqual(self.titles(), ["Rekor signing monitor run failed"])
        self.assertIn("BadZipFile", self.world.discord[-1])

    def test_artifact_downloads_ask_for_a_media_type_the_github_api_serves(self):
        entry = self.world.add_entry(b"release payload")
        self.world.add_run("release.yml", 23, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), [], "the ledger download did not explain the entry")
        state = io.BytesIO()
        with zipfile.ZipFile(state, "w") as bundle:
            bundle.writestr("state.json", json.dumps({"tree_size": 3}))
        self.world.runs[monitor.MONITOR_WORKFLOW] = [{"id": 46, "head_branch": "staging", "event": "schedule"}]
        self.world.state_zips = {46: state.getvalue()}
        out = self.root / "fetched.json"
        status = monitor.main(["--github-api", self.base, "--fetch-state", "--state-out", str(out)],
                              {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": "synthetic-token"})
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out.read_text()), {"tree_size": 3})
        self.assertEqual(self.world.artifact_accepts, ["application/vnd.github+json"] * 2)
        self.assertEqual(self.world.blob_requests_with_auth, 0)

    def test_a_failed_request_names_its_method_host_and_path_without_the_query(self):
        entry = self.world.add_entry(b"release payload")
        self.world.add_run("release.yml", 24, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        location = f"{self.base}/expired-blob?sig=synthetic-signed-credential"
        self.world.failing_paths = {f"/repos/{REPOSITORY}/actions/artifacts/24/zip": (302, location),
                                    "/expired-blob": (403, None)}
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn(f"(GET {self.base}/expired-blob)", self.world.discord[-1])
        self.assertIn("HTTP Error 403", self.world.discord[-1])
        failure = next(issue for issue in self.world.issues if issue["title"] == "Rekor signing monitor run failed")
        for text in (self.world.discord[-1], failure["body"]):
            self.assertNotIn("synthetic-signed-credential", text)
            self.assertNotIn("synthetic-token", text)

    def test_a_dropped_connection_names_its_method_host_and_path(self):
        self.world.add_entry(b"release payload")
        self.world.failing_paths = {"/api/v1/log/entries/retrieve": "drop"}
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn("RemoteDisconnected", self.world.discord[-1])
        self.assertIn(f"(POST {self.base}/api/v1/log/entries/retrieve)", self.world.discord[-1])

    def test_a_failing_webhook_never_reveals_its_path(self):
        self.world.add_entry(b"release payload")
        webhook = "/discord/synthetic-webhook-secret"
        self.world.failing_paths = {"/api/v1/log/entries/retrieve": "drop", webhook: "drop"}
        args = ["--rekor-url", self.base, "--github-api", self.base, "--rekor-key", str(self.world.log_pub),
                "--release-key", str(self.world.release_pub), "--acknowledged", str(self.acknowledged),
                "--state-in", str(self.state), "--state-out", str(self.root / "unused.json")]
        environ = {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": "synthetic-token",
                   "CI_FAILURE_DISCORD_WEBHOOK_URL": self.base + webhook}
        output = io.StringIO()
        with contextlib.redirect_stderr(output), contextlib.redirect_stdout(output):
            self.assertEqual(monitor.main(args, environ, now=NOW), 1)
        self.assertIn("the Discord notification was not delivered", output.getvalue())
        failure = next(issue for issue in self.world.issues if issue["title"] == "Rekor signing monitor run failed")
        for text in [output.getvalue(), failure["body"], *self.world.discord]:
            self.assertNotIn("synthetic-webhook-secret", text)

    def test_an_issue_behind_a_full_page_of_newer_issues_is_still_found(self):
        entry = self.world.add_entry(b"signed outside any run")
        self.assertEqual(self.run_monitor(), 0)
        for number in range(100):
            self.world.issues.append({"number": len(self.world.issues) + 1, "title": f"Other alert {number}",
                                      "body": "", "labels": ["signing-monitor"], "state": "open", "comments": []})
        self.assertEqual(self.run_monitor(), 0)
        title = f"Unexplained release-key signature in Rekor: {entry['uuid']}"
        self.assertEqual(self.titles().count(title), 1, "the same entry was reported twice")
        self.acknowledged.write_text(json.dumps({"entries": [
            {"uuid": entry["uuid"], "log_index": entry["log_index"], "run": "n/a", "reason": "manual"}]}))
        self.assertEqual(self.run_monitor(), 0)
        self.assertNotIn(title, self.titles())

    def test_a_ledger_artifact_after_a_full_page_of_artifacts_explains_the_entry(self):
        entry = self.world.add_entry(b"release payload")
        self.world.add_run("release.yml", 23, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.world.filler_artifacts = 100
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])

    def test_state_fetch_finds_a_checkpoint_behind_a_full_page_of_self_tests(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("state.json", json.dumps({"tree_size": 3}))
        self.world.runs[monitor.MONITOR_WORKFLOW] = [
            {"id": 1000 + number, "head_branch": "staging", "event": "workflow_dispatch"} for number in range(100)
        ] + [{"id": 46, "head_branch": "staging", "event": "schedule"}]
        self.world.state_zips = {46: archive.getvalue()}
        out = self.root / "fetched.json"
        status = monitor.main(["--github-api", self.base, "--fetch-state", "--state-out", str(out)],
                              {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": "synthetic-token"})
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out.read_text()), {"tree_size": 3})

    def test_a_truncated_discord_reply_is_retried_without_failing_the_scan(self):
        entry = self.world.add_entry(b"signed outside any run")
        self.world.discord_status = "truncated"
        self.assertEqual(self.run_monitor(), 0)
        self.world.discord_status = 204
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(len(self.world.discord), 1)
        self.assertIn(entry["uuid"], self.world.discord[0])
        self.assertEqual(self.titles(), [f"Unexplained release-key signature in Rekor: {entry['uuid']}"])

    def test_missing_checkpoint_fails_without_bootstrap(self):
        self.state.unlink()
        self.assertEqual(self.run_monitor(), 1)
        self.assertIn("checkpoint is missing", self.world.discord[-1])

    def test_blindness_canary_reports_a_ledgered_entry_never_seen(self):
        log_id = hashlib.sha256(monitor.pem_der(self.world.log_pub.read_text())).hexdigest()
        self.world.add_run("native-addons.yml", 9, NOW - timedelta(hours=6), NOW - timedelta(hours=3), [
            {"event": "logged", "log_id": log_id, "log_index": 99, "integrated_time": int((NOW - timedelta(hours=5)).timestamp()),
             "subject": "registry.example/addon@sha256:" + "a" * 64}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), ["Rekor signing monitor is blind to ledgered entries"])

    def test_blindness_canary_reads_the_ledger_of_a_long_running_release(self):
        log_id = hashlib.sha256(monitor.pem_der(self.world.log_pub.read_text())).hexdigest()
        self.move_first_checkpoint(NOW - timedelta(days=20))
        # Created ten days ago (a release waiting on its environment), ended three hours ago.
        self.world.add_run("release.yml", 13, NOW - timedelta(days=10), NOW - timedelta(hours=3), [
            {"event": "logged", "log_id": log_id, "log_index": 99,
             "integrated_time": int((NOW - timedelta(hours=4)).timestamp()),
             "subject": "registry.example/core@sha256:" + "b" * 64}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), ["Rekor signing monitor is blind to ledgered entries"])

    def test_state_fetch_reads_the_newest_staging_scans_checkpoint(self):
        def state_zip(size):
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("state.json", json.dumps({"tree_size": size}))
            return archive.getvalue()

        # Newest first: a dispatch on another branch, a self-test (no checkpoint), a pull request
        # run, then the staging scan whose checkpoint is the one to use.
        self.world.runs[monitor.MONITOR_WORKFLOW] = [
            {"id": 44, "head_branch": "feature", "event": "workflow_dispatch"},
            {"id": 43, "head_branch": "staging", "event": "workflow_dispatch"},
            {"id": 42, "head_branch": "staging", "event": "pull_request"},
            {"id": 41, "head_branch": "staging", "event": "schedule"},
        ]
        self.world.state_zips = {44: state_zip(99), 42: state_zip(98), 41: state_zip(3)}
        out = self.root / "fetched.json"
        status = monitor.main(["--github-api", self.base, "--fetch-state", "--state-out", str(out)],
                              {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": "synthetic-token"})
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out.read_text()), {"tree_size": 3})

    def test_blindness_canary_checks_a_run_that_ended_days_before_the_scan_once(self):
        log_id = hashlib.sha256(monitor.pem_der(self.world.log_pub.read_text())).hexdigest()
        self.move_first_checkpoint(NOW - timedelta(days=10))
        # Created and ended days after the first checkpoint, a week before this scan (an outage).
        self.world.add_run("publish-oci.yml", 14, NOW - timedelta(days=8), NOW - timedelta(days=7), [
            {"event": "logged", "log_id": log_id, "log_index": 99,
             "integrated_time": int((NOW - timedelta(days=7, hours=12)).timestamp()),
             "subject": "registry.example/agent@sha256:" + "c" * 64}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), ["Rekor signing monitor is blind to ledgered entries"])
        self.assertEqual(len(self.world.discord), 1)
        self.assertIn("log index 99", self.world.issues[0]["body"])

    def canary_line(self, log_index, integrated):
        log_id = hashlib.sha256(monitor.pem_der(self.world.log_pub.read_text())).hexdigest()
        return {"event": "logged", "log_id": log_id, "log_index": log_index,
                "integrated_time": int(integrated.timestamp()), "subject": f"registry.example/x{log_index}"}

    def test_blindness_canary_checks_a_run_that_started_before_the_first_checkpoint(self):
        # The first checkpoint was taken ten hours ago, while this release was waiting on its environment.
        self.world.add_run("release.yml", 24, NOW - timedelta(hours=12), NOW - timedelta(hours=3),
                           [self.canary_line(99, NOW - timedelta(hours=5))])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.titles(), ["Rekor signing monitor is blind to ledgered entries"])
        self.assertIn("log index 99", self.world.issues[0]["body"])
        self.assertIn("log index 99", self.world.discord[-1])

    def test_unseen_entries_that_do_not_fit_one_message_rotate_into_later_posts(self):
        lines = [self.canary_line(100 + number, NOW - timedelta(hours=5)) for number in range(40)]
        self.world.add_run("publish-oci.yml", 25, NOW - timedelta(hours=8), NOW - timedelta(hours=3), lines)
        self.assertEqual(self.run_monitor(), 0)
        self.assertTrue(all(len(message) <= 2000 for message in self.world.discord))
        self.assertNotIn("log index 139 ", self.world.discord[0])
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=1)), 0)
        posted = "\n".join(self.world.discord)
        self.assertEqual([number for number in range(100, 140) if f"log index {number} " not in posted], [])

    def test_a_closed_canary_issue_does_not_hide_an_unseen_entry(self):
        self.world.add_run("publish-oci.yml", 15, NOW - timedelta(hours=8), NOW - timedelta(hours=3),
                           [self.canary_line(99, NOW - timedelta(hours=5))])
        self.assertEqual(self.run_monitor(), 0)
        self.world.issues[0]["state"] = "closed"
        # The ledger has aged out; the finding is kept in the checkpoint.
        self.world.runs["publish-oci.yml"].clear()
        self.world.ledgers.clear()
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=1)), 0)
        self.assertEqual(self.titles(), ["Rekor signing monitor is blind to ledgered entries"])
        self.assertIn("log index 99", self.world.issues[1]["body"])
        self.assertIn("log index 99", self.world.discord[-1])
        self.assertEqual(len(self.world.discord), 2)

    def test_a_later_unseen_entry_is_named_on_the_open_canary_issue(self):
        self.world.add_run("publish-oci.yml", 16, NOW - timedelta(hours=8), NOW - timedelta(hours=3),
                           [self.canary_line(99, NOW - timedelta(hours=5))])
        self.assertEqual(self.run_monitor(), 0)
        self.world.add_run("native-addons.yml", 17, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [self.canary_line(100, NOW - timedelta(hours=3))])
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=1)), 0)
        self.assertEqual(len(self.world.issues), 1)
        self.assertIn("log index 100", self.world.issues[0]["comments"][-1])
        self.assertNotIn("log index 99", self.world.issues[0]["comments"][-1])
        self.assertIn("log index 99", self.world.discord[-1])
        self.assertIn("log index 100", self.world.discord[-1])

    def test_an_unseen_entry_is_reported_until_it_appears_in_the_log(self):
        self.world.add_run("publish-oci.yml", 18, NOW - timedelta(hours=8), NOW - timedelta(hours=3),
                           [self.canary_line(2, NOW - timedelta(hours=5))])
        self.assertEqual(self.run_monitor(), 0)
        self.world.discord_status = 500
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=1)), 0)
        self.world.discord_status = 204
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=2)), 0)
        self.assertEqual(len(self.world.discord), 2, "an unseen entry was not reported again")
        self.world.add_entry(b"late", key_pub=self.world.other_pub)
        entry = self.world.add_entry(b"index two", when=NOW - timedelta(hours=5))
        self.world.ledgers[18].append({"event": "sign", "payload_sha256": entry["payload_sha256"]})
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=3)), 0)
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=4)), 0)
        self.assertEqual(len(self.world.discord), 2, "an entry now in the log was still reported")

    def test_the_canary_issue_closes_once_every_entry_it_names_is_seen(self):
        self.world.add_run("publish-oci.yml", 20, NOW - timedelta(hours=8), NOW - timedelta(hours=3),
                           [self.canary_line(2, NOW - timedelta(hours=5)), self.canary_line(3, NOW - timedelta(hours=5))])
        self.assertEqual(self.run_monitor(), 0)
        self.world.add_entry(b"filler", key_pub=self.world.other_pub)
        two = self.world.add_entry(b"index two", when=NOW - timedelta(hours=5))
        self.world.ledgers[20].append({"event": "sign", "payload_sha256": two["payload_sha256"]})
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=1)), 0)
        issue = self.world.issues[0]
        self.assertEqual(issue["state"], "open")
        self.assertIn("log index 2", issue["comments"][-1])
        self.assertNotIn("log index 3", issue["comments"][-1])
        three = self.world.add_entry(b"index three", when=NOW - timedelta(hours=5))
        self.world.ledgers[20].append({"event": "sign", "payload_sha256": three["payload_sha256"]})
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=2)), 0)
        self.assertEqual(issue["state"], "closed")
        self.assertIn("log index 3", issue["comments"][-1])
        self.assertEqual(len(self.world.issues), 1)

    def test_a_rerun_that_ends_later_is_checked_again(self):
        self.world.add_run("publish-oci.yml", 19, NOW - timedelta(hours=8), NOW - timedelta(hours=3), [])
        self.assertEqual(self.run_monitor(), 0)
        self.world.runs["publish-oci.yml"].clear()
        self.world.add_run("publish-oci.yml", 19, NOW - timedelta(hours=8), NOW - timedelta(hours=1),
                           [self.canary_line(99, NOW - timedelta(hours=2))])
        self.assertEqual(self.run_monitor(now=NOW + timedelta(hours=2)), 0)
        self.assertEqual(self.titles(), ["Rekor signing monitor is blind to ledgered entries"])

    def test_entries_that_do_not_fit_one_discord_message_are_posted_on_later_runs(self):
        entries = [self.world.add_entry(f"signed outside any run {number}".encode()) for number in range(30)]
        self.assertEqual(self.run_monitor(), 0)
        self.assertTrue(all(len(message) <= 2000 for message in self.world.discord))
        self.assertLess(sum(entry["uuid"] in self.world.discord[0] for entry in entries), len(entries))
        for _ in range(3):
            self.assertEqual(self.run_monitor(), 0)
        posted = "\n".join(self.world.discord)
        self.assertEqual([entry["uuid"] for entry in entries if entry["uuid"] not in posted], [])
        self.assertEqual(len(self.world.issues), len(entries))

    def test_canary_ignores_entries_from_other_logs_and_before_the_first_checkpoint(self):
        log_id = hashlib.sha256(monitor.pem_der(self.world.log_pub.read_text())).hexdigest()
        self.world.add_run("release.yml", 10, NOW - timedelta(hours=9), NOW - timedelta(hours=3), [
            {"event": "logged", "log_id": "public-good", "log_index": 5, "integrated_time": int(NOW.timestamp()) - 7200},
            {"event": "logged", "log_id": log_id, "log_index": 6,
             "integrated_time": int((NOW - timedelta(hours=11)).timestamp())}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])


if __name__ == "__main__":
    unittest.main()
