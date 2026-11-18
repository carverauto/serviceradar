"""The Rekor signing monitor against a synthetic log and a synthetic GitHub API.

Every key is a throwaway generated per run; the log, its signed tree head, the workflow runs,
their signing-ledger artifacts and the issue tracker are local stand-ins on loopback.
Owner: build/ci/rekor_signing_monitor.py.
"""

import base64
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
        self.runs = {workflow: [] for workflow in monitor.SIGNING_WORKFLOWS}
        self.ledgers = {}
        self.issues = []
        self.labels = {"security"}
        self.discord = []
        self.discord_status = 204
        self.state_zips = {}
        self.blob_requests_with_auth = 0

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

    def add_run(self, workflow, run_id, start, end, ledger=None):
        self.runs[workflow].insert(0, {"id": run_id, "created_at": f"{start:%Y-%m-%dT%H:%M:%SZ}",
                                    "updated_at": f"{(end or NOW):%Y-%m-%dT%H:%M:%SZ}",
                                    "status": "completed" if end else "in_progress",
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

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else None

    def do_GET(self):
        world, path = self.server.world, self.path.split("?")[0]
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        prefix = f"/repos/{REPOSITORY}"
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
            per_page, page = int(query.get("per_page", ["30"])[0]), int(query.get("page", ["1"])[0])
            return self.reply(200, {"workflow_runs": runs[(page - 1) * per_page:page * per_page]})
        if path.startswith(prefix + "/labels/"):
            name = urllib.parse.unquote(path.split("/")[-1])
            return self.reply(200, {"name": name}) if name in world.labels else self.reply(404, {})
        if path.startswith("/state/"):
            return self.reply(200, raw=world.state_zips[int(path.split("/")[-1])])
        if path.startswith(prefix + "/actions/runs/"):
            run_id = int(path.split("/")[-2])
            if run_id in world.state_zips:
                return self.reply(200, {"artifacts": [{
                    "name": monitor.STATE_ARTIFACT, "expired": False,
                    "archive_download_url": f"http://127.0.0.1:{self.server.server_port}/state/{run_id}"}]})
            artifacts = [] if run_id not in world.ledgers else [{
                "name": f"signing-ledger-x-publish-{run_id}-1", "expired": False,
                "archive_download_url": f"http://127.0.0.1:{self.server.server_port}{prefix}/actions/artifacts/{run_id}/zip"}]
            return self.reply(200, {"artifacts": artifacts})
        if path.startswith(prefix + "/actions/artifacts/"):
            run_id = path.split("/")[-2]
            return self.reply(302, headers=[("Location", f"http://127.0.0.1:{self.server.server_port}/blob/{run_id}")])
        if path.startswith("/blob/"):
            if self.headers.get("Authorization"):
                world.blob_requests_with_auth += 1
            return self.reply(200, raw=world.ledger_zip(int(path.split("/")[-1])))
        if path == prefix + "/issues":
            return self.reply(200, [issue for issue in world.issues if issue["state"] == "open"])
        self.reply(404, {})

    def do_POST(self):
        world, path = self.server.world, self.path.split("?")[0]
        prefix = f"/repos/{REPOSITORY}"
        payload = self.body()
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
            if world.discord_status == 204:
                world.discord.append(payload["content"])
            return self.reply(world.discord_status)
        self.reply(404, {})

    def do_PATCH(self):
        world, path = self.server.world, self.path.split("?")[0]
        payload = self.body()
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

    def test_entry_in_a_finished_runs_ledger_is_explained(self):
        entry = self.world.add_entry(b"release payload")
        self.world.add_run("release.yml", 7, NOW - timedelta(hours=4), NOW - timedelta(hours=2),
                           [{"event": "sign", "payload_sha256": entry["payload_sha256"]}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])
        self.assertEqual(self.world.blob_requests_with_auth, 0, "the GitHub token followed the artifact redirect")

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

    def test_canary_ignores_entries_from_other_logs_and_before_the_first_checkpoint(self):
        log_id = hashlib.sha256(monitor.pem_der(self.world.log_pub.read_text())).hexdigest()
        self.world.add_run("release.yml", 10, NOW - timedelta(hours=30), NOW - timedelta(hours=3), [
            {"event": "logged", "log_id": "public-good", "log_index": 5, "integrated_time": int(NOW.timestamp()) - 7200},
            {"event": "logged", "log_id": log_id, "log_index": 6,
             "integrated_time": int((NOW - timedelta(hours=20)).timestamp())}])
        self.assertEqual(self.run_monitor(), 0)
        self.assertEqual(self.world.issues, [])


if __name__ == "__main__":
    unittest.main()
