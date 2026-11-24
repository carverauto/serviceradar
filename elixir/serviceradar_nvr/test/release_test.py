"""Execute the shipped release with synthetic media and no control-plane services."""
import base64
import hashlib
import http.client
import http.server
import json
import os
import signal
import socket
import ssl
import struct
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


class NVRReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.release = Path(cls.temp.name) / "release"
        cls.release.mkdir()
        with tarfile.open(os.environ["NVR_RELEASE"]) as archive:
            archive.extractall(cls.release, filter="data")
        cls.binary = str(cls.release / "bin/serviceradar_nvr")
        cls.probe = str(Path(os.environ["NVR_PROBE"]).resolve())
        cls.ffmpeg = str(Path("third_party/membrane/media_test_tools/ffmpeg").resolve())
        client = Path(cls.temp.name) / "client"
        client.mkdir()
        with tarfile.open(os.environ["NVR_CLIENT_RELEASE"]) as archive:
            archive.extractall(client, filter="data")
        cls.client_binary = str(client / "bin/serviceradar_nvr_client")
        cls.client_probe = str(Path(os.environ["NVR_CLIENT_PROBE"]).resolve())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.spool = self.root / "spool"
        self.spool.mkdir(mode=0o700)
        self.generation = "00000000-0000-4000-8000-000000000077"
        self.recovery = self.root / "recovery.json"
        self.ready = ('{"generation":"' + self.generation + '","state":"ready"}').encode()
        self.recovery.write_bytes(self.ready)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.env = {
            "PATH": "/usr/bin:/bin", "HOME": str(self.root), "TMPDIR": str(self.root),
            "RELEASE_COOKIE": "synthetic_nvr_cookie", "ERL_CRASH_DUMP": "/dev/null",
            "SERVICERADAR_NVR_SPOOL_ROOT": str(self.spool),
            "SERVICERADAR_NVR_RECOVERY_GENERATION": self.generation,
            "SERVICERADAR_NVR_RECOVERY_STATE_FILE": str(self.recovery),
            "SERVICERADAR_NVR_STORAGE_ID": "00000000-0000-4000-8000-000000000011",
            "NVR_TEST_EXPECTED_STORAGE_ID": "00000000-0000-4000-8000-000000000011",
            "SERVICERADAR_NVR_MAX_SESSIONS": "2", "SERVICERADAR_NVR_HEALTH_PORT": str(port),
            # Rotation and capacity cases are sized for eight-fragment blocks.
            "SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS": "8", "NVR_TEST_ROTATION_FRAGMENTS": "[8, 8, 1]",
            "NVR_TEST_RECEIPT": str(self.root / "receipt.json"),
            "NVR_TEST_H264": str(self.root / "synthetic.h264"),
            "NVR_TEST_MP4": str(self.root / "recovered.mp4"),
        }

    def run_probe(self, mode):
        env = self.env | {"NVR_TEST_MODE": mode}
        result = subprocess.run([self.binary, "eval", f'Code.require_file("{self.probe}")'],
                                env=env, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b"NVR_RELEASE_PROBE_OK", result.stdout)

    def test_recovery_gate_refuses_untrusted_state_without_changing_storage(self):
        self.run_probe("recovery_ready")
        marker = self.spool / ".storage-id"
        before = (marker.read_bytes(), marker.stat().st_ino, marker.stat().st_mtime_ns)
        for raw in (b"", b"x" * 257, self.ready + b"\n",
                    self.ready.replace(b"ready", b"closed"),
                    self.ready.replace(b"000000000077", b"000000000078"),
                    self.ready[:-1] + b',"state":"ready"}'):
            with self.subTest(raw=raw):
                self.recovery.write_bytes(raw)
                self.run_probe("recovery_closed")
                self.assertEqual(self.recovery.read_bytes(), raw)
        self.recovery.unlink()
        self.run_probe("recovery_closed")
        self.recovery.mkdir()
        self.run_probe("recovery_closed")
        del self.env["SERVICERADAR_NVR_RECOVERY_GENERATION"]
        del self.env["SERVICERADAR_NVR_RECOVERY_STATE_FILE"]
        self.run_probe("recovery_closed")
        self.assertEqual(list(self.spool.iterdir()), [marker])
        self.assertEqual((marker.read_bytes(), marker.stat().st_ino, marker.stat().st_mtime_ns), before)

    def test_recovery_gate_observes_live_projection_and_pins_generation_until_restart(self):
        # Model a projected-volume symlink; replacing its target changes the live view.
        projected = self.root / "projected-state.json"
        projected.symlink_to(self.recovery)
        self.env["SERVICERADAR_NVR_RECOVERY_STATE_FILE"] = str(projected)
        self.run_probe("recovery_transition")
        next_generation = "00000000-0000-4000-8000-000000000078"
        self.assertEqual(self.recovery.read_bytes(), self.ready.replace(self.generation.encode(), next_generation.encode()))
        self.env["SERVICERADAR_NVR_RECOVERY_GENERATION"] = next_generation
        self.run_probe("recovery_ready")

    def bootstrap_document(self):
        return {"binding_id": "00000000-0000-4000-8000-000000000022",
                "binding_sha256": "ab" * 32, "kind": "local_storage_bootstrap_prepared",
                "operation_id": "00000000-0000-4000-8000-000000000033",
                "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"], "version": 1}

    def bootstrap(self, document=None, raw=None, reference=None):
        document = self.bootstrap_document() if document is None else document
        raw = json.dumps(document, sort_keys=True, separators=(",", ":")).encode() if raw is None else raw
        reference = {key: document[key] for key in ("storage_id", "binding_id", "binding_sha256")} if reference is None else reference
        (self.root / "bootstrap-input.json").write_bytes(raw)
        (self.root / "bootstrap-reference.json").write_text(json.dumps(reference))
        self.run_probe("storage_bootstrap")
        return json.loads((self.root / "bootstrap-result.json").read_bytes()), raw

    def test_bootstrap_retains_exact_receipt_across_restart_and_keeps_admission_closed(self):
        result, raw = self.bootstrap()
        self.assertEqual(result, {"result": "installed", "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                  "preparation_sha256": hashlib.sha256(raw).hexdigest()})
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".bootstrap-preparation.json", ".storage-id"])
        preparation = self.spool / ".bootstrap-preparation.json"
        marker = self.spool / ".storage-id"
        self.assertEqual(preparation.read_bytes(), raw)
        self.assertEqual(marker.read_text(), self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
        before = [(p.stat().st_ino, p.stat().st_mtime_ns) for p in (preparation, marker)]
        self.assertEqual(preparation.stat().st_mode & 0o777, 0o600)
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        retry, _ = self.bootstrap()
        self.assertEqual(retry, result)
        self.assertEqual([(p.stat().st_ino, p.stat().st_mtime_ns) for p in (preparation, marker)], before)
        for change in ({"operation_id": "00000000-0000-4000-8000-000000000044"},
                       {"binding_id": "00000000-0000-4000-8000-000000000055"}):
            with self.subTest(change=change):
                conflict, _ = self.bootstrap(self.bootstrap_document() | change)
                self.assertEqual(conflict, {"result": "refused", "reason": ":storage_bootstrap_conflict"})
                self.assertEqual(preparation.read_bytes(), raw)
                self.assertEqual([(p.stat().st_ino, p.stat().st_mtime_ns) for p in (preparation, marker)], before)

    def test_bootstrap_refuses_untrusted_bytes_and_existing_spools_without_writing(self):
        document = self.bootstrap_document()
        canonical = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        invalid = [b"", b"x" * 513, canonical + b"\n",
                   canonical[:-1] + b',"version":1}',
                   json.dumps(document | {"extra": True}, sort_keys=True, separators=(",", ":")).encode(),
                   json.dumps(document | {"operation_id": "invalid"}, sort_keys=True, separators=(",", ":")).encode(),
                   json.dumps(document | {"storage_id": "00000000-0000-4000-8000-000000000099"},
                              sort_keys=True, separators=(",", ":")).encode()]
        for raw in invalid:
            with self.subTest(raw=raw):
                result, _ = self.bootstrap(raw=raw)
                self.assertEqual(result, {"result": "refused", "reason": ":invalid_storage_bootstrap_preparation"})
                self.assertEqual(list(self.spool.iterdir()), [])
        invalid_digest, _ = self.bootstrap(document | {"binding_sha256": "AB" * 32})
        self.assertEqual(invalid_digest, {"result": "refused", "reason": ":invalid_storage_bootstrap_preparation"})
        self.assertEqual(list(self.spool.iterdir()), [])
        self.spool.chmod(0o755)
        not_private, _ = self.bootstrap()
        self.assertEqual(not_private, {"result": "refused", "reason": ":storage_bootstrap_not_private"})
        self.assertEqual(list(self.spool.iterdir()), [])
        self.spool.chmod(0o700)
        for name, data in ((".storage-id", (document["storage_id"] + "\n").encode()),
                           ("retained-media", b"synthetic retained bytes")):
            with self.subTest(existing=name):
                path = self.spool / name
                path.write_bytes(data)
                path.chmod(0o600)
                result, _ = self.bootstrap()
                self.assertEqual(result, {"result": "refused", "reason": ":storage_bootstrap_requires_new_root"})
                self.assertEqual([p.name for p in self.spool.iterdir()], [name])
                self.assertEqual(path.read_bytes(), data)
                path.unlink()

    def test_bootstrap_resumes_complete_preparation_but_preserves_incomplete_or_unsafe_files(self):
        document = self.bootstrap_document()
        raw = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        preparation = self.spool / ".bootstrap-preparation.json"
        marker = self.spool / ".storage-id"
        preparation.write_bytes(raw)
        preparation.chmod(0o600)
        result, _ = self.bootstrap()
        self.assertEqual(result["result"], "installed")
        self.assertEqual(marker.read_text(), document["storage_id"] + "\n")
        # These are persisted interruption states, not a physical crash/durability claim.
        for target, data, reason in ((preparation, b'{"binding_id":', ":storage_bootstrap_conflict"),
                                     (marker, b"partial", ":storage_bootstrap_conflict")):
            with self.subTest(partial=target.name):
                original = target.read_bytes()
                if target == preparation:
                    marker.unlink()
                target.write_bytes(data)
                result, _ = self.bootstrap()
                self.assertEqual(result, {"result": "refused", "reason": reason})
                self.assertEqual(target.read_bytes(), data)
                if target == preparation:
                    self.assertFalse(marker.exists())
                target.write_bytes(original)
                if target == preparation:
                    resumed, _ = self.bootstrap()
                    self.assertEqual(resumed["result"], "installed")
        marker.unlink()
        preparation.chmod(0o644)
        result, _ = self.bootstrap()
        self.assertEqual(result, {"result": "refused", "reason": ":storage_bootstrap_not_private"})
        self.assertFalse(marker.exists())
        preparation.chmod(0o600)
        outside = self.root / "retained-preparation"
        preparation.rename(outside)
        preparation.symlink_to(outside)
        result, _ = self.bootstrap()
        self.assertEqual(result, {"result": "refused", "reason": ":invalid_storage_bootstrap_file"})
        self.assertTrue(preparation.is_symlink())
        self.assertEqual(outside.read_bytes(), raw)
        self.assertFalse(marker.exists())
        preparation.unlink()
        os.link(outside, preparation)
        result, _ = self.bootstrap()
        self.assertEqual(result, {"result": "refused", "reason": ":invalid_storage_bootstrap_file"})
        self.assertEqual(outside.read_bytes(), raw)
        self.assertFalse(marker.exists())

    def bootstrap_acknowledgement(self, raw=None):
        if raw is None:
            preparation = (self.spool / ".bootstrap-preparation.json").read_bytes()
            document = self.bootstrap_document()
            acknowledgement = {"version": 1, "kind": "local_storage_bootstrap_installed",
                               "operation_id": document["operation_id"], "storage_id": document["storage_id"],
                               "preparation_sha256": hashlib.sha256(preparation).hexdigest()}
            raw = json.dumps(acknowledgement, sort_keys=True, separators=(",", ":")).encode()
        (self.root / "bootstrap-ack-input.json").write_bytes(raw)
        self.run_probe("storage_bootstrap_acknowledgement")
        return json.loads((self.root / "bootstrap-result.json").read_bytes()), raw

    def bootstrap_evidence(self):
        self.run_probe("storage_bootstrap_evidence")
        return json.loads((self.root / "bootstrap-result.json").read_bytes())

    def test_bootstrap_acknowledgement_survives_restart_with_exact_bytes_and_bounded_accounting(self):
        installed, preparation = self.bootstrap()
        paths = [self.spool / name for name in (".bootstrap-preparation.json", ".storage-id")]
        before = [(p.stat().st_ino, p.stat().st_mtime_ns) for p in paths]
        expected = {"result": "observed", "storage_id": self.bootstrap_document()["storage_id"],
                    "operation_id": self.bootstrap_document()["operation_id"],
                    "preparation_sha256": hashlib.sha256(preparation).hexdigest(),
                    "preparation": preparation.decode(), "acknowledgement": None,
                    "acknowledgement_sha256": None, "state": "prepared",
                    "used_control_bytes": 37 + len(preparation), "pending_control_bytes": 512}
        self.assertEqual(self.bootstrap_evidence(), expected)
        self.assertEqual([(p.stat().st_ino, p.stat().st_mtime_ns) for p in paths], before)
        result, acknowledgement = self.bootstrap_acknowledgement()
        expected.update(acknowledgement=acknowledgement.decode(),
                        acknowledgement_sha256=hashlib.sha256(acknowledgement).hexdigest(),
                        state="installation_acknowledged", used_control_bytes=37 + len(preparation) + len(acknowledgement),
                        pending_control_bytes=0)
        self.assertEqual(result, expected)
        path = self.spool / ".bootstrap-acknowledgement.json"
        self.assertEqual(path.read_bytes(), acknowledgement)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        paths.append(path)
        before = [(p.stat().st_ino, p.stat().st_mtime_ns) for p in paths]
        self.assertEqual(self.bootstrap_evidence(), expected)
        retry, _ = self.bootstrap_acknowledgement(acknowledgement)
        self.assertEqual(retry, expected)
        retry, _ = self.bootstrap()
        self.assertEqual(retry, installed)
        self.assertEqual([(p.stat().st_ino, p.stat().st_mtime_ns) for p in paths], before)

    def test_bootstrap_acknowledgement_refuses_untrusted_or_mismatched_bytes_without_writing(self):
        _, preparation = self.bootstrap()
        document = {"version": 1, "kind": "local_storage_bootstrap_installed",
                    "operation_id": self.bootstrap_document()["operation_id"],
                    "storage_id": self.bootstrap_document()["storage_id"],
                    "preparation_sha256": hashlib.sha256(preparation).hexdigest()}
        canonical = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        invalid = [b"", b"x" * 513, canonical + b"\n", canonical[:-1] + b',"version":1}']
        for change in ({"extra": True}, {"version": 2}, {"kind": "local_storage_bootstrap_prepared"},
                       {"operation_id": "00000000-0000-4000-8000-000000000044"},
                       {"storage_id": "00000000-0000-4000-8000-000000000055"},
                       {"preparation_sha256": "cd" * 32}):
            invalid.append(json.dumps(document | change, sort_keys=True, separators=(",", ":")).encode())
        paths = list(self.spool.iterdir())
        before = [(p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in paths]
        for raw in invalid:
            with self.subTest(raw=raw):
                result, _ = self.bootstrap_acknowledgement(raw)
                self.assertEqual(result, {"result": "refused", "reason": ":invalid_storage_bootstrap_acknowledgement"})
                self.assertFalse((self.spool / ".bootstrap-acknowledgement.json").exists())
                self.assertEqual([(p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in paths], before)
        reference_path = self.root / "bootstrap-reference.json"
        original = reference_path.read_bytes()
        reference_path.write_text(json.dumps(json.loads(original) | {"binding_sha256": "ef" * 32}))
        result, _ = self.bootstrap_acknowledgement(canonical)
        self.assertEqual(result, {"result": "refused", "reason": ":invalid_storage_bootstrap_preparation"})
        reference_path.write_bytes(original)
        media = self.spool / "retained-media"
        media.write_bytes(b"synthetic retained media")
        result, _ = self.bootstrap_acknowledgement(canonical)
        self.assertEqual(result, {"result": "refused", "reason": ":storage_bootstrap_requires_new_root"})
        self.assertEqual(media.read_bytes(), b"synthetic retained media")
        self.assertFalse((self.spool / ".bootstrap-acknowledgement.json").exists())

    def test_bootstrap_acknowledgement_preserves_interrupted_and_unsafe_records(self):
        _, preparation = self.bootstrap()
        _, acknowledgement = self.bootstrap_acknowledgement()
        path = self.spool / ".bootstrap-acknowledgement.json"
        # Persisted interruption states exercise restart refusal, not physical crash durability.
        path.write_bytes(b'{"kind":')
        for operation in (self.bootstrap_evidence, lambda: self.bootstrap_acknowledgement(acknowledgement)[0],
                          lambda: self.bootstrap()[0]):
            self.assertEqual(operation(), {"result": "refused", "reason": ":invalid_storage_bootstrap_acknowledgement"})
            self.assertEqual(path.read_bytes(), b'{"kind":')
        path.write_bytes(acknowledgement)
        before = (path.stat().st_ino, path.stat().st_mtime_ns)
        result, _ = self.bootstrap_acknowledgement(acknowledgement)
        self.assertEqual(result["state"], "installation_acknowledged")
        self.assertEqual((path.stat().st_ino, path.stat().st_mtime_ns), before)
        for name in (".bootstrap-preparation.json", ".storage-id"):
            target = self.spool / name
            original = target.read_bytes()
            target.unlink()
            for operation in (self.bootstrap_evidence, lambda: self.bootstrap_acknowledgement(acknowledgement)[0],
                              lambda: self.bootstrap()[0]):
                self.assertEqual(operation()["result"], "refused")
                self.assertFalse(target.exists())
                self.assertEqual(path.read_bytes(), acknowledgement)
            target.write_bytes(original)
            target.chmod(0o600)
        changed = self.bootstrap_document() | {"operation_id": "00000000-0000-4000-8000-000000000066"}
        (self.spool / ".bootstrap-preparation.json").write_text(json.dumps(changed, sort_keys=True, separators=(",", ":")))
        self.assertEqual(self.bootstrap_evidence(), {"result": "refused", "reason": ":invalid_storage_bootstrap_acknowledgement"})
        (self.spool / ".bootstrap-preparation.json").write_bytes(preparation)
        path.chmod(0o644)
        result, _ = self.bootstrap_acknowledgement(acknowledgement)
        self.assertEqual(result, {"result": "refused", "reason": ":storage_bootstrap_not_private"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        path.chmod(0o600)
        outside = self.root / "retained-acknowledgement"
        path.rename(outside)
        for link in (lambda: path.symlink_to(outside), lambda: os.link(outside, path)):
            link()
            result, _ = self.bootstrap_acknowledgement(acknowledgement)
            self.assertEqual(result, {"result": "refused", "reason": ":invalid_storage_bootstrap_file"})
            self.assertEqual(outside.read_bytes(), acknowledgement)
            self.assertTrue(path.exists())
            path.unlink()

    def publication_server(self, actions, present_ca=False):
        self.run_probe("delivery_certificates")
        requests = []
        root = self.root
        token = "synthetic-nvr-publication-delivery-token"
        client_der = ssl.PEM_cert_to_DER_cert((root / "client.pem").read_text())
        expected_peer = hashlib.sha256(client_der).digest()
        closed = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["content-length"]))
                requests.append((self.path, self.headers.get("authorization"), body,
                                 hashlib.sha256(self.connection.getpeercert(binary_form=True)).digest()))
                action = actions(body) if callable(actions) else actions.pop(0) if actions else 200
                if action == "drop":
                    self.close_connection = True
                    return
                if action == "stall":
                    (root / "request-started").touch()
                    self.connection.settimeout(35)
                    try:
                        if self.connection.recv(1) == b"":
                            closed.set()
                    except (OSError, TimeoutError):
                        pass
                    return
                ack = json.dumps({"version": 1, "kind": "intent_accepted",
                                  "operation_id": json.loads(body)["operation_id"],
                                  "intent_sha256": hashlib.sha256(body).hexdigest()},
                                 sort_keys=True, separators=(",", ":")).encode()
                status = action if isinstance(action, int) else 200
                if action == "wrong_ack":
                    other = json.loads(ack)
                    other["intent_sha256"] = "0" * 64
                    ack = json.dumps(other, sort_keys=True, separators=(",", ":")).encode()
                if action == "oversized":
                    ack = b"x" * 513
                if action == "oversized_503":
                    status, ack = 503, b"x" * 4096
                self.send_response(status)
                self.send_header("content-length", str(len(ack)))
                if status == 302:
                    self.send_header("location", "/must-not-follow")
                self.end_headers()
                self.wfile.write(ack)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        chain = root / "server.pem"
        if present_ca:
            chain = root / "server-chain.pem"
            chain.write_text((root / "server.pem").read_text() + (root / "client-ca.pem").read_text())
        context.load_cert_chain(chain, root / "server-key.pem")
        context.load_verify_locations(root / "server-ca.pem")
        context.verify_mode = ssl.CERT_REQUIRED
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.addCleanup(stop)
        document = {"host": "localhost", "port": server.server_port,
                    "ca_file": str(root / "client-ca.pem"), "cert_file": str(root / "client.pem"),
                    "key_file": str(root / "client-key.pem")}
        config = root / "delivery.json"
        config.write_text(json.dumps(document))
        (root / "delivery-token").write_text(token)
        self.env["SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE"] = str(config)
        self.env["SERVICERADAR_NVR_PUBLICATION_TOKEN_FILE"] = str(root / "delivery-token")
        return requests, document, expected_peer, closed

    def delivery_block(self):
        block = self.record_publication_block()
        self.run_probe("publication_prepare")
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        return block

    def start_scheduler(self):
        self.env["SERVICERADAR_NVR_PUBLICATION_AUTO_DELIVERY"] = "true"
        status = self.root / "scheduler-status.json"
        status.unlink(missing_ok=True)
        log = open(self.root / "scheduler.log", "ab")
        self.addCleanup(log.close)
        proc = subprocess.Popen([self.binary, "eval", f'Code.require_file("{self.probe}")'],
                                env=self.env | {"NVR_TEST_MODE": "scheduler_watch"},
                                stdout=log, stderr=subprocess.STDOUT)

        def stop():
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=15)
        self.addCleanup(stop)
        return proc

    def wait_scheduler(self, proc, condition, timeout=20):
        deadline = time.monotonic() + timeout
        status = None
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                self.fail((self.root / "scheduler.log").read_text())
            path = self.root / "scheduler-status.json"
            if path.exists():
                status = json.loads(path.read_text())
                if condition(status):
                    return status
            time.sleep(0.05)
        self.fail(f"scheduler condition timed out; last status: {status}")

    def test_scheduler_advances_past_failed_intents_and_preserves_other_states(self):
        self.make_media(510)
        self.run_probe("rotation")
        self.run_probe("publication_page_setup")
        first, second, damaged = sorted(p for p in self.spool.iterdir() if p.is_dir())
        (second / "publication-ack.json").unlink()
        (damaged / "publication.json").write_bytes(b"partial")
        unprepared = self.spool / ("f" * 64)
        unprepared.mkdir(mode=0o700)
        evidence = {p: p.read_bytes() for p in self.spool.rglob("*") if p.is_file()}

        # The first intent is refused until a later block is acknowledged. A
        # coordinator that pins its cursor on error can never satisfy this.
        def response(body):
            if body == (first / "publication.json").read_bytes() and not (second / "publication-ack.json").exists():
                return 409
            return 200

        requests, _, _, _ = self.publication_server(response)
        proc = self.start_scheduler()
        self.wait_scheduler(proc, lambda s: s["delivered"] == 2 and s["steps"] >= 8)
        self.assertEqual([r[2] for r in requests], [(first / "publication.json").read_bytes(),
                                                  (second / "publication.json").read_bytes(),
                                                  (first / "publication.json").read_bytes()])
        for block in [first, second]:
            intent = (block / "publication.json").read_bytes()
            self.assertEqual(json.loads((block / "publication-ack.json").read_bytes()), {
                "version": 1, "kind": "intent_accepted", "operation_id": json.loads(intent)["operation_id"],
                "intent_sha256": hashlib.sha256(intent).hexdigest()})
        self.assertEqual({p: p.read_bytes() for p in evidence}, evidence)
        self.assertEqual(list(unprepared.iterdir()), [])
        self.assertFalse((damaged / "publication-ack.json").exists())
        proc.terminate()
        proc.wait(timeout=15)
        restarted = self.start_scheduler()
        self.wait_scheduler(restarted, lambda s: s["steps"] >= 4)
        self.assertEqual(len(requests), 3, "restart redelivered an accepted or unresolved item")

    def test_scheduler_restart_keeps_one_admitted_worker(self):
        block = self.delivery_block()

        def response(_body):
            (self.root / "request-started").touch()
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                if (self.root / "scheduler-restarted").exists():
                    return 200
                time.sleep(0.02)
            return 503

        requests, _, _, _ = self.publication_server(response)
        self.env["SERVICERADAR_NVR_PUBLICATION_AUTO_DELIVERY"] = "true"
        self.run_probe("scheduler_restart")
        self.assertTrue((self.root / "scheduler-restarted").exists())
        self.assertTrue((block / "publication-ack.json").exists())
        self.assertEqual(len(requests), 1, "coordinator loss duplicated an admitted delivery")

    def test_scheduler_backs_off_and_recovers_retained_intent_after_vm_loss(self):
        block = self.delivery_block()
        intent = (block / "publication.json").read_bytes()
        actions = [409, 409, "stall"]
        requests, _, _, closed = self.publication_server(actions)
        proc = self.start_scheduler()
        status = self.wait_scheduler(proc, lambda s: s["failures"] == 2)
        self.assertGreaterEqual(status["delay_ms"], 4000)
        self.assertLess(status["delay_ms"], 5000)
        self.assertEqual(len(requests), 2)
        self.wait_scheduler(proc, lambda s: (self.root / "request-started").exists())
        self.assertFalse((block / "publication-ack.json").exists())
        proc.kill()
        proc.wait(timeout=15)
        self.assertTrue(closed.wait(2), "VM loss retained a TLS connection")
        restarted = self.start_scheduler()
        self.wait_scheduler(restarted, lambda s: s["delivered"] == 1 and s["steps"] >= 2)
        self.assertEqual([r[2] for r in requests], [intent] * 4)
        self.assertEqual((block / "publication.json").read_bytes(), intent)
        self.assertTrue((block / "publication-ack.json").exists())

    def test_delivery_retries_identical_intent_over_mtls_and_retains_ack_after_restart(self):
        block = self.delivery_block()
        intent = (block / "publication.json").read_bytes()
        requests, _, peer, _ = self.publication_server(["drop", "oversized_503", 200])
        self.run_probe("delivery")
        ack = block / "publication-ack.json"
        expected = json.dumps({"version": 1, "kind": "intent_accepted",
                               "operation_id": json.loads(intent)["operation_id"],
                               "intent_sha256": hashlib.sha256(intent).hexdigest()},
                              sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(ack.read_bytes(), expected)
        inode = ack.stat().st_ino
        self.assertEqual(len(requests), 3)
        self.run_probe("delivery")
        self.assertEqual(len(requests), 4)  # Retained correlation alone is not authenticated origin.
        self.assertEqual(ack.read_bytes(), expected)
        self.assertEqual(ack.stat().st_ino, inode)
        self.assertEqual(requests, [("/v1/local-publication-intents",
                                    "Bearer synthetic-nvr-publication-delivery-token", intent, peer)] * 4)

    def test_delivery_refuses_permanent_or_uncorrelated_responses_and_bounds_retries(self):
        block = self.delivery_block()
        self.run_probe("delivery")
        self.assertEqual(Path(self.env["NVR_TEST_MP4"] + ".delivery").read_text(), ":nvr_delivery_not_configured")
        actions = []
        requests, document, _, _ = self.publication_server(actions)
        evidence = {p.name: p.read_bytes() for p in block.iterdir()}
        for action, count, expected in [
                (401, 1, ":nvr_delivery_status, 401"), (409, 1, ":nvr_delivery_status, 409"),
                (302, 1, ":nvr_delivery_status, 302"),
                ("wrong_ack", 1, ":invalid_publication_acknowledgement"),
                ("oversized", 1, ":invalid_publication_acknowledgement"),
                (503, 3, ":nvr_delivery_status, 503"), (429, 3, ":nvr_delivery_status, 429")]:
            with self.subTest(action=action):
                actions[:] = [action] * count
                before = len(requests)
                self.run_probe("delivery")
                self.assertEqual(len(requests) - before, count)
                self.assertIn(expected, Path(self.env["NVR_TEST_MP4"] + ".delivery").read_text())
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, evidence)
        # A valid chain for the wrong hostname must not receive bearer or intent bytes.
        document["host"] = "127.0.0.1"
        Path(self.env["SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE"]).write_text(json.dumps(document))
        before = len(requests)
        self.run_probe("delivery")
        self.assertEqual(len(requests), before)
        self.assertEqual(Path(self.env["NVR_TEST_MP4"] + ".delivery").read_text(), ":nvr_delivery_transport")
        self.assertFalse((block / "publication-ack.json").exists())

    def test_recovery_closure_stops_delivery_retry_and_ack_persistence(self):
        block = self.delivery_block()
        evidence = {p.name: p.read_bytes() for p in block.iterdir()}
        response_status = 503

        def response(_body):
            replacement = self.root / "recovery.next"
            replacement.write_bytes(self.ready.replace(b"ready", b"closed"))
            replacement.replace(self.recovery)
            return response_status

        requests, _, _, _ = self.publication_server(response)
        for response_status in (503, 200):
            with self.subTest(status=response_status):
                self.recovery.write_bytes(self.ready)
                before = len(requests)
                self.run_probe("delivery")
                self.assertEqual(len(requests) - before, 1, "delivery retried after observing closure")
                self.assertEqual(Path(self.env["NVR_TEST_MP4"] + ".delivery").read_text(), ":nvr_recovery_closed")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, evidence)

    def test_delivery_rejects_receiver_signed_by_replaced_ca_in_same_vm(self):
        block = self.delivery_block()
        intent = (block / "publication.json").read_bytes()
        for present_ca in [False, True]:
            with self.subTest(present_ca=present_ca):
                requests, _, _, _ = self.publication_server([], present_ca)
                self.run_probe("delivery_ca_replacement")
                self.assertEqual(Path(self.env["NVR_TEST_MP4"] + ".delivery").read_text(),
                                 "ok :nvr_delivery_transport")
                self.assertEqual([body for _, _, body, _ in requests], [intent])

    def test_delivery_deadline_survives_caller_loss_without_blocking_capture(self):
        block = self.delivery_block()
        source = self.decode(self.env["NVR_TEST_H264"])
        requests, _, _, closed = self.publication_server(["stall", 200])
        started = time.monotonic()
        self.run_probe("delivery_caller_loss")
        self.assertLess(time.monotonic() - started, 40)
        self.assertTrue(closed.wait(2), "expired worker retained its TLS socket")
        self.assertEqual(len(requests), 2)
        self.assertTrue((block / "publication-ack.json").exists())
        captured = Path(self.env["NVR_TEST_RECEIPT"]).read_text()
        output = self.root / "delivery-capture.mp4"
        output.write_bytes((Path(captured) / "init.mp4").read_bytes() +
                           (Path(captured) / "media.m4s").read_bytes())
        self.assertEqual(self.decode(output), source)

    def test_media_survives_release_restart_and_decodes_identically(self):
        # Exercise the same member-to-volume selection used by the StatefulSet.
        identity = self.env.pop("SERVICERADAR_NVR_STORAGE_ID")
        self.env["SERVICERADAR_NVR_MEMBER_NAME"] = "synthetic-nvr-1"
        self.env["SERVICERADAR_NVR_STORAGE_IDS"] = json.dumps({
            "synthetic-nvr-0": "00000000-0000-4000-8000-000000000012",
            "synthetic-nvr-1": identity,
        })
        source = self.make_media()
        self.run_probe("record")
        receipt = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(receipt["block_bytes"] + 65536 + 512 + 4096)
        self.run_probe("recover")
        expected = self.decode(source)
        self.assertEqual(len(expected), 75 * 64 * 64 * 3 // 2)
        self.assertEqual(self.decode(self.env["NVR_TEST_MP4"]), expected)

    def test_publication_allows_capture_rotation_and_expires_after_caller_loss(self):
        block = self.record_publication_block()
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        self.env["NVR_TEST_H264"] = str(self.root / "concurrent.h264")
        source = self.make_media(510)
        self.run_probe("publication_concurrent")
        paths = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())
        self.assertEqual(len(paths), 3)
        decoded = []
        for index, directory in enumerate(paths):
            directory = Path(directory)
            output = self.root / f"concurrent-{index}.mp4"
            output.write_bytes((directory / "init.mp4").read_bytes() +
                               (directory / "media.m4s").read_bytes())
            decoded.append(self.decode(output))
        self.assertEqual(b"".join(decoded), self.decode(source))

    def test_publication_pages_recover_mixed_states_without_mutating_evidence(self):
        self.make_media(510)
        self.run_probe("rotation")
        Path(self.env["NVR_TEST_RECEIPT"]).unlink()
        self.run_probe("publication_page_setup")
        blocks = sorted(p for p in self.spool.iterdir() if p.is_dir())
        pending, accepted, unprepared = blocks

        def scan():
            before = {str(p): (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns)
                      for p in self.spool.rglob("*") if p.is_file()}
            self.run_probe("publication_page")
            self.assertEqual(before, {
                str(p): (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns)
                for p in self.spool.rglob("*") if p.is_file()
            })
            entries = json.loads(Path(self.env["NVR_TEST_MP4"] + ".pages.json").read_text())
            self.assertEqual([entry["block_id"] for entry in entries], [p.name for p in blocks])
            return entries

        entries = scan()
        self.assertEqual([entry["state"] for entry in entries], ["pending", "intent_accepted", "unprepared"])
        self.assertEqual(entries[0], {"block_id": pending.name, "state": "pending",
                                     "intent": (pending / "publication.json").read_text()})
        self.assertEqual(entries[1], {"block_id": accepted.name, "state": "intent_accepted",
                                     "intent": (accepted / "publication.json").read_text(),
                                     "acknowledgement": (accepted / "publication-ack.json").read_text()})
        self.assertEqual(entries[2], {"block_id": unprepared.name, "state": "unprepared"})
        self.run_probe("publication_page_resume")

        # A damaged earlier item must remain visible and must not hide later work.
        intent = pending / "publication.json"
        original = intent.read_bytes()
        intent.write_bytes(original[:17])
        damaged = scan()
        self.assertEqual(damaged[0]["state"], "unresolved")
        self.assertNotIn("intent", damaged[0])
        self.assertEqual(damaged[1:], entries[1:])
        intent.write_bytes(original)

        # A valid manifest with missing media is not an absent publication intent.
        media = pending / "media.m4s"
        saved = media.read_bytes()
        media.unlink()
        self.assertEqual(scan()[0]["state"], "unresolved")
        media.write_bytes(saved)

        ack = accepted / "publication-ack.json"
        original_ack = ack.read_bytes()
        wrong = json.loads(original_ack) | {"intent_sha256": "0" * 64}
        ack.write_bytes(json.dumps(wrong, sort_keys=True, separators=(",", ":")).encode())
        damaged = scan()
        self.assertEqual(damaged[1]["state"], "unresolved")
        self.assertNotIn("intent", damaged[1])
        self.assertEqual(damaged[0], entries[0])
        ack.write_bytes(original_ack)
        (accepted / "publication.json").unlink()
        self.assertEqual(scan()[1]["reason"], ":publication_intent_missing")

    def test_publication_intent_survives_restart_and_preserves_conflicts(self):
        block = self.record_publication_block()
        descriptor = Path(self.env["NVR_TEST_MP4"] + ".0.json").read_bytes()
        self.run_probe("publication_prepare")
        intent = block / "publication.json"
        original = intent.read_bytes()
        document = json.loads(original)
        self.assertEqual(set(document), {"version", "storage_id", "block_id", "operation_id",
                                         "recording_block_id", "descriptor_sha256", "descriptor"})
        self.assertEqual(document["version"], 1)
        self.assertEqual(document["storage_id"], self.env["SERVICERADAR_NVR_STORAGE_ID"])
        self.assertEqual(document["block_id"], block.name)
        self.assertEqual(document["operation_id"], "00000000-0000-4000-8000-000000000021")
        self.assertEqual(document["recording_block_id"], "00000000-0000-4000-8000-000000000022")
        self.assertEqual(document["descriptor_sha256"], hashlib.sha256(descriptor).hexdigest())
        self.assertEqual(document["descriptor"], json.loads(descriptor))
        self.assertEqual(original, json.dumps(document, sort_keys=True, separators=(",", ":")).encode())
        self.assertLessEqual(len(original), 65536)
        self.assertEqual(intent.stat().st_mode & 0o777, 0o600)
        inode, mtime = intent.stat().st_ino, intent.stat().st_mtime_ns
        # Restart with no room for another byte: exact retry must still succeed.
        used = sum(p.stat().st_size for p in block.iterdir())
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(used)
        self.run_probe("publication_retry")
        self.assertEqual((intent.stat().st_ino, intent.stat().st_mtime_ns), (inode, mtime))
        self.assertEqual(intent.read_bytes(), original)
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        self.run_probe("publication_storage_binding")

        for damaged in [original[:17], original + b" ", b"x" * 65537,
                        json.dumps(document | {"storage_id": "00000000-0000-4000-8000-000000000099"},
                                   sort_keys=True, separators=(",", ":")).encode()]:
            intent.write_bytes(damaged)
            self.run_probe("publication_error")
            self.assertEqual(intent.read_bytes(), damaged)
        intent.write_bytes(original)
        media = block / "media.m4s"
        damaged_media = bytearray(media.read_bytes())
        damaged_media[-1] ^= 1
        media.write_bytes(damaged_media)
        self.run_probe("publication_error")
        self.assertEqual(intent.read_bytes(), original)
        self.assertEqual(media.read_bytes(), damaged_media)

    def test_publication_records_require_space_before_creating_metadata(self):
        block = self.record_publication_block()
        retained = sum(p.stat().st_size for p in block.iterdir())
        block_bytes = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())["block_bytes"]
        # Keep room for the retained block's bounded intent, acknowledgement and
        # archive receipt, and the next block's, independently of its media reservation.
        capture_budget = retained + block_bytes + 2 * (65536 + 512 + 4096) - 1
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(capture_budget)
        self.run_probe("publication_headroom")
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()))
        self.run_probe("publication_budget")
        self.assertFalse((block / "publication.json").exists())
        del self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"]
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = "1125899906842624"
        self.run_probe("publication_pressure")
        self.assertFalse((block / "publication.json").exists())

        del self.env["SERVICERADAR_NVR_RESERVE_BYTES"]
        self.run_probe("publication_prepare")
        self.acknowledgement_input(block)
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()))
        self.run_probe("publication_ack_budget")
        self.assertFalse((block / "publication-ack.json").exists())
        del self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"]
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = "1125899906842624"
        self.run_probe("publication_ack_pressure")
        self.assertFalse((block / "publication-ack.json").exists())

        # The acknowledgement can spend its own reserved slot; the absent archive
        # receipt keeps its own. Once both publication records exist, their unused
        # headroom is available to capture.
        del self.env["SERVICERADAR_NVR_RESERVE_BYTES"]
        retained = sum(p.stat().st_size for p in block.iterdir())
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(retained + 512 + 4096)
        self.run_probe("publication_ack_store")
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(capture_budget)
        self.run_probe("publication_headroom_released")

    def record_publication_block(self):
        self.make_media()
        self.run_probe("record")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        # Existing descriptor export verifies media; Python independently hashes its wire bytes.
        self.run_probe("discover_rotation")
        descriptor_path = Path(self.env["NVR_TEST_MP4"] + ".0.json")
        descriptor = descriptor_path.read_bytes()
        self.env["NVR_TEST_DESCRIPTOR_SHA256"] = hashlib.sha256(descriptor).hexdigest()
        return block

    def acknowledgement_input(self, block):
        # Invented response in the public wire format, supplied independently of
        # the Elixir codec. Core's DB owner checks emission after committed acceptance.
        intent = (block / "publication.json").read_bytes()
        document = {"version": 1, "kind": "intent_accepted",
                    "operation_id": json.loads(intent)["operation_id"],
                    "intent_sha256": hashlib.sha256(intent).hexdigest()}
        raw = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        path = self.root / "ack-input.json"
        path.write_bytes(raw)
        self.env["NVR_TEST_ACK"] = str(path)
        self.env["NVR_TEST_BLOCK_ID"] = block.name
        return path, raw

    def test_publication_acknowledgement_survives_restart_and_preserves_unresolved_records(self):
        block = self.record_publication_block()
        self.run_probe("publication_prepare")
        supplied, raw = self.acknowledgement_input(block)
        intent = block / "publication.json"
        original_intent = intent.read_bytes()
        ack = block / "publication-ack.json"

        # A response without its original retained intent cannot become local evidence.
        intent.unlink()
        self.run_probe("publication_ack_error")
        self.assertFalse(ack.exists())
        intent.write_bytes(original_intent)
        intent.chmod(0o600)
        self.run_probe("publication_ack_store")
        self.assertEqual(ack.read_bytes(), raw)
        self.assertEqual(ack.stat().st_mode & 0o777, 0o600)
        before = [(p.stat().st_ino, p.stat().st_mtime_ns) for p in (intent, ack)]
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(sum(p.stat().st_size for p in block.iterdir()))
        self.run_probe("publication_ack_retry")
        self.assertEqual([(p.stat().st_ino, p.stat().st_mtime_ns) for p in (intent, ack)], before)
        self.assertEqual(intent.read_bytes(), original_intent)
        self.assertEqual(ack.read_bytes(), raw)

        document = json.loads(raw)
        wrong = document | {"intent_sha256": "0" * 64}
        for bad in [raw + b" ", b"x" * 513,
                    json.dumps(wrong, sort_keys=True, separators=(",", ":")).encode()]:
            supplied.write_bytes(bad)
            self.run_probe("publication_ack_input_error")
            self.assertEqual(ack.read_bytes(), raw)
        supplied.write_bytes(raw)

        for damaged in [raw[:17], raw + b" ", b"x" * 513]:
            ack.write_bytes(damaged)
            self.run_probe("publication_ack_error")
            self.assertEqual(ack.read_bytes(), damaged)
            self.assertEqual(intent.read_bytes(), original_intent)
        ack.write_bytes(raw)
        alias = self.root / "ack-alias.json"
        os.link(ack, alias)
        self.run_probe("publication_ack_error")
        self.assertEqual(ack.stat().st_ino, alias.stat().st_ino)
        alias.unlink()
        media = block / "media.m4s"
        damaged_media = bytearray(media.read_bytes())
        damaged_media[-1] ^= 1
        media.write_bytes(damaged_media)
        self.run_probe("publication_ack_error")
        self.assertEqual(ack.read_bytes(), raw)
        self.assertEqual(media.read_bytes(), damaged_media)

    def make_media(self, frames=75):
        source = self.env["NVR_TEST_H264"]
        subprocess.run([self.ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                        "testsrc2=size=64x64:rate=15", "-frames:v", str(frames), "-c:v", "libx264",
                        "-profile:v", "baseline", "-bf", "0", "-g", "30", "-sc_threshold", "0",
                        "-x264-params", "aud=1:repeat-headers=1", "-f", "h264", source],
                       check=True, capture_output=True, timeout=30)
        return source

    def decode(self, path):
        return subprocess.run([self.ffmpeg, "-nostdin", "-v", "error", "-xerror", "-threads", "1",
                               "-i", path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f",
                               "rawvideo", "-pix_fmt", "yuv420p", "pipe:1"],
                              check=True, capture_output=True, timeout=30).stdout

    def test_rotation_preserves_frames_and_stops_before_unreserved_block(self):
        # The first boundary rotates during push; the second during final flush.
        source = self.make_media(510)
        expected = self.decode(source)
        self.assertEqual(len(expected), 510 * 64 * 64 * 3 // 2)
        # Enough for one reservation and these retained bytes, not two reservations.
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = "20000000"
        self.run_probe("rotation")
        receipt = json.loads(Path(self.env["NVR_TEST_RECEIPT"]).read_text())
        self.assertEqual(len(list(self.spool.iterdir())), 4)
        Path(self.env["NVR_TEST_RECEIPT"]).unlink()
        self.run_probe("discover_rotation")
        for index in range(3):
            path = Path(self.env["NVR_TEST_MP4"] + f".{index}")
            encoded = Path(str(path) + ".json").read_bytes()
            descriptor = json.loads(encoded)
            self.assertEqual(encoded, json.dumps(descriptor, sort_keys=True, separators=(",", ":")).encode())
            self.assertEqual(set(descriptor), {"version", "identity", "format", "init", "media", "fragments"})
            self.assertEqual(descriptor["version"], 1)
            self.assertEqual(descriptor["identity"], {
                "source_id": "synthetic-camera", "profile": "recording", "recorder_epoch": 1,
                "block_sequence": index, "clock": {
                    "clock_epoch": "synthetic-clock", "timebase": 90000,
                    "dts_source": "pts_no_reordering", "utc_mapping": "unknown",
                },
            })
            self.assertEqual(descriptor["format"], {"codec": "avc1.42c00a", "timescale": 30720})
            data = path.read_bytes()
            init_size = descriptor["init"]["length"]
            init, media = data[:init_size], data[init_size:]
            self.assertEqual(descriptor["init"], {"length": len(init), "sha256": hashlib.sha256(init).hexdigest()})
            self.assertEqual(descriptor["media"], {"length": len(media), "sha256": hashlib.sha256(media).hexdigest()})
            offset = 0
            for fragment in descriptor["fragments"]:
                self.assertEqual(fragment["offset"], offset)
                end = offset + fragment["length"]
                self.assertEqual(fragment["sha256"], hashlib.sha256(media[offset:end]).hexdigest())
                offset = end
            self.assertEqual(offset, len(media))
        decoded = [self.decode(self.env["NVR_TEST_MP4"] + f".{i}") for i in range(3)]
        self.assertEqual([len(x) for x in decoded], [n * 64 * 64 * 3 // 2 for n in [240, 240, 30]])
        self.assertEqual(b"".join(decoded), expected)

        # A fresh one-block budget admits capture but cannot fund its successor.
        self.spool = self.root / "limited-spool"
        self.spool.mkdir(mode=0o700)
        self.env["SERVICERADAR_NVR_SPOOL_ROOT"] = str(self.spool)
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = str(receipt["block_bytes"] + 65536 + 512 + 4096)
        self.run_probe("rotation_budget")
        self.assertEqual(len(list(self.spool.iterdir())), 2)
        Path(self.env["NVR_TEST_RECEIPT"]).unlink()
        self.run_probe("discover_rotation")
        self.assertEqual(self.decode(self.env["NVR_TEST_MP4"] + ".0"), expected[:240 * 64 * 64 * 3 // 2])

    def test_configured_fragment_limit_rotates_blocks_that_stay_readable_after_it_is_lowered(self):
        source = self.make_media(510)
        expected = self.decode(source)
        self.env["SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS"] = "12"
        self.env["NVR_TEST_ROTATION_FRAGMENTS"] = "[12, 5]"
        self.run_probe("rotation")
        Path(self.env["NVR_TEST_RECEIPT"]).unlink()
        # A restart with a smaller limit still discovers, verifies and reads both blocks.
        self.env["SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS"] = "8"
        self.run_probe("discover_rotation")
        decoded = [self.decode(self.env["NVR_TEST_MP4"] + f".{i}") for i in range(2)]
        self.assertEqual([len(x) for x in decoded], [n * 64 * 64 * 3 // 2 for n in [360, 150]])
        self.assertEqual(b"".join(decoded), expected)

    def test_discovery_preserves_unsealed_corrupt_and_uncommitted_blocks(self):
        self.make_media()
        self.run_probe("record")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        originals = {p.name: p.read_bytes() for p in block.iterdir()}
        journal = originals["journal"]
        offset = 0
        while offset < len(journal):
            last = offset
            size = int.from_bytes(journal[offset:offset + 4], "big")
            offset += 4 + size + 32
        self.assertEqual(offset, len(journal))
        self.assertEqual(json.loads(journal[last + 4:offset - 32])["type"], "seal")

        cases = [
            ("journal", journal[:last], "unsealed_block"),
            ("journal", journal[:-1] + bytes([journal[-1] ^ 1]), "invalid_journal_record"),
            # Reads accept a journal for the largest configurable block, whatever the current setting.
            ("journal", b"x" * ((256 + 2) * (4096 + 36) + 1), "journal_too_large"),
            ("media.m4s", b"x" + originals["media.m4s"][1:], "media_digest_mismatch"),
            ("media.m4s", originals["media.m4s"] + b"uncommitted", "uncommitted_block_bytes"),
            ("init.mp4", originals["init.mp4"] + b"uncommitted", "uncommitted_block_bytes"),
        ]
        for name, content, error in cases:
            with self.subTest(error=error, file=name):
                for filename, original in originals.items():
                    (block / filename).write_bytes(original)
                (block / name).write_bytes(content)
                before = {p.name: p.read_bytes() for p in block.iterdir()}
                self.env["NVR_TEST_RECOVERY_ERROR"] = error
                self.run_probe("discover_unresolved")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, before)

        # A valid journal under a different block ID cannot supply that identity.
        for name, original in originals.items():
            (block / name).write_bytes(original)
        renamed = self.spool / ("f" * 64)
        block.rename(renamed)
        self.env["NVR_TEST_RECOVERY_ERROR"] = "block_identity_mismatch"
        self.run_probe("discover_unresolved")
        self.assertEqual({p.name: p.read_bytes() for p in renamed.iterdir()}, originals)

    def test_discovery_refuses_invalid_format_even_with_valid_journal_hashes(self):
        self.make_media()
        self.run_probe("record")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        journal = (block / "journal").read_bytes()
        header_size = int.from_bytes(journal[:4], "big")
        header = json.loads(journal[4:4 + header_size])
        init = (block / "init.mp4").read_bytes()
        self.assertEqual(init.count(b"avcC\x01\x42"), 1)
        unsupported = init.replace(b"avcC\x01\x42", b"avcC\x01\x58")
        for content in [init[:-1], unsupported, b"synthetic non-MP4 initialization"]:
            with self.subTest(initialization_bytes=len(content)):
                # Integrity-valid persisted records must still have a supported format.
                header["init"] = {"length": len(content), "sha256": hashlib.sha256(content).hexdigest()}
                encoded = json.dumps(header, separators=(",", ":")).encode()
                (block / "init.mp4").write_bytes(content)
                (block / "journal").write_bytes(len(encoded).to_bytes(4, "big") + encoded +
                                              hashlib.sha256(encoded).digest() + journal[4 + header_size + 32:])
                before = {p.name: p.read_bytes() for p in block.iterdir()}
                self.env["NVR_TEST_RECOVERY_ERROR"] = "invalid_initialization"
                self.run_probe("discover_unresolved")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, before)

    def test_interrupted_recording_recovers_only_committed_frames(self):
        source = self.make_media()
        self.run_probe("interrupted")
        self.assertFalse(Path(self.env["NVR_TEST_RECEIPT"]).exists())
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        media = (block / "media.m4s").read_bytes()
        journal = (block / "journal").read_bytes()
        # Represent writes interrupted before a complete journal record committed.
        (block / "media.m4s").write_bytes(media + b"uncommitted synthetic tail")
        (block / "journal").write_bytes(journal + b"\x00\x00")
        self.run_probe("recover_interrupted")
        self.assertEqual((block / "media.m4s").read_bytes(), media)
        sealed = {p.name: p.read_bytes() for p in block.iterdir()}
        self.run_probe("discover_rotation")
        decoded = self.decode(self.env["NVR_TEST_MP4"] + ".0")
        self.assertEqual(len(decoded), 60 * 64 * 64 * 3 // 2)
        self.assertEqual(decoded, self.decode(source)[:len(decoded)])
        self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, sealed)

    def test_recovery_gate_closed_during_repair_or_measurement_refuses_reply_and_keeps_seal(self):
        self.make_media()
        self.run_probe("interrupted")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        media = (block / "media.m4s").read_bytes()
        journal = (block / "journal").read_bytes()
        (block / "media.m4s").write_bytes(media + b"uncommitted synthetic tail")
        (block / "journal").write_bytes(journal + b"\x00\x00")
        self.run_probe("recover_closed_in_flight")
        self.assertEqual((block / "media.m4s").read_bytes(), media)
        self.assertEqual(self.recovery.read_bytes(), self.ready.replace(b"ready", b"closed"))

    def test_recovery_preserves_unresolved_blocks_and_pressure(self):
        self.make_media()
        self.run_probe("interrupted")
        block = next(p for p in self.spool.iterdir() if p.is_dir())
        originals = {p.name: p.read_bytes() for p in block.iterdir()}
        journal = originals["journal"]
        header_end = 4 + int.from_bytes(journal[:4], "big") + 32
        cases = [
            ("journal", journal[:-1] + bytes([journal[-1] ^ 1]), "invalid_journal_record"),
            ("media.m4s", b"x" + originals["media.m4s"][1:], "media_digest_mismatch"),
            ("init.mp4", originals["init.mp4"] + b"uncommitted", "uncommitted_block_bytes"),
            ("journal", journal[:header_end], "empty_block"),
        ]
        for name, content, error in cases:
            with self.subTest(error=error):
                for filename, original in originals.items():
                    (block / filename).write_bytes(original)
                (block / name).write_bytes(content)
                before = {p.name: p.read_bytes() for p in block.iterdir()}
                self.env["NVR_TEST_RECOVERY_ERROR"] = error
                self.run_probe("recover_unresolved")
                self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, before)

        for name, original in originals.items():
            (block / name).write_bytes(original)
        disk = os.statvfs(self.spool)
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = str(disk.f_bavail * disk.f_frsize + 1024**3)
        self.env["NVR_TEST_RECOVERY_ERROR"] = "nvr_storage_pressure"
        self.run_probe("recover_unresolved")
        self.assertEqual({p.name: p.read_bytes() for p in block.iterdir()}, originals)

        del self.env["SERVICERADAR_NVR_RESERVE_BYTES"]
        renamed = self.spool / ("f" * 64)
        block.rename(renamed)
        self.env["NVR_TEST_RECOVERY_ERROR"] = "block_identity_mismatch"
        self.run_probe("recover_unresolved")
        self.assertEqual({p.name: p.read_bytes() for p in renamed.iterdir()}, originals)

    def test_deadline_and_producer_loss_release_admission(self):
        self.env["SERVICERADAR_NVR_MAX_DURATION_MS"] = "500"
        self.run_probe("lifecycle")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_concurrent_reservations_and_accounting_restart(self):
        self.env["SERVICERADAR_NVR_MAX_SESSIONS"] = "3"
        self.env["SERVICERADAR_NVR_MAX_SPOOL_BYTES"] = "20000000"
        self.run_probe("capacity")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_reads_refuse_overload_expire_and_restart_without_stopping_recording(self):
        self.run_probe("read_admission")
        self.assertEqual({p.name for p in self.spool.iterdir()}, {".storage-id"})

    def test_physical_free_reserve_refuses_without_creating_media(self):
        disk = os.statvfs(self.spool)
        self.env["SERVICERADAR_NVR_RESERVE_BYTES"] = str(disk.f_bavail * disk.f_frsize + 1024**3)
        self.run_probe("pressure")
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])

    def test_unrecognized_inventory_is_preserved_and_refused(self):
        marker = self.spool / ".storage-id"
        marker.write_text(self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
        marker.chmod(0o600)
        block = self.spool / ("a" * 64)
        block.mkdir(mode=0o700)
        target = self.root / "retained-evidence"
        target.write_bytes(b"invented retained media")
        (block / "media.m4s").symlink_to(target)
        self.run_probe("inventory")
        self.assertTrue((block / "media.m4s").is_symlink())
        self.assertEqual(target.read_bytes(), b"invented retained media")

    def test_block_cap_refuses_admission_but_keeps_the_volume_listable(self):
        self.env["SERVICERADAR_NVR_MAX_BLOCKS"] = "4096"
        marker = self.spool / ".storage-id"
        marker.write_text(self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
        marker.chmod(0o600)
        for index in range(4096):
            (self.spool / f"{index:064x}").mkdir(mode=0o700)
        self.run_probe("inventory_limit")
        self.assertEqual(len(list(self.spool.iterdir())), 4097)
        (self.spool / f"{4096:064x}").mkdir(mode=0o700)
        self.run_probe("discovery_limit")
        self.assertEqual(len(list(self.spool.iterdir())), 4098)

    def test_multipage_rebuild_reports_later_failure_settles_exits_and_rejects_invalid_ids(self):
        marker = self.spool / ".storage-id"
        marker.write_text(self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
        marker.chmod(0o600)
        for index in range(2100):
            (self.spool / f"{index:064x}").mkdir(mode=0o700)
        self.run_probe("multipage_rebuild")

    def ingest_installation(self):
        self.run_probe("delivery_certificates")
        self.run_probe("recovery_ready")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.ingest_port = sock.getsockname()[1]
        pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert((self.root / "client.pem").read_text())).hexdigest()
        config = {"port": self.ingest_port, "client_sha256": pin,
                  "cert_file": str(self.root / "server.pem"), "key_file": str(self.root / "server-key.pem"),
                  "ca_file": str(self.root / "server-ca.pem")}
        path = self.root / "ingest.json"
        path.write_text(json.dumps(config))
        token = self.root / "ingest-token"
        self.ingest_token = "synthetic-nvr-recording-coordinator-token"
        token.write_text(self.ingest_token)
        self.env.update(SERVICERADAR_NVR_INGEST_CONFIG_FILE=str(path),
                        SERVICERADAR_NVR_INGEST_TOKEN_FILE=str(token))
        self.ingest_tls = ssl.create_default_context(cafile=str(self.root / "client-ca.pem"))
        self.ingest_tls.load_cert_chain(str(self.root / "client.pem"), str(self.root / "client-key.pem"))

    def start_ingest_release(self):
        proc = subprocess.Popen([self.binary, "start"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_ingest_release, proc)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                self.fail(f"release exited: {proc.communicate()[0]}")
            try:
                connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=1)
                connection.request("GET", "/unknown", headers={"Authorization": "Bearer " + self.ingest_token})
                self.assertEqual(connection.getresponse().status, 404)
                connection.close()
                return proc
            except OSError:
                time.sleep(0.05)
        self.fail("NVR ingest listener did not become ready")

    def stop_ingest_release(self, proc):
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=15)

    def ingest_header(self, source="synthetic-network-camera", **changes):
        document = {"version": 1, "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                    "recovery_generation": self.generation, "clock_epoch": "synthetic-network-clock",
                    "identity": {"source_id": source, "profile": "recording", "recorder_epoch": 1, "block_sequence": 0}}
        document.update(changes)
        raw = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        return struct.pack("!I", len(raw)) + raw

    def ingest_units(self):
        aud = b"\x00\x00\x00\x01\x09"
        prefix, *units = Path(self.env["NVR_TEST_H264"]).read_bytes().split(aud)
        self.assertEqual(prefix, b"")
        return [struct.pack("!IQQQ", len(aud + unit), index + 1, 90000 + index * 6000, 90000 + index * 6000) + aud + unit
                for index, unit in enumerate(units)]

    def ingest_request(self, body, token=None, tls=None):
        connection = http.client.HTTPSConnection("localhost", self.ingest_port,
                                                context=tls or self.ingest_tls, timeout=10)
        try:
            connection.request("POST", "/v1/recordings/ingest", body=body, encode_chunked=True,
                               headers={"Authorization": "Bearer " + (token or self.ingest_token),
                                        "Content-Type": "application/vnd.serviceradar.nvr-ingest.v1"})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def assert_ingest_unsealed(self):
        journals = list(self.spool.glob("*/journal"))
        self.assertEqual(len(journals), 1)
        data = journals[0].read_bytes()
        types = []
        while data:
            size = int.from_bytes(data[:4], "big")
            record, digest = data[4:4 + size], data[4 + size:4 + size + 32]
            self.assertEqual(hashlib.sha256(record).digest(), digest)
            types.append(json.loads(record)["type"])
            data = data[4 + size + 32:]
        self.assertIn("fragment", types)
        self.assertNotIn("seal", types)

    def send_with_client(self, units, mode="normal", timeout_ms=20000, config_changes=None, header_changes=None,
                         pace_ms=None):
        units_path = self.root / "client-units.bin"
        units_path.write_bytes(b"".join(units))
        return self.run_client({"header": json.loads(self.ingest_header(**(header_changes or {}))[4:]),
                                "units_path": str(units_path), "mode": mode, "timeout_ms": timeout_ms,
                                "pace_ms": pace_ms},
                               config_changes=config_changes)

    def run_client(self, request, config_changes=None, timeout=35):
        config = {"host": "localhost", "port": self.ingest_port,
                  "ca_file": str(self.root / "client-ca.pem"),
                  "cert_file": str(self.root / "client.pem"), "key_file": str(self.root / "client-key.pem")}
        config.update(config_changes or {})
        config_path = self.root / "client-config.json"
        config_path.write_text(json.dumps(config))
        request = {"config_path": str(config_path), "token_path": str(self.root / "ingest-token")} | request
        request_path = self.root / "client-request.json"
        request_path.write_text(json.dumps(request))
        output = self.root / "client-result.json"
        output.unlink(missing_ok=True)
        env = self.env | {"NVR_CLIENT_REQUEST": str(request_path), "NVR_CLIENT_RESULT": str(output)}
        result = subprocess.run([self.client_binary, "eval", f'Code.require_file("{self.client_probe}")'],
                                env=env, capture_output=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b"NVR_CLIENT_PROBE_OK", result.stdout)
        return json.loads(output.read_bytes())

    def sender_peer(self, response_body, status=200, hang=False, drop_after=None, answer_after=None):
        observations = []
        closed = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def do_POST(self):
                observation = {"path": self.path, "body": bytearray(), "complete": False, "answered_at": None}
                observations.append(observation)
                self.connection.settimeout(5)
                try:
                    # Independent implementation of HTTP chunking; retain application bytes.
                    while True:
                        line = self.rfile.readline(64)
                        if not line:
                            return
                        size = int(line.strip(), 16)
                        if size == 0:
                            if self.rfile.read(2) != b"\r\n":
                                return
                            observation["complete"] = True
                            break
                        if size > 2 * 1024 * 1024:
                            return
                        data = self.rfile.read(size)
                        observation["body"].extend(data)
                        if len(data) != size or self.rfile.read(2) != b"\r\n":
                            return
                        if drop_after is not None and len(observation["body"]) >= drop_after:
                            # Close mid-body without any answer, not even to a next request.
                            self.close_connection = True
                            return
                        if (answer_after is not None and observation["answered_at"] is None
                                and len(observation["body"]) >= answer_after):
                            # Answer before the body ends, then keep recording what still arrives.
                            observation["answered_at"] = len(observation["body"])
                            self.answer()
                    if observation["answered_at"] is not None:
                        return
                    if hang:
                        self.rfile.read(1)
                        return
                    self.answer()
                except (OSError, ValueError):
                    pass
                finally:
                    closed.set()

            def answer(self):
                self.send_response(status)
                self.send_header("Content-Length", str(len(response_body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(response_body)
                self.wfile.flush()

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(str(self.root / "server.pem"), str(self.root / "server-key.pem"))
        tls.load_verify_locations(str(self.root / "server-ca.pem"))
        tls.verify_mode = ssl.CERT_REQUIRED
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.ingest_port = server.server_address[1]
        return observations, closed

    def test_sender_records_through_real_nvr_and_decodes_after_restart(self):
        self.ingest_installation()
        source = self.make_media(510)
        units = self.ingest_units()
        proc = self.start_ingest_release()
        result = self.send_with_client(units)
        self.assertIn("ok", result)
        receipt = result["ok"]
        self.assertEqual(receipt["status"], "sealed_local")
        self.assertEqual(receipt["storage_id"], self.env["NVR_TEST_EXPECTED_STORAGE_ID"])
        self.assertGreaterEqual(len(receipt["block_ids"]), 2)
        self.stop_ingest_release(proc)
        self.start_ingest_release()
        decoded = bytearray()
        for block_id in receipt["block_ids"]:
            block = self.spool / block_id
            output = self.root / (block_id + ".mp4")
            output.write_bytes((block / "init.mp4").read_bytes() + (block / "media.m4s").read_bytes())
            decoded.extend(self.decode(str(output)))
        self.assertEqual(bytes(decoded), self.decode(source))

    def test_sender_wire_bytes_and_receipt_binding_without_retries(self):
        self.ingest_installation()
        self.make_media(1)
        units = self.ingest_units()
        identity = ["synthetic-network-camera", "recording", 1, 0]
        key = hashlib.sha256(json.dumps(identity, separators=(",", ":")).encode()).hexdigest()
        receipt = {"version": 1, "status": "sealed_local", "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                   "block_ids": [key]}
        observations, _ = self.sender_peer(json.dumps(receipt).encode())
        self.assertIn("ok", self.send_with_client(units))
        self.assertEqual(len(observations), 1)
        self.assertTrue(observations[0]["complete"])
        self.assertEqual(observations[0]["path"], "/v1/recordings/ingest")
        self.assertEqual(bytes(observations[0]["body"]), self.ingest_header() + b"".join(units) + b"\0" * 4)
        for bad in ({**receipt, "storage_id": "00000000-0000-4000-8000-000000000099"},
                    {**receipt, "block_ids": ["a" * 64]}, {**receipt, "block_ids": [key, key]},
                    {**receipt, "extra": True}, {**receipt, "block_ids": []}):
            observed, _ = self.sender_peer(json.dumps(bad).encode())
            self.assertEqual(self.send_with_client(units), {"error": ":outcome_unknown"})
            self.assertEqual(len(observed), 1)
        for raw, status in ((b"invalid json", 200), (b"x" * 32769, 200)):
            observed, _ = self.sender_peer(raw, status=status)
            self.assertIn("error", self.send_with_client(units))
            self.assertEqual(len(observed), 1)
        # A non-200 after the end marker may follow a seal, so it is never a refusal.
        for status in (307, 422, 503):
            observed, _ = self.sender_peer(b"{}", status=status)
            self.assertEqual(self.send_with_client(units), {"error": "{:ingest_status, %d}" % status})
            self.assertEqual(len(observed), 1)
            self.assertTrue(observed[0]["complete"])

    def test_sender_rejects_invalid_header_configuration_and_server_identity(self):
        self.ingest_installation()
        self.make_media(1)
        units = self.ingest_units()
        observations, _ = self.sender_peer(b"{}")
        self.assertEqual(self.send_with_client(units, header_changes={"clock_epoch": ""}),
                         {"error": ":invalid_ingest_header"})
        self.assertEqual(self.send_with_client(units, config_changes={"host": "https://localhost"}),
                         {"error": ":invalid_ingest_config"})
        (self.root / "ingest-token").write_text(self.ingest_token + "\n")
        self.assertEqual(self.send_with_client(units), {"error": ":invalid_ingest_config"})
        (self.root / "ingest-token").write_text(self.ingest_token)
        # The peer's certificate names localhost, never its numeric loopback address.
        self.assertIn("error", self.send_with_client(units, config_changes={"host": "127.0.0.1"}))
        self.assertEqual(observations, [])

    def test_sender_producer_failures_and_deadlines_close_without_sealing(self):
        self.ingest_installation()
        self.make_media(1)
        units = self.ingest_units()
        for mode in ("raise", "block", "caller_loss"):
            observations, closed = self.sender_peer(b"{}")
            result = self.send_with_client(units, mode=mode, timeout_ms=1500)
            if mode == "caller_loss":
                self.assertEqual(result, {"ok": {"caller_loss_bounded": True}})
            else:
                self.assertEqual(result, {"error": ":outcome_unknown"})
            self.assertTrue(closed.wait(3), "sender socket survived its deadline")
            self.assertEqual(len(observations), 1)
            self.assertFalse(observations[0]["complete"])
            self.assertEqual(bytes(observations[0]["body"]), self.ingest_header())
        observations, closed = self.sender_peer(b"{}", hang=True)
        self.assertEqual(self.send_with_client(units, timeout_ms=1500), {"error": ":outcome_unknown"})
        self.assertTrue(closed.wait(3), "response wait left its socket open")
        self.assertEqual(len(observations), 1)
        self.assertTrue(observations[0]["complete"])

    def test_sender_enforces_unit_and_total_body_limits_without_sealing(self):
        self.ingest_installation()
        for size in (0, 1048577):
            observations, closed = self.sender_peer(b"{}")
            unit = struct.pack("!IQQQ", size, 1, 90000, 90000) + b"x" * size
            self.assertEqual(self.send_with_client([unit]), {"error": ":outcome_unknown"})
            self.assertTrue(closed.wait(3))
            self.assertEqual(len(observations), 1)
            self.assertFalse(observations[0]["complete"])
            self.assertEqual(bytes(observations[0]["body"]), self.ingest_header())
        # 63 maximum-size units fit; the 64th exceeds the application-body budget.
        unit = struct.pack("!IQQQ", 1048576, 1, 90000, 90000) + b"x" * 1048576
        observations, closed = self.sender_peer(b"{}")
        self.assertEqual(self.send_with_client([unit] * 64), {"error": ":outcome_unknown"})
        self.assertTrue(closed.wait(3))
        self.assertEqual(len(observations), 1)
        self.assertFalse(observations[0]["complete"])
        body = observations[0]["body"]
        header = self.ingest_header()
        self.assertEqual(len(body), len(header) + 63 * len(unit))
        self.assertEqual(body[:len(header)], header)
        self.assertLess(len(body), 64 * 1024 * 1024)

    def test_sender_reports_mid_stream_refusal_definitely_and_a_drop_as_unknown(self):
        self.ingest_installation()
        self.make_media(150)
        units = self.ingest_units()
        # A sequence gap after five valid units: the NVR answers 422 and stops
        # reading while the client still has most of the stream to send.
        gapped = units[:5] + units[6:]
        self.start_ingest_release()
        result = self.send_with_client(gapped, mode="paced", pace_ms=50)
        self.assertEqual(result["error"], "{:ingest_refused, 422}")
        self.assertLess(result["pulled"], len(gapped))
        # A connection closed mid-body without an answer stays an unknown outcome.
        observations, closed = self.sender_peer(b"{}", drop_after=len(self.ingest_header()) + 1)
        result = self.send_with_client(gapped, mode="paced", pace_ms=50)
        self.assertEqual(result["error"], ":outcome_unknown")
        self.assertLess(result["pulled"], len(gapped))
        self.assertTrue(closed.wait(3))
        self.assertEqual(len(observations), 1)
        self.assertFalse(observations[0]["complete"])
        # Any answer before the end marker stops the stream. A non-200 is a refusal;
        # a 200 with a well-formed receipt cannot be a seal, so it proves nothing.
        identity = ["synthetic-network-camera", "recording", 1, 0]
        key = hashlib.sha256(json.dumps(identity, separators=(",", ":")).encode()).hexdigest()
        receipt = json.dumps({"version": 1, "status": "sealed_local",
                              "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"], "block_ids": [key]}).encode()
        for status, body, expected in ((400, b"{}", "{:ingest_refused, 400}"), (401, b"{}", "{:ingest_refused, 401}"),
                                       (408, b"{}", "{:ingest_refused, 408}"),
                                       (503, b"{}", "{:ingest_refused, 503}"), (200, receipt, ":outcome_unknown")):
            observations, closed = self.sender_peer(body, status=status, answer_after=len(self.ingest_header()) + 1)
            result = self.send_with_client(units, mode="paced", pace_ms=50)
            self.assertEqual(result["error"], expected, status)
            self.assertLess(result["pulled"], len(units))
            self.assertTrue(closed.wait(3))
            self.assertEqual(len(observations), 1)
            self.assertFalse(observations[0]["complete"])
            self.assertNotEqual(bytes(observations[0]["body"][-4:]), b"\0" * 4)

    def test_network_ingest_seals_and_preserves_decodable_frames_across_restart(self):
        self.ingest_installation()
        source = self.make_media(510)
        units = self.ingest_units()
        proc = self.start_ingest_release()

        def stream():
            yield self.ingest_header()
            for unit in units:
                # Deliver boundaries across HTTP chunks, including a partial frame header.
                yield unit[:7]
                yield unit[7:]
                time.sleep(0.002)
            yield struct.pack("!I", 0)

        status, receipt = self.ingest_request(stream())
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["status"], "sealed_local")
        self.assertEqual(receipt["storage_id"], self.env["NVR_TEST_EXPECTED_STORAGE_ID"])
        self.assertGreaterEqual(len(receipt["block_ids"]), 2)
        self.stop_ingest_release(proc)
        self.start_ingest_release()
        decoded = bytearray()
        for block_id in receipt["block_ids"]:
            self.assertRegex(block_id, r"^[0-9a-f]{64}$")
            block = self.spool / block_id
            output = self.root / (block_id + ".mp4")
            output.write_bytes((block / "init.mp4").read_bytes() + (block / "media.m4s").read_bytes())
            decoded.extend(self.decode(str(output)))
        self.assertEqual(bytes(decoded), self.decode(source))
        before = {str(p.relative_to(self.spool)): p.read_bytes() for p in self.spool.rglob("*") if p.is_file()}
        status, _ = self.ingest_request(self.ingest_header() + b"".join(units) + struct.pack("!I", 0))
        self.assertNotEqual(status, 200)
        self.assertEqual(before, {str(p.relative_to(self.spool)): p.read_bytes() for p in self.spool.rglob("*") if p.is_file()})

    def encode_profile(self, codec_args, x264_params="aud=1:repeat-headers=1", pix_fmt="yuv420p"):
        source = self.env["NVR_TEST_H264"]
        # Each stream replaces the previous one at the shared source path.
        subprocess.run([self.ffmpeg, "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i",
                        "testsrc2=size=64x64:rate=15", "-frames:v", "75", "-pix_fmt", pix_fmt,
                        "-c:v", "libx264", "-sc_threshold", "0", "-x264-params", x264_params,
                        *codec_args, "-f", "h264", source],
                       check=True, capture_output=True, timeout=30)
        return source

    def test_network_ingest_admits_main_and_high_only_without_frame_reordering(self):
        self.ingest_installation()
        proc = self.start_ingest_release()
        admitted = {
            "main": (["-profile:v", "main", "-bf", "0", "-g", "30"], "aud=1:repeat-headers=1", b"avcC\x01\x4d"),
            "high": (["-profile:v", "high", "-bf", "0", "-g", "30"], "aud=1:repeat-headers=1", b"avcC\x01\x64"),
            # Interlaced x264 output uses POC type 0, so only its VUI restriction excludes reordering.
            "interlaced-main": (["-profile:v", "main", "-bf", "0", "-g", "30", "-flags", "+ildct+ilme"],
                                "tff=1:aud=1:repeat-headers=1", b"avcC\x01\x4d"),
        }
        for name, (args, params, avcc) in admitted.items():
            with self.subTest(stream=name):
                source = self.encode_profile(args, params)
                status, receipt = self.ingest_request(self.ingest_header(source=f"synthetic-{name}-camera")
                                                      + b"".join(self.ingest_units()) + struct.pack("!I", 0))
                self.assertEqual(status, 200, receipt)
                self.assertEqual(receipt["status"], "sealed_local")
                decoded = bytearray()
                for block_id in receipt["block_ids"]:
                    block = self.spool / block_id
                    init = (block / "init.mp4").read_bytes()
                    self.assertEqual(init.count(avcc), 1)
                    output = self.root / (block_id + ".mp4")
                    output.write_bytes(init + (block / "media.m4s").read_bytes())
                    decoded.extend(self.decode(str(output)))
                self.assertEqual(bytes(decoded), self.decode(source))
        sealed = sorted(p.name for p in self.spool.iterdir() if p.is_dir())
        refused = {
            "reordering-main": (["-profile:v", "main", "-bf", "2", "-g", "30"], "yuv420p", "h264_frame_reordering"),
            "high422": (["-profile:v", "high422", "-bf", "0", "-g", "30"], "yuv422p", "unsupported_h264_profile"),
        }
        for name, (args, pix_fmt, _) in refused.items():
            with self.subTest(stream=name):
                self.encode_profile(args, pix_fmt=pix_fmt)
                status, result = self.ingest_request(self.ingest_header(source=f"synthetic-{name}-camera")
                                                     + b"".join(self.ingest_units()) + struct.pack("!I", 0))
                self.assertEqual((status, result), (422, {"error": "ingest_incomplete"}))
        for block in self.spool.iterdir():
            if block.is_dir() and block.name not in sealed:
                journal = (block / "journal").read_bytes() if (block / "journal").exists() else b""
                self.assertNotIn(b'"type":"seal"', journal.replace(b" ", b""))
        proc.send_signal(signal.SIGTERM)
        log = proc.communicate(timeout=15)[0].decode(errors="replace")
        warnings = [line for line in log.splitlines() if "NVR ingest incomplete:" in line]
        self.assertEqual([w.split("NVR ingest incomplete: ", 1)[1].strip() for w in warnings],
                         [":" + reason for _, _, reason in refused.values()])

    def test_network_ingest_authentication_binding_and_incomplete_input(self):
        self.ingest_installation()
        self.make_media()
        units = self.ingest_units()
        self.start_ingest_release()
        body = self.ingest_header() + b"".join(units) + struct.pack("!I", 0)
        self.assertEqual(self.ingest_request(body, token="incorrect-token")[0], 401)
        no_cert = ssl.create_default_context(cafile=str(self.root / "client-ca.pem"))
        with self.assertRaises((OSError, http.client.HTTPException)):
            self.ingest_request(body, tls=no_cert)
        for header in (self.ingest_header(storage_id="00000000-0000-4000-8000-000000000099"),
                       self.ingest_header(recovery_generation="00000000-0000-4000-8000-000000000099")):
            self.assertEqual(self.ingest_request(header + struct.pack("!I", 0))[0], 400)
        for raw in (struct.pack("!I", 1025), struct.pack("!I", 0),
                    self.ingest_header()[:12]):
            self.assertEqual(self.ingest_request(raw)[0], 400)
        identity = {"source_id": "synthetic-network-camera", "profile": "recording", "recorder_epoch": 1, "block_sequence": 0}
        # Limits from the recording identity contract: printable 1..128-byte names,
        # recorder_epoch 1..2^63-1, block_sequence 0..2^63-1 and a printable clock epoch.
        for header in (self.ingest_header(identity={**identity, "recorder_epoch": 0}),
                       self.ingest_header(identity={**identity, "block_sequence": 2 ** 63}),
                       self.ingest_header(identity={**identity, "profile": "p" * 129}),
                       self.ingest_header(identity={**identity, "source_id": "synthetic\u0001camera"}),
                       self.ingest_header(clock_epoch="synthetic\u0001clock")):
            self.assertEqual(self.ingest_request(header + struct.pack("!I", 0)),
                             (400, {"error": "invalid_ingest_header"}))
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])
        # Complete HTTP EOF without the explicit application end marker must not seal.
        status, result = self.ingest_request(self.ingest_header() + b"".join(units))
        self.assertEqual((status, result), (422, {"error": "ingest_incomplete"}))
        retained = [p for p in self.spool.iterdir() if p.is_dir()]
        self.assertEqual(len(retained), 1)
        self.assert_ingest_unsealed()
        # An admitted worker that rejects a well-formed frame (sequence gap) is an
        # incomplete stream, not an unavailable listener.
        status, result = self.ingest_request(self.ingest_header(source="gapped-synthetic-camera")
                                             + units[0] + units[2] + struct.pack("!I", 0))
        self.assertEqual((status, result), (422, {"error": "ingest_incomplete"}))
        before = {str(p.relative_to(self.spool)): p.read_bytes() for p in self.spool.rglob("*") if p.is_file()}
        self.recovery.write_bytes(self.ready.replace(b"ready", b"closed"))
        self.assertEqual(self.ingest_request(self.ingest_header(source="another-synthetic-camera") + b"".join(units) + struct.pack("!I", 0))[0], 503)
        self.assertEqual(before, {str(p.relative_to(self.spool)): p.read_bytes() for p in self.spool.rglob("*") if p.is_file()})

    def test_network_ingest_pins_client_and_keeps_bootstrap_barrier(self):
        self.ingest_installation()
        config_path = Path(self.env["SERVICERADAR_NVR_INGEST_CONFIG_FILE"])
        config = json.loads(config_path.read_text())
        pinned = config["client_sha256"]
        config["client_sha256"] = "00" * 32
        config_path.write_text(json.dumps(config))
        # The CA-valid client is deliberately absent from the installed pin.
        proc = subprocess.Popen([self.binary, "start"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_ingest_release, proc)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                status, _ = self.ingest_request(self.ingest_header() + struct.pack("!I", 0))
                break
            except OSError:
                time.sleep(0.05)
        else:
            self.fail("NVR ingest listener did not start")
        self.assertEqual(status, 401)
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".storage-id"])
        self.stop_ingest_release(proc)
        config["client_sha256"] = pinned
        config_path.write_text(json.dumps(config))
        self.start_ingest_release()
        (self.spool / ".bootstrap-preparation.json").write_bytes(b"{}")
        self.assertEqual(self.ingest_request(self.ingest_header() + struct.pack("!I", 0))[0], 503)
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), [".bootstrap-preparation.json", ".storage-id"])

    def test_network_ingest_disconnect_releases_source_without_sealing(self):
        self.ingest_installation()
        self.make_media()
        self.start_ingest_release()
        partial = self.ingest_header() + b"".join(self.ingest_units())
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=5)
        connection.putrequest("POST", "/v1/recordings/ingest")
        connection.putheader("Authorization", "Bearer " + self.ingest_token)
        connection.putheader("Content-Type", "application/vnd.serviceradar.nvr-ingest.v1")
        connection.putheader("Content-Length", str(len(partial) + 4))
        connection.endheaders()
        connection.send(partial)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if any(p.stat().st_size > 0 for p in self.spool.glob("*/media.m4s")):
                break
            time.sleep(0.01)
        else:
            self.fail("stream did not persist media before disconnect")
        connection.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status, result = self.ingest_request(self.ingest_header() + struct.pack("!I", 0))
            if status == 422:
                break
            self.assertEqual(status, 503)
            time.sleep(0.05)
        else:
            self.fail("disconnected producer retained source admission")
        self.assertEqual(result, {"error": "ingest_incomplete"})
        self.assert_ingest_unsealed()
        self.assertTrue(any(p.stat().st_size > 0 for p in self.spool.glob("*/media.m4s")))

    def test_network_ingest_deadline_retires_producer_and_preserves_partial_media(self):
        self.ingest_installation()
        self.make_media(150)
        units = self.ingest_units()
        self.env["SERVICERADAR_NVR_MAX_DURATION_MS"] = "3000"
        self.start_ingest_release()
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=6)
        self.addCleanup(connection.close)
        connection.putrequest("POST", "/v1/recordings/ingest")
        connection.putheader("Authorization", "Bearer " + self.ingest_token)
        connection.putheader("Content-Type", "application/vnd.serviceradar.nvr-ingest.v1")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        first = self.ingest_header() + b"".join(units[:75])
        connection.send(f"{len(first):x}\r\n".encode() + first + b"\r\n")
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if any(p.stat().st_size > 0 for p in self.spool.glob("*/media.m4s")):
                break
            time.sleep(0.01)
        else:
            self.fail("stream did not persist a fragment before the deadline")
        # A second producer cannot overlap this camera/profile.
        self.assertEqual(self.ingest_request(self.ingest_header() + struct.pack("!I", 0))[0], 503)
        started = time.monotonic()
        # Continue complete valid frames faster than the idle-read timeout, so
        # that timeout cannot be mistaken for the absolute request deadline.
        ended = False
        for unit in units[75:]:
            try:
                connection.send(f"{len(unit):x}\r\n".encode() + unit + b"\r\n")
                time.sleep(0.15)
            except OSError:
                ended = True
                break
        self.assertTrue(ended, "stream outlived its absolute recording budget")
        self.assertGreater(time.monotonic() - started, 1.5)
        self.assertLess(time.monotonic() - started, 4)
        before = {str(p.relative_to(self.spool)): p.read_bytes() for p in self.spool.rglob("*") if p.is_file()}
        # The same source can be admitted again once the failed producer retires;
        # the empty new stream is rejected rather than advertised as a recording.
        status, result = self.ingest_request(self.ingest_header() + struct.pack("!I", 0))
        self.assertEqual((status, result), (422, {"error": "ingest_incomplete"}))
        self.assertEqual(before, {str(p.relative_to(self.spool)): p.read_bytes() for p in self.spool.rglob("*") if p.is_file()})

    def test_network_ingest_survives_wan_frame_jitter_over_one_second_and_seals(self):
        self.ingest_installation()
        source = self.make_media(150)
        units = self.ingest_units()
        proc = self.start_ingest_release()
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=25)
        self.addCleanup(connection.close)
        connection.putrequest("POST", "/v1/recordings/ingest")
        connection.putheader("Authorization", "Bearer " + self.ingest_token)
        connection.putheader("Content-Type", "application/vnd.serviceradar.nvr-ingest.v1")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()

        def send_chunk(data):
            connection.send(f"{len(data):x}\r\n".encode() + data + b"\r\n")

        send_chunk(self.ingest_header() + b"".join(units[:75]))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if any(p.stat().st_size > 0 for p in self.spool.glob("*/media.m4s")):
                break
            time.sleep(0.01)
        else:
            self.fail("stream did not persist a fragment before jitter pause")
        # Pause >1s between frames (exceeding the previous 1_000 ms read_timeout)
        # and >1s mid-frame across HTTP chunks to exercise IngestStream.take/2.
        time.sleep(2.5)
        send_chunk(units[75][:11])
        time.sleep(1.5)
        send_chunk(units[75][11:] + b"".join(units[76:]) + struct.pack("!I", 0))
        connection.send(b"0\r\n\r\n")

        response = connection.getresponse()
        receipt = json.loads(response.read())
        self.assertEqual(response.status, 200, receipt)
        self.assertEqual(receipt["status"], "sealed_local")
        self.assertEqual(receipt["storage_id"], self.env["NVR_TEST_EXPECTED_STORAGE_ID"])
        self.assertGreaterEqual(len(receipt["block_ids"]), 1)

        lookup_status, lookup_body = self.lookup(receipt["block_ids"])
        self.assertEqual(lookup_status, 200, lookup_body)
        for entry in json.loads(lookup_body)["blocks"]:
            self.assertEqual(entry["state"], "sealed", entry)

        proc.send_signal(signal.SIGTERM)
        log = proc.communicate(timeout=15)[0].decode(errors="replace")
        self.assertNotIn("Read timeout", log)
        self.assertNotIn("Bandit.HTTPError", log)
        self.assertNotIn("NVR ingest incomplete:", log)

        self.start_ingest_release()
        decoded = bytearray()
        for block_id in receipt["block_ids"]:
            block = self.spool / block_id
            output = self.root / (block_id + ".mp4")
            output.write_bytes((block / "init.mp4").read_bytes() + (block / "media.m4s").read_bytes())
            decoded.extend(self.decode(str(output)))
        self.assertEqual(bytes(decoded), self.decode(source))

    def test_network_ingest_read_timeout_aborts_stalled_stream_after_twenty_five_seconds(self):
        self.ingest_installation()
        self.make_media(75)
        units = self.ingest_units()
        # Keep the absolute recording budget well above the 25s read_timeout and pin
        # max_keyframe_wait_ms to 20s so the 25s read_timeout floor retires the stall cleanly.
        self.env["SERVICERADAR_NVR_MAX_DURATION_MS"] = "60000"
        self.env["SERVICERADAR_NVR_MAX_KEYFRAME_WAIT_MS"] = "20000"
        proc = self.start_ingest_release()
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=35)
        self.addCleanup(connection.close)
        connection.putrequest("POST", "/v1/recordings/ingest")
        connection.putheader("Authorization", "Bearer " + self.ingest_token)
        connection.putheader("Content-Type", "application/vnd.serviceradar.nvr-ingest.v1")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        first = self.ingest_header() + b"".join(units)
        connection.send(f"{len(first):x}\r\n".encode() + first + b"\r\n")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if any(p.stat().st_size > 0 for p in self.spool.glob("*/media.m4s")):
                break
            time.sleep(0.01)
        else:
            self.fail("stream did not persist a fragment before stall")

        stalled_at = time.monotonic()
        status = None
        response_body = None
        try:
            response = connection.getresponse()
            status = response.status
            response_body = json.loads(response.read())
        except (OSError, http.client.HTTPException, ValueError):
            pass
        elapsed = time.monotonic() - stalled_at

        self.assertGreaterEqual(elapsed, 24.0, f"stalled stream aborted too early ({elapsed:.2f}s, status={status})")
        self.assertLess(elapsed, 32.0, f"stalled stream outlived 25s read_timeout ({elapsed:.2f}s, status={status})")
        self.assertEqual(status, 408)
        self.assertEqual(response_body, {"error": "ingest_read_timeout"})

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            retry_status, retry_result = self.ingest_request(self.ingest_header() + struct.pack("!I", 0))
            if retry_status == 422:
                break
            self.assertEqual(retry_status, 503)
            time.sleep(0.05)
        else:
            self.fail("timed-out producer retained source admission")
        self.assertEqual(retry_result, {"error": "ingest_incomplete"})
        self.assert_ingest_unsealed()

        block_dirs = [p.name for p in self.spool.iterdir() if p.is_dir()]
        self.assertEqual(len(block_dirs), 1)
        lookup_status, lookup_body = self.lookup(block_dirs)
        self.assertEqual(lookup_status, 200, lookup_body)
        entry = json.loads(lookup_body)["blocks"][0]
        self.assertEqual(entry["state"], "incomplete", entry)
        self.assertFalse(entry["writing"], entry)

        proc.send_signal(signal.SIGTERM)
        log = proc.communicate(timeout=15)[0].decode(errors="replace")
        self.assertNotIn("Bandit.HTTPError", log)
        self.assertNotIn("Read timeout", log)
        self.assertRegex(log, r"NVR ingest incomplete: :(?:ingest_read_timeout|keyframe_wait_exceeded)")

    def test_network_ingest_keyframe_interval_and_wait_limits(self):
        defaults = subprocess.run(
            [
                self.binary,
                "eval",
                "{:ok, cfg} = ServiceRadarNVR.Config.load(System.get_env()); "
                "IO.inspect({cfg.max_keyframe_interval_ms, cfg.max_keyframe_wait_ms})",
            ],
            env=self.env,
            capture_output=True,
            timeout=20,
        )
        self.assertEqual(defaults.returncode, 0, defaults.stdout + defaults.stderr)
        self.assertIn(b"{15000, 35000}", defaults.stdout)

        self.ingest_installation()
        source = self.env["NVR_TEST_H264"]
        subprocess.run(
            [
                self.ffmpeg, "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i",
                "testsrc2=size=64x64:rate=15", "-frames:v", "120", "-pix_fmt", "yuv420p",
                "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0", "-sc_threshold", "0",
                "-g", "90", "-x264-params", "aud=1:repeat-headers=1", "-f", "h264", source,
            ],
            check=True,
            capture_output=True,
            timeout=30,
        )
        units = self.ingest_units()

        # 6.0s GOP (90 frames at 15fps) exceeds the old 5s limit but succeeds under the 15s default.
        proc = self.start_ingest_release()
        status, receipt = self.ingest_request(
            self.ingest_header(source="synthetic-six-second-gop") + b"".join(units) + struct.pack("!I", 0)
        )
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["status"], "sealed_local")
        self.stop_ingest_release(proc)

        # Lowering SERVICERADAR_NVR_MAX_KEYFRAME_INTERVAL_MS below 6s rejects the same 6s GOP with 422.
        self.env["SERVICERADAR_NVR_MAX_KEYFRAME_INTERVAL_MS"] = "4000"
        proc_strict = self.start_ingest_release()
        strict_status, strict_result = self.ingest_request(
            self.ingest_header(source="synthetic-six-second-gop-strict") + b"".join(units) + struct.pack("!I", 0)
        )
        self.assertEqual((strict_status, strict_result), (422, {"error": "ingest_incomplete"}))
        self.stop_ingest_release(proc_strict)

        # Lowering SERVICERADAR_NVR_MAX_KEYFRAME_WAIT_MS to 2s rejects a 3s mid-GOP stall with 422.
        self.env["SERVICERADAR_NVR_MAX_KEYFRAME_INTERVAL_MS"] = "15000"
        self.env["SERVICERADAR_NVR_MAX_KEYFRAME_WAIT_MS"] = "2000"
        self.make_media(75)
        wait_units = self.ingest_units()
        proc_wait = self.start_ingest_release()
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=15)
        self.addCleanup(connection.close)
        connection.putrequest("POST", "/v1/recordings/ingest")
        connection.putheader("Authorization", "Bearer " + self.ingest_token)
        connection.putheader("Content-Type", "application/vnd.serviceradar.nvr-ingest.v1")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        first = self.ingest_header(source="synthetic-keyframe-wait-limit") + b"".join(wait_units[:15])
        connection.send(f"{len(first):x}\r\n".encode() + first + b"\r\n")
        time.sleep(3.0)
        tail = b"".join(wait_units[15:]) + struct.pack("!I", 0)
        try:
            connection.send(f"{len(tail):x}\r\n".encode() + tail + b"\r\n")
            connection.send(b"0\r\n\r\n")
        except OSError:
            pass
        resp = connection.getresponse()
        resp_body = json.loads(resp.read())
        self.assertEqual((resp.status, resp_body), (422, {"error": "ingest_incomplete"}))
        self.stop_ingest_release(proc_wait)

    def test_foreground_release_probes_refuse_uninitialized_storage(self):
        proc = subprocess.Popen([self.binary, "start"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            base = "http://127.0.0.1:" + self.env["SERVICERADAR_NVR_HEALTH_PORT"]
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    self.fail(f"release exited: {proc.communicate()[0]}")
                try:
                    with urllib.request.urlopen(base + "/healthz", timeout=1) as reply:
                        self.assertEqual(reply.read(), b"ok")
                    break
                except urllib.error.URLError:
                    time.sleep(0.05)
            else:
                self.fail("release did not become live")
            for path, status in [("/readyz", 503), ("/recordings", 404)]:
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(base + path, timeout=2)
                self.assertEqual(failure.exception.code, status)
            self.assertEqual(list(self.spool.iterdir()), [])
            marker = self.spool / ".storage-id"
            marker.write_text(self.env["NVR_TEST_EXPECTED_STORAGE_ID"] + "\n")
            marker.chmod(0o600)
            with urllib.request.urlopen(base + "/readyz", timeout=2) as reply:
                self.assertEqual(reply.status, 200)
            self.recovery.write_bytes(self.ready.replace(b"ready", b"closed"))
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(base + "/readyz", timeout=2)
            self.assertEqual(failure.exception.code, 503)
            with urllib.request.urlopen(base + "/healthz", timeout=2) as reply:
                self.assertEqual(reply.status, 200)
        finally:
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=15)

    def test_unknown_member_cannot_adopt_another_volume(self):
        del self.env["SERVICERADAR_NVR_STORAGE_ID"]
        self.env["SERVICERADAR_NVR_MEMBER_NAME"] = "synthetic-nvr-1"
        self.env["SERVICERADAR_NVR_STORAGE_IDS"] = json.dumps({
            "synthetic-nvr-0": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
        })
        result = subprocess.run([self.binary, "eval", "{:ok, _} = Application.ensure_all_started(:serviceradar_nvr)"],
                                env=self.env, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"invalid_nvr_storage_member", result.stdout + result.stderr)
        self.assertEqual(list(self.spool.iterdir()), [])

    def test_invalid_boot_configuration_fails_closed(self):
        malformed = self.root / "delivery.json"
        malformed.write_text("{}")
        settings = [({"SERVICERADAR_NVR_" + key: "0"}, b"invalid_nvr_limit")
                    for key in ["MAX_SESSIONS", "MAX_SPOOL_BYTES", "RESERVE_BYTES", "MAX_BLOCKS"]]
        settings += [({"SERVICERADAR_NVR_MAX_BLOCKS": "262145"}, b"invalid_nvr_limit")]
        settings += [({"SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS": value}, b"invalid_nvr_limit")
                     for value in ["7", "257"]]
        settings += [({"SERVICERADAR_NVR_MAX_KEYFRAME_INTERVAL_MS": value}, b"invalid_nvr_limit")
                     for value in ["0", "999", "60001"]]
        settings += [({"SERVICERADAR_NVR_MAX_KEYFRAME_WAIT_MS": value}, b"invalid_nvr_limit")
                     for value in ["0", "999", "60001"]]
        settings += [({"SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE": str(malformed)}, b"invalid_nvr_delivery_config"),
                     ({"SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE": str(malformed),
                       "SERVICERADAR_NVR_PUBLICATION_TOKEN_FILE": str(malformed)}, b"invalid_nvr_delivery_config")]
        settings += [({"SERVICERADAR_NVR_INGEST_CONFIG_FILE": str(malformed)}, b"invalid_nvr_ingest_config"),
                     ({"SERVICERADAR_NVR_INGEST_CONFIG_FILE": str(malformed),
                       "SERVICERADAR_NVR_INGEST_TOKEN_FILE": str(malformed)}, b"invalid_nvr_ingest_config")]
        settings += [({"SERVICERADAR_NVR_PUBLICATION_AUTO_DELIVERY": value}, b"invalid_nvr_auto_delivery_config")
                     for value in ["true", "yes"]]
        settings += [({"SERVICERADAR_NVR_RECOVERY_GENERATION": "invalid"}, b"invalid_nvr_recovery_config"),
                     ({"SERVICERADAR_NVR_RECOVERY_STATE_FILE": "relative.json"}, b"invalid_nvr_recovery_config"),
                     ({"SERVICERADAR_NVR_RECOVERY_STATE_FILE": str(self.spool / "state.json")}, b"invalid_nvr_recovery_config"),
                     ({"SERVICERADAR_NVR_RECOVERY_GENERATION": ""}, b"invalid_nvr_recovery_config"),
                     ({"SERVICERADAR_NVR_RECOVERY_GENERATION": None}, b"invalid_nvr_recovery_config"),
                     ({"SERVICERADAR_NVR_RECOVERY_STATE_FILE": None}, b"invalid_nvr_recovery_config")]
        for setting, error in settings:
            with self.subTest(setting=setting):
                env = {key: value for key, value in (self.env | setting).items() if value is not None}
                result = subprocess.run([self.binary, "eval", "{:ok, _} = Application.ensure_all_started(:serviceradar_nvr)"],
                                        env=env, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stdout + result.stderr)
                self.assertEqual(list(self.spool.iterdir()), [])

    def sealed_network_block(self):
        self.ingest_installation()
        self.make_media()
        proc = self.start_ingest_release()
        status, receipt = self.ingest_request(self.ingest_header() + b"".join(self.ingest_units()) + struct.pack("!I", 0))
        self.assertEqual(status, 200, receipt)
        self.assertEqual(len(receipt["block_ids"]), 1)
        return proc, receipt["block_ids"][0]

    def descriptor_request(self, block_id, token=None):
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=20)
        try:
            connection.request("GET", f"/v1/blocks/{block_id}/descriptor",
                               headers={"Authorization": "Bearer " + (token or self.ingest_token)})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def descriptor_peer(self, status, body):
        """An independent TLS peer that answers every descriptor read with `body`."""
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def do_GET(self):
                requests.append((self.path, self.headers.get("Authorization")))
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(str(self.root / "server.pem"), str(self.root / "server-key.pem"))
        tls.load_verify_locations(str(self.root / "server-ca.pem"))
        tls.verify_mode = ssl.CERT_REQUIRED
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return requests, server.server_address[1]

    def test_descriptor_returns_the_canonical_bytes_of_a_verified_sealed_block(self):
        _proc, block_id = self.sealed_network_block()
        block = self.spool / block_id
        status, body = self.descriptor_request(block_id)
        self.assertEqual(status, 200, body)
        descriptor = json.loads(body)
        self.assertEqual(canonical(descriptor), body)
        identity = descriptor["identity"]
        key = [identity["source_id"], identity["profile"], identity["recorder_epoch"], identity["block_sequence"]]
        self.assertEqual(hashlib.sha256(json.dumps(key, separators=(",", ":")).encode()).hexdigest(), block_id)
        self.assertEqual(identity["clock"]["clock_epoch"], "synthetic-network-clock")
        for name, field in (("init.mp4", "init"), ("media.m4s", "media")):
            data = (block / name).read_bytes()
            self.assertEqual(descriptor[field], {"length": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        self.assertEqual(sum(fragment["length"] for fragment in descriptor["fragments"]), descriptor["media"]["length"])
        # The packaged client returns exactly the descriptor those bytes encode.
        self.assertEqual(self.run_client({"mode": "descriptor", "block_id": block_id, "timeout_ms": 15000}),
                         {"ok": descriptor})

        self.assertEqual(self.descriptor_request(block_id, token="incorrect-token")[0], 401)
        for unknown in ("0" * 64, "not-a-block-id"):
            self.assertEqual(self.descriptor_request(unknown), (404, b'{"error":"block_not_found"}'))
        self.assertEqual(self.run_client({"mode": "descriptor", "block_id": "0" * 64, "timeout_ms": 15000}),
                         {"error": "descriptor_status", "status": 404, "body": {"error": "block_not_found"}})
        self.assertEqual(self.run_client({"mode": "descriptor", "block_id": "not-a-block-id", "timeout_ms": 15000}),
                         {"error": ":invalid_descriptor_request"})

        # Removing the seal record leaves an open block, which has no descriptor.
        journal = (block / "journal").read_bytes()
        offset = 0
        while offset < len(journal):
            last = offset
            offset += 4 + int.from_bytes(journal[offset:offset + 4], "big") + 32
        (block / "journal").write_bytes(journal[:last])
        self.assertEqual(self.descriptor_request(block_id), (409, b'{"error":"block_not_sealed"}'))
        (block / "journal").write_bytes(journal)
        self.assertEqual(self.descriptor_request(block_id), (200, body))

        (block / "journal").write_bytes(journal[:-1] + bytes([journal[-1] ^ 1]))
        self.assertEqual(self.descriptor_request(block_id), (409, b'{"error":"block_not_sealed"}'))
        (block / "journal").write_bytes(journal)
        for name in ("journal", "init.mp4", "media.m4s"):
            with self.subTest(missing=name):
                path = block / name
                retained = path.read_bytes()
                path.unlink()
                self.assertEqual(self.descriptor_request(block_id), (409, b'{"error":"block_not_sealed"}'))
                path.write_bytes(retained)

        unavailable = self.spool.with_name("offline-spool")
        self.spool.rename(unavailable)
        try:
            self.assertEqual(self.descriptor_request("not-a-block-id"), (404, b'{"error":"block_not_found"}'))
            self.assertEqual(self.descriptor_request("not-a-block-id", token="incorrect-token")[0], 401)
            self.assertEqual(self.descriptor_request(block_id), (503, b'{"error":"descriptor_unavailable"}'))
        finally:
            unavailable.rename(self.spool)
        self.assertEqual(self.descriptor_request(block_id), (200, body))

        fragment = descriptor["fragments"][0]
        fragments = [{**fragment, "sequence": n, "offset": n * fragment["length"],
                      "start_ns": fragment["start_ns"] + n * fragment["duration_ns"]} for n in range(256)]
        large = {**descriptor, "fragments": fragments,
                 "media": {**descriptor["media"], "length": len(fragments) * fragment["length"]}}
        encoded = canonical(large)
        self.assertGreater(len(encoded), 32 * 1024)
        self.assertLess(len(encoded), 2 * 1024 * 1024)
        requests, port = self.descriptor_peer(200, encoded)
        self.assertEqual(self.run_client({"mode": "descriptor", "block_id": block_id, "timeout_ms": 15000},
                                         config_changes={"port": port}), {"ok": large})
        self.assertEqual(requests, [(f"/v1/blocks/{block_id}/descriptor", "Bearer " + self.ingest_token)])

        # The client accepts only canonical bytes whose identity derives the block it asked for.
        other = {**identity, "block_sequence": identity["block_sequence"] + 1}
        refused = (json.dumps(descriptor, indent=1).encode(), canonical({**descriptor, "identity": other}),
                   canonical({**descriptor, "version": 2}), b"x" * 2097153)
        for answer in refused:
            with self.subTest(answer=answer[:40]):
                requests, port = self.descriptor_peer(200, answer)
                self.assertEqual(self.run_client({"mode": "descriptor", "block_id": block_id, "timeout_ms": 15000},
                                                 config_changes={"port": port}),
                                 {"error": ":invalid_descriptor_response"} if len(answer) <= 2097152
                                 else {"error": ":descriptor_unavailable"})
                self.assertEqual(requests, [(f"/v1/blocks/{block_id}/descriptor", "Bearer " + self.ingest_token)])

    def read_installation(self):
        """A read listener with its own certificates, pin, token and port."""
        self.run_probe("read_certificates")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.read_port = sock.getsockname()[1]
        pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert((self.root / "read-client.pem").read_text())).hexdigest()
        config = {"port": self.read_port, "client_sha256": pin,
                  "cert_file": str(self.root / "read-server.pem"), "key_file": str(self.root / "read-server-key.pem"),
                  "ca_file": str(self.root / "read-server-ca.pem")}
        path = self.root / "read.json"
        path.write_text(json.dumps(config))
        token = self.root / "read-token"
        self.read_token = "synthetic-nvr-playback-reader-token-0123"
        token.write_text(self.read_token)
        self.env.update(SERVICERADAR_NVR_READ_CONFIG_FILE=str(path), SERVICERADAR_NVR_READ_TOKEN_FILE=str(token))
        self.read_tls = ssl.create_default_context(cafile=str(self.root / "read-client-ca.pem"))
        self.read_tls.load_cert_chain(str(self.root / "read-client.pem"), str(self.root / "read-client-key.pem"))

    def media_request(self, path, token=None):
        connection = http.client.HTTPSConnection("localhost", self.read_port, context=self.read_tls, timeout=20)
        try:
            connection.request("GET", path, headers={"Authorization": "Bearer " + (token or self.read_token)})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def read_with_client(self, block_id, digest, selector, length, sha256):
        return self.run_client({"mode": "read", "block_id": block_id, "descriptor_sha256": digest,
                                "selector": selector, "length": length, "sha256": sha256, "timeout_ms": 15000,
                                "token_path": str(self.root / "read-token")},
                               config_changes={"port": self.read_port, "ca_file": str(self.root / "read-client-ca.pem"),
                                               "cert_file": str(self.root / "read-client.pem"),
                                               "key_file": str(self.root / "read-client-key.pem")})

    def test_read_listener_serves_verified_init_and_fragments_that_decode(self):
        self.read_installation()
        _proc, block_id = self.sealed_network_block()
        block = self.spool / block_id
        status, body = self.descriptor_request(block_id)
        self.assertEqual(status, 200, body)
        descriptor = json.loads(body)
        digest = hashlib.sha256(body).hexdigest()
        query = "?descriptor_sha256=" + digest

        init = (block / "init.mp4").read_bytes()
        media = (block / "media.m4s").read_bytes()
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/init{query}"), (200, init))
        played = bytearray(init)
        for fragment in descriptor["fragments"]:
            status, data = self.media_request(f"/v1/blocks/{block_id}/fragments/{fragment['sequence']}{query}")
            self.assertEqual(status, 200)
            self.assertEqual(data, media[fragment["offset"]:fragment["offset"] + fragment["length"]])
            self.assertEqual(hashlib.sha256(data).hexdigest(), fragment["sha256"])
            played.extend(data)
        # An independent decoder plays init plus the fragments as the captured frames.
        output = self.root / "played.mp4"
        output.write_bytes(bytes(played))
        self.assertEqual(self.decode(str(output)), self.decode(self.env["NVR_TEST_H264"]))

        # The packaged client returns exactly the selected bytes, and refuses others.
        first = descriptor["fragments"][0]
        self.assertEqual(self.read_with_client(block_id, digest, first["sequence"], first["length"], first["sha256"]),
                         {"ok": {"length": first["length"], "sha256": first["sha256"]}})
        self.assertEqual(self.read_with_client(block_id, digest, "init", len(init), hashlib.sha256(init).hexdigest()),
                         {"ok": {"length": len(init), "sha256": hashlib.sha256(init).hexdigest()}})
        self.assertEqual(self.read_with_client(block_id, digest, first["sequence"], first["length"], "0" * 64),
                         {"error": ":integrity_mismatch"})
        self.assertEqual(self.read_with_client(block_id, "0" * 64, first["sequence"], first["length"], first["sha256"]),
                         {"error": ":integrity_mismatch"})
        self.assertEqual(self.read_with_client("0" * 64, digest, first["sequence"], first["length"], first["sha256"]),
                         {"error": ":not_found"})

        # Refusals: wrong descriptor, malformed request, unknown block or fragment, wrong token.
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/init?descriptor_sha256=" + "0" * 64),
                         (409, b'{"error":"descriptor_mismatch"}'))
        for path in (f"/v1/blocks/{block_id}/init", f"/v1/blocks/{block_id}/init{query}&extra=1",
                     f"/v1/blocks/{block_id}/init?descriptor_sha256=XYZ"):
            self.assertEqual(self.media_request(path), (400, b'{"error":"invalid_read_request"}'))
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/fragments/{len(descriptor['fragments'])}{query}"),
                         (404, b'{"error":"fragment_not_found"}'))
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/fragments/01{query}"),
                         (404, b'{"error":"fragment_not_found"}'))
        self.assertEqual(self.media_request(f"/v1/blocks/{'0' * 64}/init{query}"), (404, b'{"error":"block_not_found"}'))
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/init{query}", token=self.ingest_token)[0], 401)
        # The read token opens nothing on the ingest listener.
        self.assertEqual(self.descriptor_request(block_id, token=self.read_token)[0], 401)

        # A block whose seal no longer verifies is not served.
        journal = (block / "journal").read_bytes()
        offset = 0
        while offset < len(journal):
            last = offset
            offset += 4 + int.from_bytes(journal[offset:offset + 4], "big") + 32
        (block / "journal").write_bytes(journal[:last])
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/init{query}"), (409, b'{"error":"block_not_sealed"}'))
        (block / "journal").write_bytes(journal[:-1] + bytes([journal[-1] ^ 1]))
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/init{query}"), (409, b'{"error":"block_not_sealed"}'))
        self.assertEqual(
            self.read_with_client(block_id, digest, "init", len(init), hashlib.sha256(init).hexdigest()),
            {"error": ":integrity_mismatch"},
        )
        (block / "journal").write_bytes(journal)
        self.assertEqual(self.media_request(f"/v1/blocks/{block_id}/init{query}"), (200, init))

    def test_read_listener_refuses_ingest_credentials_at_boot(self):
        self.ingest_installation()
        self.read_installation()
        ingest = json.loads(Path(self.env["SERVICERADAR_NVR_INGEST_CONFIG_FILE"]).read_text())
        read = json.loads(Path(self.env["SERVICERADAR_NVR_READ_CONFIG_FILE"]).read_text())
        shared = self.root / "read-shared.json"
        for changes, token in (({"port": ingest["port"]}, self.env["SERVICERADAR_NVR_READ_TOKEN_FILE"]),
                               ({"client_sha256": ingest["client_sha256"]}, self.env["SERVICERADAR_NVR_READ_TOKEN_FILE"]),
                               ({}, self.env["SERVICERADAR_NVR_INGEST_TOKEN_FILE"])):
            with self.subTest(changes=changes, token=token):
                shared.write_text(json.dumps(read | changes))
                env = self.env | {"SERVICERADAR_NVR_READ_CONFIG_FILE": str(shared),
                                  "SERVICERADAR_NVR_READ_TOKEN_FILE": token}
                result = subprocess.run([self.binary, "eval", "{:ok, _} = Application.ensure_all_started(:serviceradar_nvr)"],
                                        env=env, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"invalid_nvr_read_config", result.stdout + result.stderr)

    def member_request_with_headers(self, method, path, body=None, content_type=None, token=None):
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=20)
        headers = {"Authorization": "Bearer " + (token or self.ingest_token)}
        if content_type:
            headers["Content-Type"] = content_type
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            resp_headers = {k.lower(): v for k, v in response.getheaders()}
            return response.status, response.read(), resp_headers
        finally:
            connection.close()

    def member_request(self, method, path, body=None, content_type=None, token=None):
        status, body, _headers = self.member_request_with_headers(method, path, body, content_type, token)
        return status, body

    def lookup(self, block_ids, content_type="application/vnd.serviceradar.nvr-lookup.v1+json"):
        return self.member_request("POST", "/v1/blocks/lookup", canonical({"block_ids": block_ids}), content_type)

    def member_status(self):
        status, body = self.member_request("GET", "/v1/status")
        self.assertEqual(status, 200, body)
        return json.loads(body)

    def block_bytes(self, block_id):
        return sum(path.stat().st_size for path in (self.spool / block_id).iterdir())

    def test_member_status_lookup_and_ledger_pages_report_local_block_state(self):
        _proc, block_id = self.sealed_network_block()
        status, descriptor = self.descriptor_request(block_id)
        self.assertEqual(status, 200)
        digest = hashlib.sha256(descriptor).hexdigest()
        stored = self.block_bytes(block_id)

        report = self.member_status()
        self.assertEqual({key: report[key] for key in ("version", "storage_id", "recovery", "inventory", "archive_busy",
                                                       "max_sessions")},
                         {"version": 1, "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                          "recovery": {"state": "ready", "generation": self.generation}, "inventory": "ready",
                          "archive_busy": False, "max_sessions": 2})
        self.assertEqual({key: report["capacity"][key] for key in ("blocks", "max_blocks", "used_bytes", "reservations")},
                         {"blocks": 1, "max_blocks": 131072, "used_bytes": stored, "reservations": 0})

        sealed = {"block_id": block_id, "state": "sealed", "writing": False, "bytes": stored, "descriptor_sha256": digest}
        absent = {"block_id": "0" * 64, "state": "absent", "writing": False, "bytes": None}
        status, body = self.lookup([block_id, "0" * 64])
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body), {"version": 1, "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                            "blocks": [sealed, absent]})

        pages = {"?limit=100": ([sealed], None), "?limit=1": ([sealed], block_id), f"?after={block_id}": ([], None)}
        for query, (blocks, next_after) in pages.items():
            with self.subTest(query=query):
                status, body = self.member_request("GET", "/v1/blocks" + query)
                self.assertEqual(status, 200, body)
                self.assertEqual(json.loads(body), {"version": 1, "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                                    "blocks": blocks, "next_after": next_after})

        # The packaged client returns the same observations, checked against the request.
        self.assertEqual(self.run_client({"mode": "lookup", "block_ids": [block_id, "0" * 64], "timeout_ms": 15000}),
                         {"ok": {"storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                 "blocks": [sealed | {"reason": None}, absent | {"descriptor_sha256": None, "reason": None}]}})
        self.assertEqual(self.run_client({"mode": "page", "after": None, "limit": 1, "timeout_ms": 15000}),
                         {"ok": {"storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                 "blocks": [sealed | {"reason": None}], "next_after": block_id}})
        status_result = self.run_client({"mode": "status", "timeout_ms": 15000})["ok"]
        self.assertEqual((status_result["storage_id"], status_result["inventory"], status_result["capacity"]["blocks"]),
                         (self.env["NVR_TEST_EXPECTED_STORAGE_ID"], "ready", 1))

        # A journal without its seal record is incomplete and has no descriptor digest.
        block = self.spool / block_id
        journal = (block / "journal").read_bytes()
        offset = 0
        while offset < len(journal):
            last = offset
            offset += 4 + int.from_bytes(journal[offset:offset + 4], "big") + 32
        (block / "journal").write_bytes(journal[:last])
        status, body = self.lookup([block_id])
        self.assertEqual(json.loads(body)["blocks"],
                         [{"block_id": block_id, "state": "incomplete", "writing": False, "bytes": stored - (len(journal) - last)}])

        # A corrupt journal digest is reported as unresolved with its error class and no digest.
        (block / "journal").write_bytes(journal[:-1] + bytes([journal[-1] ^ 1]))
        unresolved = {"block_id": block_id, "state": "unresolved", "writing": False, "bytes": stored,
                      "reason": "invalid_journal_record"}
        status, body = self.lookup([block_id])
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body)["blocks"], [unresolved])
        status, body = self.member_request("GET", "/v1/blocks?limit=10")
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body)["blocks"], [unresolved])
        self.assertEqual(self.run_client({"mode": "lookup", "block_ids": [block_id], "timeout_ms": 15000}),
                         {"ok": {"storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                 "blocks": [unresolved | {"descriptor_sha256": None}]}})
        self.assertEqual(self.run_client({"mode": "page", "after": None, "limit": 10, "timeout_ms": 15000}),
                         {"ok": {"storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
                                 "blocks": [unresolved | {"descriptor_sha256": None}], "next_after": None}})
        (block / "journal").write_bytes(journal)

        # A closed recovery gate is reported on /v1/status (200) and refuses lookup/pages with 503 + retry-after.
        self.recovery.write_bytes(self.ready.replace(b"ready", b"closed"))
        closed_report = self.member_status()
        self.assertEqual(
            {key: closed_report[key] for key in ("recovery", "inventory", "capacity")},
            {"recovery": {"state": "closed", "generation": self.generation},
             "inventory": "unavailable", "capacity": None},
        )
        closed_client = self.run_client({"mode": "status", "timeout_ms": 15000})["ok"]
        self.assertEqual(
            (closed_client["recovery"], closed_client["inventory"], closed_client["capacity"]),
            ({"state": "closed", "generation": self.generation}, "unavailable", None),
        )
        status, body, headers = self.member_request_with_headers(
            "POST", "/v1/blocks/lookup", canonical({"block_ids": [block_id]}),
            "application/vnd.serviceradar.nvr-lookup.v1+json",
        )
        self.assertEqual((status, body, headers.get("retry-after")),
                         (503, b'{"error":"lookup_unavailable"}', "1"))
        self.assertEqual(self.run_client({"mode": "lookup", "block_ids": [block_id], "timeout_ms": 15000}),
                         {"error": "lookup_status", "status": 503, "body": {"error": "lookup_unavailable"}})
        status, body, headers = self.member_request_with_headers("GET", "/v1/blocks?limit=10")
        self.assertEqual((status, body, headers.get("retry-after")),
                         (503, b'{"error":"inventory_unavailable"}', "1"))
        self.assertEqual(self.run_client({"mode": "page", "after": None, "limit": 10, "timeout_ms": 15000}),
                         {"error": "inventory_status", "status": 503, "body": {"error": "inventory_unavailable"}})
        self.recovery.write_bytes(self.ready)
        self.assertEqual(self.member_status()["inventory"], "ready")

        # Malformed requests are refused before any read; the ingest token is required.
        for ids in ([], ["0" * 64] * 2, ["x"], ["%064x" % index for index in range(51)]):
            with self.subTest(ids=len(ids)):
                self.assertEqual(self.lookup(ids), (400, b'{"error":"invalid_lookup_request"}'))
        self.assertEqual(self.lookup([block_id], content_type="application/json")[0], 400)
        for query in ("?limit=0", "?limit=101", "?limit=01", "?after=XYZ", "?after[a]=1", "?limit=1&extra=1"):
            with self.subTest(query=query):
                self.assertEqual(self.member_request("GET", "/v1/blocks" + query),
                                 (400, b'{"error":"invalid_inventory_request"}'))
        bad_token = "incorrect-token-for-the-ingest-listener"
        self.assertEqual(self.member_request("GET", "/v1/status", token=bad_token)[0], 401)
        self.assertEqual(self.member_request("POST", "/v1/blocks/lookup", canonical({"block_ids": [block_id]}),
                                             "application/vnd.serviceradar.nvr-lookup.v1+json", token=bad_token)[0], 401)
        self.assertEqual(self.member_request("GET", "/v1/blocks?limit=1", token=bad_token)[0], 401)

    def test_lookup_and_ledger_page_enforce_storage_gate_and_active_block_guards(self):
        self.make_media()
        self.run_probe("lookup_page_guards")

    def test_block_ledger_caps_admission_rebuilds_on_restart_and_closes_admission_on_mismatch(self):
        self.env["SERVICERADAR_NVR_MAX_BLOCKS"] = "1"
        proc, block_id = self.sealed_network_block()
        stored = self.block_bytes(block_id)
        units = b"".join(self.ingest_units()) + struct.pack("!I", 0)
        identity = {"source_id": "synthetic-network-camera", "profile": "recording", "recorder_epoch": 1}

        # At the cap a new recording is refused; reads and lookups keep working.
        status, body = self.ingest_request(self.ingest_header(identity=identity | {"block_sequence": 1}) + units)
        self.assertEqual((status, body), (503, {"error": "ingest_unavailable"}))
        self.assertEqual(self.descriptor_request(block_id)[0], 200)
        self.assertEqual(json.loads(self.lookup([block_id])[1])["blocks"][0]["state"], "sealed")
        self.assertEqual({key: self.member_status()["capacity"][key] for key in ("blocks", "max_blocks", "used_bytes")},
                         {"blocks": 1, "max_blocks": 1, "used_bytes": stored})

        # After a restart the ledger is rebuilt from the volume with the same charge.
        self.stop_ingest_release(proc)
        self.env["SERVICERADAR_NVR_MAX_BLOCKS"] = "8"
        self.start_ingest_release()
        self.assertEqual({key: self.member_status()["capacity"][key] for key in ("blocks", "max_blocks", "used_bytes")},
                         {"blocks": 1, "max_blocks": 8, "used_bytes": stored})
        status, receipt = self.ingest_request(self.ingest_header(identity=identity | {"block_sequence": 1}) + units)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(self.member_status()["capacity"]["blocks"], 2)

        # A directory the ledger did not record closes admission; nothing is repaired or removed.
        before = {str(path.relative_to(self.spool)): path.read_bytes() for path in self.spool.rglob("*") if path.is_file()}
        stray = self.spool / ("c" * 64)
        stray.mkdir(mode=0o700)
        deadline = time.monotonic() + 15
        while self.member_status()["inventory"] != "mismatch":
            self.assertLess(time.monotonic(), deadline, "the audit did not report the unrecorded directory")
            time.sleep(0.2)
        status, body = self.ingest_request(self.ingest_header(identity=identity | {"block_sequence": 2}) + units)
        self.assertEqual((status, body), (503, {"error": "ingest_unavailable"}))
        self.assertTrue(stray.is_dir())
        self.assertEqual(before, {str(path.relative_to(self.spool)): path.read_bytes()
                                  for path in self.spool.rglob("*") if path.is_file()})

    def test_member_status_and_ledger_page_report_rebuilding_over_http(self):
        self.ingest_installation()
        for index in range(1025):
            (self.spool / f"{index:064x}").mkdir(mode=0o700)

        # First /v1/blocks call on a >1024-block volume triggers step 1 and reports 503 inventory_rebuilding.
        proc = self.start_ingest_release()
        status, body, headers = self.member_request_with_headers("GET", "/v1/blocks?limit=1")
        self.assertEqual((status, body, headers.get("retry-after")),
                         (503, b'{"error":"inventory_rebuilding"}', "1"))
        self.stop_ingest_release(proc)

        # Fresh restart: first /v1/status call via packaged client reports 200 inventory=rebuilding, capacity=null.
        self.start_ingest_release()
        rebuilding = self.run_client({"mode": "status", "timeout_ms": 15000})["ok"]
        self.assertEqual((rebuilding["inventory"], rebuilding["capacity"]), ("rebuilding", None))
        deadline = time.monotonic() + 15
        while True:
            report = self.member_status()
            if report["inventory"] == "ready":
                break
            self.assertLess(time.monotonic(), deadline, "ledger rebuild did not finish")
            time.sleep(0.1)
        self.assertEqual(report["capacity"]["blocks"], 1025)

    def reclaim_document(self, digest, operation_id="00000000-0000-4000-8000-000000000088", **changes):
        document = {
            "version": 1,
            "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
            "recovery_generation": self.generation,
            "operation_id": operation_id,
            "expected_descriptor_sha256": digest,
        }
        document.update(changes)
        return document

    def reclaim_request(self, block_id, body, content_type="application/vnd.serviceradar.nvr-reclaim.v1+json", token=None):
        payload = canonical(body) if isinstance(body, dict) else body
        return self.member_request_with_headers("POST", f"/v1/blocks/{block_id}/reclaim", payload, content_type, token)

    def test_reclaim_tombstones_unlinks_updates_capacity_and_is_idempotent(self):
        proc, block_id = self.sealed_network_block()
        status, descriptor = self.descriptor_request(block_id)
        self.assertEqual(status, 200, descriptor)
        digest = hashlib.sha256(descriptor).hexdigest()
        stored = self.block_bytes(block_id)
        self.assertEqual(self.member_status()["capacity"]["blocks"], 1)
        self.assertEqual(self.member_status()["capacity"]["used_bytes"], stored)

        document = self.reclaim_document(digest)
        journal_path = self.spool / ".disposition-journal"

        # Digest mismatch refuses without deleting files or writing a tombstone.
        status, body, _ = self.reclaim_request(block_id, self.reclaim_document("0" * 64))
        self.assertEqual((status, body), (409, b'{"error":"descriptor_mismatch"}'))
        self.assertTrue((self.spool / block_id).is_dir())
        self.assertFalse(journal_path.exists())

        # Unknown block, malformed requests, wrong token, and closed recovery gate are refused.
        self.assertEqual(self.reclaim_request("0" * 64, document)[:2], (404, b'{"error":"block_not_found"}'))
        self.assertEqual(self.reclaim_request("not-a-block-id", document)[:2], (404, b'{"error":"block_not_found"}'))
        for invalid in (
            self.reclaim_document(digest, storage_id="00000000-0000-4000-8000-000000000099"),
            self.reclaim_document(digest, recovery_generation="00000000-0000-4000-8000-000000000098"),
            self.reclaim_document(digest, operation_id="not-a-uuid"),
            self.reclaim_document(digest, expected_descriptor_sha256="short"),
            self.reclaim_document(digest, extra=True),
            json.dumps(document, indent=1).encode(),
            b"not json",
        ):
            self.assertEqual(self.reclaim_request(block_id, invalid)[:2], (400, b'{"error":"invalid_reclaim_request"}'))
        self.assertEqual(self.reclaim_request(block_id, document, content_type="application/json")[0], 400)
        self.assertEqual(self.reclaim_request(block_id, document, token="incorrect-token")[0], 401)

        self.recovery.write_bytes(self.ready.replace(b"ready", b"closed"))
        status, body, headers = self.reclaim_request(block_id, document)
        self.assertEqual((status, body, headers.get("retry-after")), (503, b'{"error":"reclaim_unavailable"}', "1"))
        self.recovery.write_bytes(self.ready)
        self.assertTrue((self.spool / block_id).is_dir())
        self.assertFalse(journal_path.exists())

        # Happy path via packaged client: unlinks block, writes 0600 journal, frees capacity immediately.
        reclaimed = self.run_client(
            {"mode": "reclaim", "block_id": block_id, "reclaim_request": document, "timeout_ms": 15000}
        )
        self.assertIn("ok", reclaimed, reclaimed)
        receipt = reclaimed["ok"]
        self.assertEqual(
            {k: receipt[k] for k in ("storage_id", "block_id", "operation_id", "status")},
            {"storage_id": document["storage_id"], "block_id": block_id, "operation_id": document["operation_id"],
             "status": "reclaimed"},
        )
        self.assertGreater(receipt["reclaimed_at_ms"], 0)
        self.assertFalse((self.spool / block_id).exists())
        self.assertTrue(journal_path.is_file())
        self.assertEqual(journal_path.stat().st_mode & 0o777, 0o600)

        after_status = self.member_status()
        self.assertEqual(after_status["inventory"], "ready")
        self.assertEqual((after_status["capacity"]["blocks"], after_status["capacity"]["used_bytes"]), (0, 0))

        expected_lookup = {"block_id": block_id, "state": "reclaimed", "writing": False, "bytes": None}
        status, body = self.lookup([block_id])
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body)["blocks"], [expected_lookup])
        self.assertEqual(
            self.run_client({"mode": "lookup", "block_ids": [block_id], "timeout_ms": 15000}),
            {"ok": {"storage_id": document["storage_id"],
                    "blocks": [expected_lookup | {"descriptor_sha256": None, "reason": None}]}},
        )
        status, body = self.member_request("GET", "/v1/blocks?limit=10")
        self.assertEqual((status, json.loads(body)["blocks"], json.loads(body)["next_after"]), (200, [], None))

        # Exact retry is idempotent; different operation_id or digest is a 409 conflict/mismatch.
        retry = self.run_client(
            {"mode": "reclaim", "block_id": block_id, "reclaim_request": document, "timeout_ms": 15000}
        )
        self.assertEqual(retry, reclaimed)
        conflict_doc = self.reclaim_document(digest, operation_id="00000000-0000-4000-8000-000000000089")
        self.assertEqual(
            self.run_client({"mode": "reclaim", "block_id": block_id, "reclaim_request": conflict_doc, "timeout_ms": 15000}),
            {"error": "reclaim_status", "status": 409, "body": {"error": "reclaim_conflict"}},
        )
        self.assertEqual(self.reclaim_request(block_id, self.reclaim_document("0" * 64))[:2],
                         (409, b'{"error":"descriptor_mismatch"}'))

        # Restart accepts the disposition journal, keeps capacity at 0, reports reclaimed, and admits new recordings.
        self.stop_ingest_release(proc)
        self.start_ingest_release()
        restarted = self.member_status()
        self.assertEqual(restarted["inventory"], "ready")
        self.assertEqual((restarted["capacity"]["blocks"], restarted["capacity"]["used_bytes"]), (0, 0))
        self.assertEqual(json.loads(self.lookup([block_id])[1])["blocks"], [expected_lookup])
        identity = {"source_id": "synthetic-network-camera", "profile": "recording", "recorder_epoch": 1, "block_sequence": 1}
        status, next_receipt = self.ingest_request(
            self.ingest_header(identity=identity) + b"".join(self.ingest_units()) + struct.pack("!I", 0)
        )
        self.assertEqual(status, 200, next_receipt)
        self.assertEqual(self.member_status()["capacity"]["blocks"], 1)

    def test_reclaim_refuses_active_and_unsealed_blocks_and_boot_finishes_pending_tombstone(self):
        self.ingest_installation()
        self.make_media(75)
        units = self.ingest_units()
        proc = self.start_ingest_release()

        # Start an active ingest stream without sending the end marker.
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=20)
        self.addCleanup(connection.close)
        connection.putrequest("POST", "/v1/recordings/ingest")
        connection.putheader("Authorization", "Bearer " + self.ingest_token)
        connection.putheader("Content-Type", "application/vnd.serviceradar.nvr-ingest.v1")
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        first = self.ingest_header() + b"".join(units)
        connection.send(f"{len(first):x}\r\n".encode() + first + b"\r\n")

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            dirs = [p.name for p in self.spool.iterdir() if p.is_dir()]
            if dirs and any(p.stat().st_size > 0 for p in self.spool.glob("*/media.m4s")):
                active_id = dirs[0]
                break
            time.sleep(0.02)
        else:
            self.fail("active stream did not persist a fragment")

        # Active writer block cannot be reclaimed.
        doc = self.reclaim_document("a" * 64)
        self.assertEqual(self.reclaim_request(active_id, doc)[:2], (409, b'{"error":"block_active"}'))
        self.assertTrue((self.spool / active_id).is_dir())
        self.assertFalse((self.spool / ".disposition-journal").exists())

        # Drop the connection without sealing; once writer retires, incomplete block is also refused.
        connection.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            entry = json.loads(self.lookup([active_id])[1])["blocks"][0]
            if not entry["writing"]:
                break
            time.sleep(0.05)
        else:
            self.fail("writer did not retire after connection close")
        self.assertEqual(entry["state"], "incomplete", entry)
        self.assertEqual(self.reclaim_request(active_id, doc)[:2], (409, b'{"error":"block_not_sealed"}'))
        self.assertTrue((self.spool / active_id).is_dir())

        # Simulate a mid-reclaim crash: committed tombstone + leftover block dir + partial trailing line.
        self.stop_ingest_release(proc)
        journal_path = self.spool / ".disposition-journal"
        tombstone = canonical({
            "version": 1,
            "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
            "block_id": active_id,
            "operation_id": "00000000-0000-4000-8000-000000000090",
            "expected_descriptor_sha256": "a" * 64,
            "reclaimed_at_ms": 1700000000000,
        })
        journal_path.write_bytes(tombstone + b"\n" + b'{"partial":"truncated')
        journal_path.chmod(0o600)

        # Restart truncates the partial tail, completes unlinking the leftover directory, and reports reclaimed state.
        proc = self.start_ingest_release()
        report = self.member_status()
        self.assertEqual(report["inventory"], "ready")
        self.assertEqual((report["capacity"]["blocks"], report["capacity"]["used_bytes"]), (0, 0))
        self.assertFalse((self.spool / active_id).exists())
        self.assertEqual(journal_path.read_bytes(), tombstone + b"\n")
        self.assertEqual(
            json.loads(self.lookup([active_id])[1])["blocks"],
            [{"block_id": active_id, "state": "reclaimed", "writing": False, "bytes": None}],
        )
        status, body = self.member_request("GET", "/v1/blocks?limit=10")
        self.assertEqual((status, json.loads(body)["blocks"]), (200, []))

        # Reclaiming another block after partial-tail truncation appends cleanly and survives restart.
        second_identity = {
            "source_id": "synthetic-network-camera",
            "profile": "recording",
            "recorder_epoch": 1,
            "block_sequence": 1,
        }
        status, next_receipt = self.ingest_request(
            self.ingest_header(identity=second_identity) + b"".join(units) + struct.pack("!I", 0)
        )
        self.assertEqual(status, 200, next_receipt)
        second_id = next_receipt["block_ids"][0]
        status, second_descriptor = self.descriptor_request(second_id)
        self.assertEqual(status, 200, second_descriptor)
        second_digest = hashlib.sha256(second_descriptor).hexdigest()
        second_doc = self.reclaim_document(second_digest, operation_id="00000000-0000-4000-8000-000000000091")
        status, body, _ = self.reclaim_request(second_id, second_doc)
        self.assertEqual(status, 200, body)
        self.assertFalse((self.spool / second_id).exists())

        self.stop_ingest_release(proc)
        self.start_ingest_release()
        after_restart = self.member_status()
        self.assertEqual(after_restart["inventory"], "ready")
        self.assertEqual((after_restart["capacity"]["blocks"], after_restart["capacity"]["used_bytes"]), (0, 0))
        self.assertEqual(
            json.loads(self.lookup([active_id, second_id])[1])["blocks"],
            [
                {"block_id": active_id, "state": "reclaimed", "writing": False, "bytes": None},
                {"block_id": second_id, "state": "reclaimed", "writing": False, "bytes": None},
            ],
        )

    def test_reclaim_unblocks_cap_refuses_reingest_and_fails_closed_on_unsafe_journal(self):
        self.env["SERVICERADAR_NVR_MAX_BLOCKS"] = "1"
        proc, block_id = self.sealed_network_block()
        units = b"".join(self.ingest_units()) + struct.pack("!I", 0)
        base_identity = {"source_id": "synthetic-network-camera", "profile": "recording", "recorder_epoch": 1}

        # At the 1-block cap, a second block is refused.
        self.assertEqual(
            self.ingest_request(self.ingest_header(identity=base_identity | {"block_sequence": 1}) + units),
            (503, {"error": "ingest_unavailable"}),
        )

        # Reclaiming block 0 immediately releases the cap without restart.
        status, descriptor = self.descriptor_request(block_id)
        self.assertEqual(status, 200, descriptor)
        digest = hashlib.sha256(descriptor).hexdigest()
        status, body, _ = self.reclaim_request(block_id, self.reclaim_document(digest))
        self.assertEqual(status, 200, body)
        self.assertEqual(self.descriptor_request(block_id), (404, b'{"error":"block_not_found"}'))

        # Re-ingesting the tombstoned block identity is refused and does not recreate the directory.
        self.assertEqual(
            self.ingest_request(self.ingest_header(identity=base_identity | {"block_sequence": 0}) + units),
            (503, {"error": "ingest_unavailable"}),
        )
        self.assertFalse((self.spool / block_id).exists())

        # Ingesting block 1 succeeds immediately in the same process, and the 1s audit stays ready.
        status, next_receipt = self.ingest_request(
            self.ingest_header(identity=base_identity | {"block_sequence": 1}) + units
        )
        self.assertEqual(status, 200, next_receipt)
        second_id = next_receipt["block_ids"][0]
        time.sleep(1.5)
        steady = self.member_status()
        self.assertEqual(steady["inventory"], "ready")
        self.assertEqual(steady["capacity"]["blocks"], 1)

        # An unsafe (world-readable) disposition journal fails closed without mutating files.
        status, second_descriptor = self.descriptor_request(second_id)
        self.assertEqual(status, 200, second_descriptor)
        second_digest = hashlib.sha256(second_descriptor).hexdigest()
        self.stop_ingest_release(proc)
        journal_path = self.spool / ".disposition-journal"
        saved_journal = journal_path.read_bytes()
        journal_path.chmod(0o644)

        proc = self.start_ingest_release()
        unsafe_status = self.member_status()
        self.assertEqual((unsafe_status["inventory"], unsafe_status["capacity"]), ("unavailable", None))
        status, body, headers = self.reclaim_request(
            second_id, self.reclaim_document(second_digest, operation_id="00000000-0000-4000-8000-000000000092")
        )
        self.assertEqual((status, body, headers.get("retry-after")), (503, b'{"error":"reclaim_unavailable"}', "1"))
        self.assertTrue((self.spool / second_id).is_dir())
        self.assertEqual(journal_path.read_bytes(), saved_journal)

        # A journal containing only an unterminated partial fragment (0 committed lines) truncates to empty on boot.
        self.stop_ingest_release(proc)
        journal_path.write_bytes(b'{"partial":"first-line-interrupted')
        journal_path.chmod(0o600)
        proc = self.start_ingest_release()
        recovered = self.member_status()
        self.assertEqual(recovered["inventory"], "ready")
        self.assertEqual(recovered["capacity"]["blocks"], 1)
        self.assertEqual(journal_path.read_bytes(), b"")

        # Subsequent reclaim appends cleanly at offset 0 and survives restart.
        second_doc = self.reclaim_document(second_digest, operation_id="00000000-0000-4000-8000-000000000093")
        status, body, _ = self.reclaim_request(second_id, second_doc)
        self.assertEqual(status, 200, body)
        self.assertFalse((self.spool / second_id).exists())
        self.stop_ingest_release(proc)
        self.start_ingest_release()
        self.assertEqual(
            json.loads(self.lookup([second_id])[1])["blocks"],
            [{"block_id": second_id, "state": "reclaimed", "writing": False, "bytes": None}],
        )


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


class NVRArchiveReleaseTest(NVRReleaseTest):
    """Archive a sealed block from the packaged release to a synthetic object store.

    The store is a plain-HTTP path-style S3 peer on a numeric loopback address,
    the only plaintext target the Longshore client accepts. It keeps objects in
    memory, honours If-None-Match/If-Match and answers ranged reads with 206.
    """

    content_type = "application/vnd.serviceradar.nvr-archive.v1+json"
    secret = "example-archive-secret-not-a-credential"

    def object_store(self):
        store = {"objects": {}, "requests": [], "refuse_put": False, "corrupt_get": False,
                 "hold": None, "held": threading.Event()}
        bucket = "/example-archive/"

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def record(self, method):
                key = self.path[len(bucket):] if self.path.startswith(bucket) else None
                store["requests"].append((method, key, {k.lower(): v for k, v in self.headers.items()}))
                return key

            def reply(self, status, headers=(), body=b"", length=None):
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(body) if length is None else length))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def do_PUT(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                key = self.record("PUT")
                if store["hold"] is not None:
                    store["held"].set()
                    store["hold"].wait(30)
                if store["refuse_put"]:
                    return self.reply(403, body=b"<Error><Code>AccessDenied</Code></Error>")
                if key in store["objects"] and self.headers.get("If-None-Match") == "*":
                    return self.reply(412, body=b"<Error><Code>PreconditionFailed</Code></Error>")
                if self.headers.get("x-amz-checksum-sha256") != base64.b64encode(hashlib.sha256(body).digest()).decode():
                    return self.reply(400, body=b"<Error><Code>BadDigest</Code></Error>")
                etag = '"' + hashlib.sha256(b"etag" + body).hexdigest()[:32] + '"'
                store["objects"][key] = (body, etag)
                return self.reply(200, [("ETag", etag), ("x-amz-server-side-encryption", "AES256")])

            def stored(self, method):
                key = self.record(method)
                if key not in store["objects"]:
                    return None
                body, etag = store["objects"][key]
                if self.headers.get("If-Match") not in (None, etag):
                    return None
                return body, etag

            def do_HEAD(self):
                found = self.stored("HEAD")
                if found is None:
                    return self.reply(404)
                body, etag = found
                return self.reply(200, [("ETag", etag), ("x-amz-server-side-encryption", "AES256")], length=len(body))

            def do_GET(self):
                found = self.stored("GET")
                if found is None:
                    return self.reply(412, body=b"<Error><Code>PreconditionFailed</Code></Error>")
                body, etag = found
                first, last = (int(n) for n in self.headers["Range"].removeprefix("bytes=").split("-"))
                chunk = body[first:last + 1]
                if store["corrupt_get"]:
                    chunk = bytes([chunk[0] ^ 1]) + chunk[1:]
                return self.reply(206, [("ETag", etag), ("Content-Range", f"bytes {first}-{last}/{len(body)}")], chunk)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return store, server.server_address[1]

    def archive_document(self, port, **changes):
        document = {
            "version": 1, "storage_id": self.env["NVR_TEST_EXPECTED_STORAGE_ID"],
            "recovery_generation": self.generation,
            # The test peer listens on an ephemeral port; providers use the default 443.
            "destination": {"host": "127.0.0.1", "port": port, "region": "example-region-1",
                            "bucket": "example-archive", "object_prefix": "recordings/v1"},
            "credential": {"access_key_id": "EXAMPLEARCHIVEKEY", "secret_access_key": self.secret},
        }
        document.update(changes)
        return document

    def archive_request(self, block_id, body, content_type=None, token=None):
        connection = http.client.HTTPSConnection("localhost", self.ingest_port, context=self.ingest_tls, timeout=90)
        try:
            connection.request("POST", f"/v1/blocks/{block_id}/archive",
                               body=canonical(body) if isinstance(body, dict) else body,
                               headers={"Authorization": "Bearer " + (token or self.ingest_token),
                                        "Content-Type": content_type or self.content_type})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def object_prefix(self, block_id):
        return f"recordings/v1/{self.env['NVR_TEST_EXPECTED_STORAGE_ID']}/{block_id}/"

    def test_archive_copies_sealed_block_and_returns_retained_receipt_after_restart(self):
        proc, block_id = self.sealed_network_block()
        block = self.spool / block_id
        store, port = self.object_store()
        document = self.archive_document(port)
        result = self.run_client({"mode": "archive", "block_id": block_id, "archive_request": document,
                                  "timeout_ms": 60000}, timeout=90)
        self.assertIn("ok", result, result)
        retained = (block / "archive-receipt.json").read_bytes()
        self.assertEqual(retained, canonical(result["ok"]))
        receipt = json.loads(retained)
        self.assertEqual({key: receipt[key] for key in ("version", "storage_id", "block_id", "destination")},
                         {"version": 1, "storage_id": document["storage_id"], "block_id": block_id,
                          "destination": document["destination"]})
        self.assertGreater(receipt["verified_at_ms"], 0)
        prefix = self.object_prefix(block_id)
        self.assertEqual([entry["name"] for entry in receipt["objects"]], ["init.mp4", "media.m4s", "descriptor.json"])
        for entry in receipt["objects"]:
            body, etag = store["objects"][prefix + entry["name"]]
            self.assertEqual(entry, {"name": entry["name"], "key": prefix + entry["name"], "length": len(body),
                                     "sha256": hashlib.sha256(body).hexdigest(), "etag": etag})
        for name in ("init.mp4", "media.m4s"):
            self.assertEqual(store["objects"][prefix + name][0], (block / name).read_bytes())
        puts = [headers for method, _key, headers in store["requests"] if method == "PUT"]
        self.assertEqual(len(puts), 3)
        for headers in puts:
            self.assertEqual((headers["if-none-match"], headers["x-amz-server-side-encryption"]), ("*", "AES256"))
            self.assertTrue(headers["authorization"].startswith("AWS4-HMAC-SHA256 Credential=EXAMPLEARCHIVEKEY/"))
        reads = [headers for method, _key, headers in store["requests"] if method == "GET"]
        self.assertEqual(len(reads), 3)
        self.assertTrue(all(headers["if-match"].startswith('"') and headers["range"] for headers in reads))
        self.assertNotIn(self.secret.encode(), retained)

        # A restarted NVR inventories the receipt beside its block, charges it and
        # returns the same receipt without contacting the provider again.
        self.stop_ingest_release(proc)
        self.env["NVR_TEST_BLOCK_ID"] = block_id
        self.run_probe("archive_retained")
        descriptor = Path(self.env["NVR_TEST_MP4"] + ".json").read_bytes()
        self.assertEqual(store["objects"][prefix + "descriptor.json"][0], descriptor)
        observed = len(store["requests"])
        self.start_ingest_release()
        self.assertEqual(self.archive_request(block_id, document), (200, retained))
        self.assertEqual(len(store["requests"]), observed)

    def test_archive_failures_write_no_receipt_and_existing_objects_are_verified_not_replaced(self):
        proc, block_id = self.sealed_network_block()
        receipt_path = self.spool / block_id / "archive-receipt.json"
        store, port = self.object_store()
        document = self.archive_document(port)
        init_key = self.object_prefix(block_id) + "init.mp4"

        store["refuse_put"] = True
        status, body = self.archive_request(block_id, document)
        self.assertEqual((status, json.loads(body)), (502, {"error": "archive_failed", "stage": "put", "object": "init.mp4"}))
        self.assertEqual(store["objects"], {})
        self.assertFalse(receipt_path.exists())

        store["refuse_put"] = False
        store["corrupt_get"] = True
        status, body = self.archive_request(block_id, document)
        self.assertEqual((status, json.loads(body)),
                         (502, {"error": "archive_failed", "stage": "readback", "object": "init.mp4"}))
        self.assertEqual(list(store["objects"]), [init_key])
        self.assertFalse(receipt_path.exists())

        # The retry meets the stored object (412), verifies it and never replaces it.
        stored = store["objects"][init_key]
        store["corrupt_get"] = False
        status, body = self.archive_request(block_id, document)
        self.assertEqual(status, 200, body)
        self.assertEqual(body, receipt_path.read_bytes())
        self.assertEqual(store["objects"][init_key], stored)
        self.assertEqual(json.loads(body)["objects"][0]["etag"], stored[1])
        self.assertEqual(len([1 for method, key, _ in store["requests"] if (method, key) == ("PUT", init_key)]), 3)

        proc.send_signal(signal.SIGTERM)
        output = proc.communicate(timeout=15)[0]
        self.assertIn(b"NVR archive failed: stage=put object=init.mp4 outcome=status_403", output)
        self.assertIn(b"NVR archive failed: stage=readback object=init.mp4 outcome=digest_mismatch", output)
        self.assertNotIn(self.secret.encode(), output)

    def test_archive_refuses_invalid_unknown_unsealed_and_concurrent_requests(self):
        proc, block_id = self.sealed_network_block()
        block = self.spool / block_id
        store, port = self.object_store()
        document = self.archive_document(port)
        destination = document["destination"]
        invalid = [
            self.archive_document(port, storage_id="00000000-0000-4000-8000-000000000099"),
            self.archive_document(port, recovery_generation="00000000-0000-4000-8000-000000000098"),
            self.archive_document(port, extra=True),
            {key: value for key, value in document.items() if key != "credential"},
            self.archive_document(port, destination={**destination, "object_prefix": "/recordings/v1"}),
            self.archive_document(port, destination={**destination, "host": "objects"}),
            self.archive_document(port, credential={"access_key_id": "EXAMPLEARCHIVEKEY"}),
            b"not json", json.dumps(document, indent=1).encode(), canonical(document) + b" " * 8192,
        ]
        for body in invalid:
            with self.subTest(body=body if isinstance(body, bytes) else sorted(body)):
                self.assertEqual(self.archive_request(block_id, body), (400, b'{"error":"invalid_archive_request"}'))
        self.assertEqual(self.archive_request(block_id, document, content_type="application/json")[0], 400)
        self.assertEqual(self.archive_request(block_id, document, token="incorrect-token")[0], 401)
        self.assertEqual(self.archive_request("0" * 64, document), (404, b'{"error":"block_not_found"}'))

        # Removing the seal record leaves an open block, which is never archived.
        journal = (block / "journal").read_bytes()
        offset = 0
        while offset < len(journal):
            last = offset
            offset += 4 + int.from_bytes(journal[offset:offset + 4], "big") + 32
        (block / "journal").write_bytes(journal[:last])
        self.assertEqual(self.archive_request(block_id, document), (409, b'{"error":"block_not_sealed"}'))
        (block / "journal").write_bytes(journal[:-1] + bytes([journal[-1] ^ 1]))
        self.assertEqual(self.archive_request(block_id, document), (503, b'{"error":"archive_unavailable"}'))
        (block / "journal").unlink()
        self.assertEqual(self.archive_request(block_id, document), (404, b'{"error":"block_not_found"}'))
        (block / "journal").write_bytes(journal)
        self.assertEqual(store["requests"], [])
        self.assertFalse((block / "archive-receipt.json").exists())

        # A receipt file the NVR cannot trust is a local fault, retried as 503 and
        # left in place; a readable receipt for another request is a conflict.
        receipt = block / "archive-receipt.json"
        unrelated = canonical({"objects": [], "verified_at_ms": 1})
        receipt.write_bytes(unrelated)
        receipt.chmod(0o644)
        self.assertEqual(self.archive_request(block_id, document), (503, b'{"error":"archive_unavailable"}'))
        self.assertEqual(receipt.read_bytes(), unrelated)
        receipt.chmod(0o600)
        self.assertEqual(self.archive_request(block_id, document), (409, b'{"error":"archive_receipt_conflict"}'))
        self.assertEqual(receipt.read_bytes(), unrelated)
        self.assertEqual(store["requests"], [])
        receipt.unlink()

        # One archive runs per NVR; a second request while it is in flight is refused.
        store["hold"] = threading.Event()
        first = []
        worker = threading.Thread(target=lambda: first.append(self.archive_request(block_id, document)))
        worker.start()
        self.assertTrue(store["held"].wait(30))
        self.assertEqual(self.archive_request(block_id, document), (503, b'{"error":"archive_busy"}'))
        store["hold"].set()
        worker.join(90)
        self.assertEqual(first[0][0], 200, first)

        proc.send_signal(signal.SIGTERM)
        output = proc.communicate(timeout=15)[0]
        self.assertIn(b"NVR archive failed: stage=receipt outcome=invalid_archive_receipt", output)
        self.assertNotIn(self.secret.encode(), output)


def _shard_tests(tests):
    shard_status_file = os.environ.get("TEST_SHARD_STATUS_FILE")
    if shard_status_file:
        Path(shard_status_file).touch()
    total_shards = int(os.environ.get("TEST_TOTAL_SHARDS", "1"))
    shard_index = int(os.environ.get("TEST_SHARD_INDEX", "0"))
    if total_shards <= 1:
        return tests
    if not 0 <= shard_index < total_shards:
        raise ValueError(f"Invalid TEST_SHARD_INDEX={shard_index} for TEST_TOTAL_SHARDS={total_shards}")
    ordered = sorted(tests, key=lambda test: test.id())
    return [test for idx, test in enumerate(ordered) if idx % total_shards == shard_index]


def load_tests(loader, _tests, _pattern):
    # The archive suite opens a real Longshore client and runs on the
    # longshore-qualification executor pool (see BUILD.bazel); the default suite
    # does not need that executor.
    if os.environ.get("NVR_RELEASE_SUITE") == "archive":
        names = [name for name in loader.getTestCaseNames(NVRArchiveReleaseTest) if name in vars(NVRArchiveReleaseTest)]
        tests = [NVRArchiveReleaseTest(name) for name in names]
    else:
        tests = list(loader.loadTestsFromTestCase(NVRReleaseTest))
    return unittest.TestSuite(_shard_tests(tests))


if __name__ == "__main__":
    unittest.main()
