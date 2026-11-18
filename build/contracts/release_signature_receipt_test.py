"""Release verification of transparency-log receipts, with the pinned cosign and real crypto.

Everything is synthetic: a throwaway release key, a stand-in "log" key that signs a
SignedEntryTimestamp over a hand-built hashedrekord entry, and an in-process OCI registry
on localhost. Every other destination is routed to a dead proxy, so a verification that
tries an online transparency-log lookup fails instead of passing.

Owner: scripts/cosign_common.sh cosign_verify_legacy_signature (design.md, Decision 4).
"""

import base64
import hashlib
import http.server
import json
import os
import platform
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REPOSITORY = "example"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"


def pinned_cosign():
    machine = platform.machine().lower()
    repository = {"x86_64": "cosign_linux_amd64", "amd64": "cosign_linux_amd64",
                  "aarch64": "cosign_linux_arm64", "arm64": "cosign_linux_arm64"}[machine]
    for dirpath, _dirnames, filenames in os.walk(os.environ["TEST_SRCDIR"], followlinks=True):
        if repository in dirpath and "downloaded" in filenames:
            return Path(dirpath) / "downloaded"
    raise FileNotFoundError("declared cosign runfile is unavailable")


def sha256_hex(raw):
    return hashlib.sha256(raw).hexdigest()


