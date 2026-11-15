"""Canonical legacy attachment migration: real crypto, synthetic registry responses."""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("legacy", ROOT / "scripts/reconcile-legacy-signature.py")
legacy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(legacy)
SUBJECT = "sha256:" + "a" * 64
REPOSITORY = "example"
TAG = SUBJECT.replace(":", "-") + ".sig"


def digest(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def encoded(value):
    return json.dumps(value, separators=(",", ":")).encode()


class Registry(legacy.Registry):
    def __init__(self):
        super().__init__("registry.example")
        self.objects = {}
        self.copies = []
        self.lookup_error = None
        self.accessories = set()

    def headers(self, repository):
        return {}

    def request(self, path, headers, absent=False):
        if self.lookup_error:
            raise self.lookup_error
        if "/referrers/" in path:
            return encoded({"manifests": [{"digest": value} for value in sorted(self.accessories)]}), {}
        if path not in self.objects:
            if absent:
                return None
            raise ValueError("unexpected missing registry object")
        raw = self.objects[path]
        return raw, {"Docker-Content-Digest": digest(raw)}

    def copy_to_build(self, repository, value, tag):
        self.copies.append((repository, value, tag))
        self.accessories.add(value)
        for path, raw in list(self.objects.items()):
            if path.startswith("/v2/serviceradar/" + repository + "/") and ("/manifests/sha256:" in path or "/blobs/" in path):
                self.objects[path.replace("/serviceradar/", "/serviceradar-builds/", 1)] = raw
        self.objects[f"/v2/serviceradar-builds/{repository}/manifests/{tag}"] = self.objects[f"/v2/serviceradar/{repository}/manifests/{value}"]


class LegacySignatureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        for name in ("trusted", "wrong"):
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(cls.root / name)], check=True, capture_output=True)
        cls.public = cls.root / "public.pem"
        subprocess.run(["openssl", "pkey", "-in", str(cls.root / "trusted"), "-pubout", "-out", str(cls.public)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.registry = Registry()

    def signed_layer(self, repository, identity=None, subject=SUBJECT, key="trusted",
                     payload_type="cosign container image signature", corrupt=None):
        payload = encoded({"critical": {"type": payload_type, "identity": {"docker-reference": identity or "registry.example/" + repository}, "image": {"docker-manifest-digest": subject}}, "optional": None})
        signature = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", str(self.root / key)], input=payload)
        if corrupt == "signature":
            signature = b"invalid detached signature"
        descriptor = {"digest": digest(payload), "size": len(payload), "mediaType": legacy.SIMPLE_SIGNING,
                      "annotations": {"dev.cosignproject.cosign/signature": base64.b64encode(signature).decode()}}
        if corrupt == "size":
            descriptor["size"] += 1
        elif corrupt == "digest":
            descriptor["digest"] = "sha256:" + "0" * 64
        elif corrupt == "media_type":
            descriptor["mediaType"] = "application/octet-stream"
        return descriptor, payload

    def artifact(self, project, identity=None, subject=SUBJECT, key="trusted", corrupt=None, layer_options=None):
        repository = project + "/" + REPOSITORY
        config = b'{"architecture":"","os":""}'
        options = layer_options if layer_options is not None else [{"identity": identity, "subject": subject, "key": key}]
        layers = []
        for option in options:
            descriptor, payload = self.signed_layer(repository, **option)
            layers.append(descriptor)
            self.registry.objects[f"/v2/{repository}/blobs/{descriptor['digest']}"] = b"corrupt" if corrupt == "payload" else payload
        manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"digest": digest(config), "size": len(config), "mediaType": "application/vnd.oci.image.config.v1+json"}, "layers": layers}
        raw = encoded(manifest)
        value = digest(raw)
        self.registry.objects[f"/v2/{repository}/manifests/{TAG}"] = raw
        self.registry.objects[f"/v2/{repository}/manifests/{value}"] = raw
        self.registry.objects[f"/v2/{repository}/blobs/{digest(config)}"] = b"corrupt" if corrupt == "config" else config
        if corrupt == "manifest":
            self.registry.objects[f"/v2/{repository}/manifests/{value}"] = raw + b" "
        if project == "serviceradar-builds":
            self.registry.accessories.add(value)
        return value

    def reconcile(self):
        return legacy.reconcile("registry.example/serviceradar-builds/example@" + SUBJECT, self.public, self.registry)

    def test_canonical_reused_before_first_build_signature_then_idempotent(self):
        canonical = self.artifact("serviceradar")
        protected = dict((k, v) for k, v in self.registry.objects.items() if k.startswith("/v2/serviceradar/"))
        self.assertEqual(self.reconcile(), "reused")
        self.assertEqual(self.registry.copies, [(REPOSITORY, canonical, TAG)])
        self.assertEqual(self.registry.manifest("serviceradar-builds/example", TAG)[0], canonical)
        self.assertEqual(self.reconcile(), "reused")
        self.assertEqual(len(self.registry.copies), 1)
        self.assertEqual(protected, {k: v for k, v in self.registry.objects.items() if k.startswith("/v2/serviceradar/")})

    def test_multiple_signatures_reused_without_changing_manifest(self):
        for count in (3, 32):
            with self.subTest(count=count):
                self.registry = Registry()
                canonical = self.artifact("serviceradar", layer_options=[{} for _ in range(count)])
                raw = self.registry.objects[f"/v2/serviceradar/example/manifests/{canonical}"]
                layers = json.loads(raw)["layers"]
                self.assertEqual(len({layer["digest"] for layer in layers}), 1)
                self.assertEqual(len({layer["annotations"]["dev.cosignproject.cosign/signature"] for layer in layers}), count)
                self.assertEqual(self.reconcile(), "reused")
                self.assertEqual(self.registry.copies, [(REPOSITORY, canonical, TAG)])
                self.assertEqual(self.registry.objects[f"/v2/serviceradar-builds/example/manifests/{TAG}"], raw)
                self.assertEqual(self.registry.objects[f"/v2/serviceradar/example/manifests/{TAG}"], raw)

    def test_invalid_later_signature_refuses_entire_artifact_before_copy(self):
        cases = [
            ({"key": "wrong"}, "configured key"),
            ({"corrupt": "signature"}, "configured key"),
            ({"subject": "sha256:" + "b" * 64}, "subject"),
            ({"payload_type": "untrusted payload type"}, "type"),
            ({"identity": "registry.example/serviceradar/other"}, "repository"),
            ({"corrupt": "size"}, "hash or size"),
            ({"corrupt": "digest"}, "hash or size"),
            ({"corrupt": "media_type"}, "unsupported legacy signature payload"),
        ]
        for position in (1, 2):
            for option, reason in cases:
                with self.subTest(position=position, option=option):
                    self.registry = Registry()
                    layers = [{}, {}, {}]
                    layers[position] = option
                    self.artifact("serviceradar", layer_options=layers)
                    with self.assertRaisesRegex(ValueError, reason):
                        self.reconcile()
                    self.assertEqual(self.registry.copies, [])

    def test_empty_or_oversized_signature_list_refuses_before_copy(self):
        for count in (0, 33):
            with self.subTest(count=count):
                self.registry = Registry()
                self.artifact("serviceradar", layer_options=[{} for _ in range(count)])
                with self.assertRaisesRegex(ValueError, "between 1 and 32"):
                    self.reconcile()
                self.assertEqual(self.registry.copies, [])

    def test_existing_different_build_signature_requires_migration_without_retag(self):
        canonical = self.artifact("serviceradar")
        previous = self.artifact("serviceradar-builds")
        with self.assertRaisesRegex(legacy.MigrationRequired, "differs"):
            self.reconcile()
        self.assertEqual(self.registry.copies, [])
        self.assertEqual(self.registry.manifest("serviceradar-builds/example", TAG)[0], previous)
        self.assertEqual(self.registry.manifest("serviceradar/example", TAG)[0], canonical)

    def test_stale_accessory_after_retag_requires_explicit_repair(self):
        canonical = self.artifact("serviceradar")
        previous = self.artifact("serviceradar-builds")
        self.registry.copy_to_build(REPOSITORY, canonical, TAG)
        self.registry.copies.clear()
        with self.assertRaisesRegex(legacy.MigrationRequired, previous):
            self.reconcile()
        self.assertEqual(self.registry.copies, [])

    def test_canonical_may_have_been_signed_in_disposable_project(self):
        canonical = self.artifact("serviceradar", identity="registry.example/serviceradar-builds/example")
        self.assertEqual(self.reconcile(), "reused")
        self.assertEqual(self.registry.copies[0][1], canonical)

    def test_invalid_canonical_refuses_before_any_copy(self):
        cases = [{"key": "wrong"}, {"subject": "sha256:" + "b" * 64}, {"identity": "registry.example/serviceradar/other"}, {"identity": "other.example/serviceradar/example"}, {"identity": "registry.example/untrusted/example"}] + [{"corrupt": kind} for kind in ("payload", "config", "manifest")]
        for case in cases:
            with self.subTest(case=case):
                self.registry = Registry()
                self.artifact("serviceradar", **case)
                with self.assertRaises(ValueError):
                    self.reconcile()
                self.assertEqual(self.registry.copies, [])

    def test_absent_canonical_and_source_permit_normal_new_signing(self):
        self.assertEqual(self.reconcile(), "absent")
        self.assertEqual(self.registry.copies, [])

    def test_existing_source_signature_is_verified_without_canonical(self):
        self.artifact("serviceradar-builds")
        self.assertEqual(self.reconcile(), "reused")
        self.assertEqual(self.registry.copies, [])
        self.artifact("serviceradar-builds", key="wrong")
        with self.assertRaises(ValueError):
            self.reconcile()

    def test_authentication_failure_never_means_absent(self):
        self.registry.lookup_error = ValueError("HTTP 401")
        with self.assertRaisesRegex(ValueError, "401"):
            self.reconcile()
        self.assertEqual(self.registry.copies, [])

    def test_only_explicit_registry_missing_response_means_absent(self):
        registry = legacy.Registry("registry.example")
        def errors(*codes):
            return encoded({"errors": [{"code": code} for code in codes]})
        oversized = errors("NOT_FOUND").ljust(1_048_576, b" ") + b"invalid trailing data"
        cases = [(404, errors(code), True, True) for code in ("MANIFEST_UNKNOWN", "NAME_UNKNOWN", "NOT_FOUND")]
        cases += [
            (404, errors("DENIED"), True, False),
            (404, errors("NOT_FOUND", "UNAUTHORIZED"), True, False),
            (404, errors("NOT_FOUND", "UNKNOWN"), True, False),
            (404, errors(), True, False),
            (404, oversized, True, False),
            (404, b'{}', True, False),
            (404, b'[]', True, False),
            (404, b'{"errors":null}', True, False),
            (404, b'{"errors":["NOT_FOUND"]}', True, False),
            (404, b'{"errors":{"code":"NOT_FOUND"}}', True, False),
            (404, b'{invalid JSON', True, False),
            (404, b'{"errors":[{"code":"DENIED","code":"MANIFEST_UNKNOWN"}]}', True, False),
            (404, b'{"errors":[{"code":"DENIED"}],"errors":[{"code":"NAME_UNKNOWN"}]}', True, False),
            (401, errors("NOT_FOUND"), True, False),
            (403, errors("NOT_FOUND"), True, False),
            (500, errors("MANIFEST_UNKNOWN"), True, False),
            (404, errors("NOT_FOUND"), False, False),
        ]
        for status, body, optional, absent in cases:
            with self.subTest(status=status, body=body[:128], body_size=len(body), optional=optional):
                error = urllib.error.HTTPError("https://registry.example", status, "synthetic", {}, io.BytesIO(body))
                with patch.object(registry.http, "open", side_effect=error):
                    if absent:
                        self.assertIsNone(registry.request("/v2/example/manifests/tag", {}, absent=optional))
                    else:
                        with self.assertRaises(ValueError):
                            registry.request("/v2/example/manifests/tag", {}, absent=optional)

    def test_paginated_referrers_refuse_before_copy(self):
        self.artifact("serviceradar")
        request = self.registry.request
        def paginated(path, headers, absent=False):
            raw, response_headers = request(path, headers, absent)
            if "/referrers/" in path:
                response_headers = {"Link": '</v2/example/referrers/digest?page=2>; rel="next"'}
            return raw, response_headers
        # Keep an existing matching source tag so every non-referrer lookup exists.
        canonical = self.registry.manifest("serviceradar/example", TAG)[0]
        self.registry.copy_to_build(REPOSITORY, canonical, TAG)
        self.registry.copies.clear()
        self.registry.request = paginated
        with self.assertRaisesRegex(ValueError, "paginated"):
            self.reconcile()
        self.assertEqual(self.registry.copies, [])

    def test_duplicate_claims_are_ambiguous(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            legacy.strict_json(b'{"critical":{},"critical":{}}')

    def test_protected_input_cannot_write(self):
        with self.assertRaisesRegex(ValueError, "only writes"):
            legacy.reconcile("registry.example/serviceradar/example@" + SUBJECT, self.public, self.registry)
        self.assertEqual(self.registry.copies, [])


class SignerIntegrationTest(unittest.TestCase):
    def test_all_signers_propagate_migration_refusal_and_preserve_tlog_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("cosign_common.sh", "oci_registry.sh", "wasm-plugin-publish-context.sh",
                         "sign-oci-publish.sh", "sign-native-addon-publish.sh", "sign-wasm-plugin-publish.sh"):
                shutil.copy2(ROOT / "scripts" / name, scripts / name)
            # This caller test replaces only the shared reconciliation boundary;
            # the owning tests above exercise actual signature/hash verification.
            (scripts / "reconcile-legacy-signature.py").write_text(
                "import os,sys\n"
                "open(os.environ['CALLS'],'a').write('reconcile '+sys.argv[1]+'\\n')\n"
                "print('LEGACY_SIGNATURE_MIGRATION_REQUIRED: synthetic existing conflict',file=sys.stderr)\n"
                "raise SystemExit(2)\n")
            tool = root / "tool/k8s/harbor/promote-artifacts.py"
            tool.parent.mkdir(parents=True)
            tool.write_text("pass\n")
            inventory = root / "docker/images/image_inventory.bzl"
            inventory.parent.mkdir(parents=True)
            inventory.write_text('PUBLISHABLE_IMAGES = [{"repository":"registry.example/serviceradar/example","image":"example"}]\n\n')
            metadata = root / "metadata"
            metadata.mkdir()
            (metadata / "example.metadata.json").write_text('{"repository_name":"example"}')
            binaries = root / "bin"
            binaries.mkdir()
            def fake(name, body):
                path = binaries / name
                path.write_text("#!" + sys.executable + "\nimport os,sys,json\n" + body)
                path.chmod(0o755)
            fake("git", "print('a'*40)\n")
            fake("bazel", "pass\n")
            fake("oras", "print(json.dumps({'digest': 'sha256:'+'a'*64}))\n")
            fake("jq", "d=json.load(sys.stdin); print(d.get('digest',d.get('token','')))\n")
            # Old existence-only signers see the conflicting build legacy tag and
            # incorrectly succeed; the fixed caller must invoke the refusing owner.
            fake("curl", "print('200' if '-I' in sys.argv else '{\"token\":\"synthetic\"}')\n")
            fake("cosign", "command=sys.argv[1]\n"
                 "if command=='public-key': print('synthetic caller-test public key')\n"
                 "elif command=='triangulate': print(sys.argv[-1].replace('@sha256:',':sha256-')+'.sig')\n"
                 "elif command=='sign': open(os.environ['CALLS'],'a').write('modern '+str('--tlog-upload=true' in sys.argv)+'\\n')\n")
            calls = root / "calls"
            env = os.environ | {"PATH": str(binaries) + os.pathsep + os.environ["PATH"], "CALLS": str(calls),
                "OCI_REGISTRY": "registry.example", "OCI_PROJECT": "serviceradar-builds", "OCI_USERNAME": "synthetic", "OCI_TOKEN": "synthetic",
                "HARBOR_LIFECYCLE_DIR": str(root), "COSIGN_KEY_REF": "env://SYNTHETIC_KEY", "COSIGN_TLOG_UPLOAD": "true",
                "SERVICERADAR_SIGN_REGISTRY_TAG": "sha-synthetic", "SERVICERADAR_REPO_ROOT": str(root),
                "BAZEL_BIN_DIR": str(root), "METADATA_DIR": str(metadata), "WASM_PLUGIN_METADATA_DIR": str(metadata)}
            for name in ("sign-oci-publish.sh", "sign-native-addon-publish.sh", "sign-wasm-plugin-publish.sh"):
                with self.subTest(signer=name):
                    calls.unlink(missing_ok=True)
                    result = subprocess.run(["bash", str(scripts / name), "sha-synthetic"], env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("LEGACY_SIGNATURE_MIGRATION_REQUIRED", result.stderr)
                    observed = calls.read_text().splitlines()
                    self.assertIn("modern True", observed)
                    self.assertIn("reconcile registry.example/serviceradar-builds/example@" + SUBJECT, observed)


class KeySelectionTest(unittest.TestCase):
    def test_current_key_precedence_export_failure_and_snapshot_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            snapshot.mkdir()
            shutil.copy2(ROOT / "scripts/cosign_common.sh", snapshot / "cosign_common.sh")
            (snapshot / "reconcile-legacy-signature.py").write_text(
                "import os,pathlib,sys\n"
                "assert pathlib.Path(sys.argv[2]).read_text().strip()==os.environ['EXPECTED_KEY']\n"
                "pathlib.Path(os.environ['CALLED']).touch()\nprint('reused')\n")
            cosign = root / "cosign"
            cosign.write_text("#!" + sys.executable + "\nimport os,sys\n"
                              "if os.environ.get('EXPORT_FAIL'): raise SystemExit(1)\n"
                              "assert sys.argv[1:3]==['public-key','--key']\nprint('exported:'+sys.argv[3])\n")
            cosign.chmod(0o755)
            trust = root / "checkout/docs/cosign.pub"
            trust.parent.mkdir(parents=True)
            trust.write_text("checkout trust")
            temporary = root / "temporary"
            temporary.mkdir()
            called = root / "called"
            base = {k: v for k, v in os.environ.items() if not k.startswith(('COSIGN_', 'SIGSTORE_'))}
            base.update(PATH=str(root) + os.pathsep + os.environ['PATH'], TMPDIR=str(temporary),
                        SERVICERADAR_REPO_ROOT=str(root / "checkout"), CALLED=str(called))
            cases = [
                ({"COSIGN_KEY_REF": "hashivault://synthetic", "COSIGN_KEYLESS": "true"}, "exported:hashivault://synthetic", True),
                ({"COSIGN_KEY_FILE": str(root / "private"), "COSIGN_KEYLESS": "true"}, "exported:" + str(root / "private"), True),
                ({"COSIGN_PRIVATE_KEY": "synthetic", "COSIGN_KEYLESS": "true"}, "exported:env://COSIGN_PRIVATE_KEY", True),
                ({"COSIGN_PUBLIC_KEY": "inline trust"}, "inline trust", True),
                ({}, "checkout trust", True),
                ({"COSIGN_KEY_REF": "hashivault://synthetic", "EXPORT_FAIL": "1", "COSIGN_PUBLIC_KEY_FILE": str(trust)}, "checkout trust", False),
                ({"COSIGN_KEYLESS": "true"}, "checkout trust", False),
            ]
            for overrides, expected, succeeds in cases:
                with self.subTest(overrides=sorted(overrides)):
                    called.unlink(missing_ok=True)
                    result = subprocess.run(["bash", "-c", 'source "$1"; cosign_reconcile_legacy_signature "$2"',
                        "probe", str(snapshot / "cosign_common.sh"), "registry.example/serviceradar-builds/example@" + SUBJECT],
                        env=base | overrides | {"EXPECTED_KEY": expected}, text=True, capture_output=True)
                    self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                    self.assertEqual(called.exists(), succeeds)
                    self.assertEqual(list(temporary.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