class Registry(http.server.ThreadingHTTPServer):
    """Serves manifests by tag or digest and blobs by digest; nothing else."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), RegistryHandler)
        self.manifests = {}
        self.blobs = {}

    @property
    def host(self):
        return f"localhost:{self.server_address[1]}"

    def put_blob(self, raw):
        digest = "sha256:" + sha256_hex(raw)
        self.blobs[digest] = raw
        return {"digest": digest, "size": len(raw)}

    def put_manifest(self, raw, tag=None):
        digest = "sha256:" + sha256_hex(raw)
        self.manifests[digest] = raw
        if tag:
            self.manifests[tag] = raw
        return digest


class RegistryHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_HEAD(self):
        self.respond(head=True)

    def do_GET(self):
        self.respond(head=False)

    def respond(self, head):
        path = self.path.split("?", 1)[0]
        body, content_type = None, "application/octet-stream"
        if path in ("/v2", "/v2/"):
            body, content_type = b"{}", "application/json"
        else:
            prefix = f"/v2/{REPOSITORY}/"
            if path.startswith(prefix + "manifests/"):
                body, content_type = self.server.manifests.get(path[len(prefix + "manifests/"):]), OCI_MANIFEST
            elif path.startswith(prefix + "blobs/"):
                body = self.server.blobs.get(path[len(prefix + "blobs/"):])
        if body is None:
            raw = b'{"errors":[{"code":"MANIFEST_UNKNOWN","message":"unknown"}]}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            if not head:
                self.wfile.write(raw)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Content-Digest", "sha256:" + sha256_hex(body))
        self.end_headers()
        if not head:
            self.wfile.write(body)


class ReleaseReceiptVerificationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        cls.registry = Registry()
        threading.Thread(target=cls.registry.serve_forever, daemon=True).start()

        cls.bin = cls.root / "bin"
        cls.bin.mkdir()
        (cls.bin / "cosign").symlink_to(pinned_cosign())
        # Registry client stand-in for reading the classic `.sig` manifest; cosign is real.
        oras = cls.bin / "oras"
        oras.write_text(
            "#!/usr/bin/env python3\nimport sys, urllib.request\n"
            "assert sys.argv[1:3] == ['manifest', 'fetch'], sys.argv\n"
            "host, _, rest = sys.argv[3].partition('/')\n"
            "repository, _, tag = rest.rpartition(':')\n"
            "with urllib.request.urlopen(f'http://{host}/v2/{repository}/manifests/{tag}') as response:\n"
            "    sys.stdout.buffer.write(response.read())\n")
        oras.chmod(0o755)

        cls.release_key, cls.release_pub = cls.ec_key("release")
        cls.log_key, cls.log_pub = cls.ec_key("log")
        cls.other_log_key, cls.other_log_pub = cls.ec_key("other-log")
        cls.pre_cutover_log_key, cls.pre_cutover_log_pub = cls.ec_key("pre-cutover-log")
        cls.log_id = cls.receipt_tool("log-id", str(cls.log_pub)).strip()
        cls.other_log_id = cls.receipt_tool("log-id", str(cls.other_log_pub)).strip()
        cls.pre_cutover_log_id = cls.receipt_tool("log-id", str(cls.pre_cutover_log_pub)).strip()

        # The accepted key set holds only the stand-in log; rekor.pub names it as the
        # signing log, as docs/sigstore does for the public-good log.
        cls.sigstore = cls.root / "sigstore"
        (cls.sigstore / "rekor-keys").mkdir(parents=True)
        (cls.sigstore / "rekor.pub").write_bytes(cls.log_pub.read_bytes())
        (cls.sigstore / "rekor-keys" / f"{cls.log_id}.pub").write_bytes(cls.log_pub.read_bytes())
        # Stand-in for the public-good log that only reused pre-cutover receipts may name.
        (cls.sigstore / "pre-cutover-rekor-keys").mkdir()
        (cls.sigstore / "pre-cutover-rekor-keys" / f"{cls.pre_cutover_log_id}.pub").write_bytes(
            cls.pre_cutover_log_pub.read_bytes())

    @classmethod
    def tearDownClass(cls):
        cls.registry.shutdown()
        cls.directory.cleanup()

    @classmethod
    def ec_key(cls, name):
        private, public = cls.root / f"{name}.key", cls.root / f"{name}.pub"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-out", str(private)], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                       check=True, capture_output=True)
        return private, public

    @classmethod
    def receipt_tool(cls, *args, stdin=None):
        return subprocess.run(["python3", str(REPO / "scripts/cosign_receipt.py"), *args], check=True,
                              capture_output=True, text=True, input=stdin).stdout

    @staticmethod
    def sign(private, raw):
        return subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private)], input=raw,
                              check=True, capture_output=True).stdout

    def env(self, ledger):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("COSIGN_", "SIGSTORE_", "SERVICERADAR_"))}
        home = self.root / "home"
        home.mkdir(exist_ok=True)
        dead_proxy = "http://127.0.0.1:9"
        environment.update(
            PATH=str(self.bin) + os.pathsep + environment["PATH"], HOME=str(home),
            SERVICERADAR_SIGNING_LEDGER=str(ledger), SERVICERADAR_SIGSTORE_DIR=str(self.sigstore),
            HTTPS_PROXY=dead_proxy, HTTP_PROXY=dead_proxy, https_proxy=dead_proxy, http_proxy=dead_proxy,
            NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1",
            TUF_ROOT=str(home / "tuf"), SIGSTORE_CACHE_DIR=str(home / "sigstore"))
        return environment

    def publish(self, receipt=None, payload_override=None, through_signer_check=True):
        """Push a fresh image and its classic `.sig`; return the digest reference."""
        config = self.registry.put_blob(os.urandom(16).hex().encode())
        image = json.dumps({"schemaVersion": 2, "mediaType": OCI_MANIFEST,
                            "config": {"mediaType": "application/vnd.oci.image.config.v1+json", **config},
                            "layers": []}).encode()
        digest = self.registry.put_manifest(image)
        reference = f"{self.registry.host}/{REPOSITORY}@{digest}"
        payload = json.dumps({"critical": {"identity": {"docker-reference": f"{self.registry.host}/{REPOSITORY}"},
                                           "image": {"docker-manifest-digest": digest},
                                           "type": "cosign container image signature"},
                              "optional": None}).encode()
        signature = base64.b64encode(self.sign(self.release_key, payload)).decode()

        work = self.root / digest.replace(":", "-")
        work.mkdir()
        (work / "payload").write_bytes(payload)
        (work / "signature").write_text(signature)
        (work / "config").write_bytes(b'{"architecture":"","os":"","config":{}}')
        args = [str(work / "config"), str(work / "payload"), str(work / "signature")]
        if receipt is not None:
            # A different entry is a genuine one: the release key over another payload.
            logged_payload = payload_override or payload
            logged_signature = (base64.b64encode(self.sign(self.release_key, logged_payload)).decode()
                                if payload_override else signature)
            bundle = {"base64Signature": signature, "rekorBundle": receipt(logged_payload, logged_signature)}
            (work / "bundle.json").write_text(json.dumps(bundle))
            if through_signer_check:
                # The production annotation writer, checked against this run's signing log.
                annotation = self.receipt_tool("receipt", str(work / "bundle.json"), str(self.sigstore / "rekor.pub"))
            else:
                annotation = json.dumps(bundle["rekorBundle"], separators=(",", ":"))
            (work / "receipt").write_text(annotation)
            args.append(str(work / "receipt"))
        manifest = self.receipt_tool("manifest", *args).strip().encode()
        layer = json.loads(manifest)["layers"][0]
        self.registry.blobs[layer["digest"]] = payload
        self.registry.put_blob((work / "config").read_bytes())
        self.registry.put_manifest(manifest, tag=digest.replace(":", "-") + ".sig")
        return reference, digest

    def receipt(self, log_key=None, log_id=None):
        """A legacy RekorBundle whose SET is signed by the stand-in log over a hashedrekord body."""

        def build(payload, signature):
            body = json.dumps({"apiVersion": "0.0.1", "kind": "hashedrekord", "spec": {
                "data": {"hash": {"algorithm": "sha256", "value": sha256_hex(payload)}},
                "signature": {"content": signature,
                              "publicKey": {"content": base64.b64encode(self.release_pub.read_bytes()).decode()}}}},
                separators=(",", ":")).encode()
            entry = {"body": base64.b64encode(body).decode(), "integratedTime": 1767225600,
                     "logID": log_id or self.log_id, "logIndex": 4242}
            canonical = json.dumps(entry, sort_keys=True, separators=(",", ":")).encode()
            signed_entry_timestamp = base64.b64encode(self.sign(log_key or self.log_key, canonical)).decode()
            return {"SignedEntryTimestamp": signed_entry_timestamp,
                    "Payload": {"body": entry["body"], "integratedTime": entry["integratedTime"],
                                "logIndex": entry["logIndex"], "logID": entry["logID"]}}

        return build

    def ledger(self, records):
        path = self.root / f"ledger-{os.urandom(4).hex()}.jsonl"
        path.write_text("".join(json.dumps({"event": event, "digest": digest}) + "\n" for event, digest in records))
        return path

    def verify(self, reference, ledger):
        script = ('source "$1"; COSIGN_VERIFY_ARGS=(--key "$2"); cosign_verify_legacy_signature "$3"')
        return subprocess.run(["bash", "-c", script, "verify", str(REPO / "scripts/cosign_common.sh"),
                               str(self.release_pub), reference],
                              env=self.env(ledger), capture_output=True, text=True, timeout=120)

    def assert_verified(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_rejected(self, result, reason):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr)

    def test_created_signature_with_a_valid_receipt_verifies_offline(self):
        reference, digest = self.publish(receipt=self.receipt())
        result = self.verify(reference, self.ledger([("sign", digest), ("logged", digest)]))
        self.assert_verified(result)
        self.assertIn("verified offline", result.stderr)

    def test_created_signature_without_a_receipt_fails_without_key_only_fallback(self):
        reference, digest = self.publish()
        result = self.verify(reference, self.ledger([("sign", digest)]))
        self.assert_rejected(result, "signed in this run but its signature carries no transparency-log receipt")

    def test_created_and_then_reused_in_the_same_run_still_requires_the_receipt(self):
        reference, digest = self.publish()
        result = self.verify(reference, self.ledger([("sign", digest), ("reused", digest)]))
        self.assert_rejected(result, "carries no transparency-log receipt")

    def test_digest_without_a_signing_record_fails(self):
        reference, digest = self.publish(receipt=self.receipt())
        result = self.verify(reference, self.ledger([("sign", "sha256:" + "0" * 64)]))
        self.assert_rejected(result, "no signing-ledger record")

    def test_valid_set_for_a_different_entry_fails(self):
        # The log really signed this entry, but it names another payload's hash.
        reference, digest = self.publish(receipt=self.receipt(), payload_override=b"another payload")
        result = self.verify(reference, self.ledger([("sign", digest)]))
        self.assert_rejected(result, "signature in bundle does not match signature being verified")

    def test_receipt_from_a_log_outside_the_accepted_key_set_fails(self):
        # Annotated directly: the signer's own check refuses a receipt from another log.
        reference, digest = self.publish(receipt=self.receipt(log_key=self.other_log_key, log_id=self.other_log_id),
                                         through_signer_check=False)
        result = self.verify(reference, self.ledger([("reused", digest)]))
        self.assert_rejected(result, "which is not an accepted Rekor log")

    def test_reused_pre_cutover_receipt_verifies_against_the_pre_cutover_key(self):
        reference, digest = self.publish(
            receipt=self.receipt(log_key=self.pre_cutover_log_key, log_id=self.pre_cutover_log_id),
            through_signer_check=False)
        result = self.verify(reference, self.ledger([("reused", digest)]))
        self.assert_verified(result)
        self.assertIn("verified offline", result.stderr)

    def test_created_signature_with_a_pre_cutover_log_receipt_fails(self):
        reference, digest = self.publish(
            receipt=self.receipt(log_key=self.pre_cutover_log_key, log_id=self.pre_cutover_log_id),
            through_signer_check=False)
        result = self.verify(reference, self.ledger([("sign", digest)]))
        self.assert_rejected(result, "not an accepted Rekor log for a created signature")

    def test_set_not_signed_by_the_named_log_fails(self):
        reference, digest = self.publish(receipt=self.receipt(log_key=self.other_log_key))
        result = self.verify(reference, self.ledger([("sign", digest)]))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("error verifying bundle", result.stderr)

    def test_reused_pre_cutover_signature_without_a_receipt_verifies_with_the_release_key(self):
        reference, digest = self.publish()
        self.assert_verified(self.verify(reference, self.ledger([("reused", digest)])))

    def test_reused_signature_with_a_receipt_is_held_to_it(self):
        reference, digest = self.publish(receipt=self.receipt(), payload_override=b"another payload")
        result = self.verify(reference, self.ledger([("reused", digest)]))
        self.assert_rejected(result, "signature in bundle does not match signature being verified")


if __name__ == "__main__":
    unittest.main()
