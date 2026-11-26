"""Mode A hermetic contract, wire-vector, Pack v2, USTAR, hygiene, and driver tests."""

from __future__ import annotations

import base64
import copy
import gzip
import hashlib
import json
import os
import socket
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc
from integration_tests.vantage_ml.drivers import (
    cli_driver,
    cnpg_driver,
    env_probe,
    http_ws_driver,
    media_gen,
    nats_driver,
    sdk_driver,
)


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _apply_dotted_patch(obj: dict, patch: dict) -> dict:
    cloned = copy.deepcopy(obj)
    for dotted_key, value in patch.items():
        parts = dotted_key.split(".")
        cur = cloned
        for part in parts[:-1]:
            cur = cur[part]
        cur[parts[-1]] = value
    return cloned


def _build_valid_pack_v2_tree(
    *,
    renderer_bytes: bytes | None = None,
    trust: str = "trusted",
    extra_manifest_fields: dict | None = None,
) -> dict[str, bytes]:
    renderer = renderer_bytes if renderer_bytes is not None else b"export function mount() { return true; }\n"
    renderer_sha = _sha256_hex(renderer)
    dash_manifest = {
        "schema_version": 1,
        "id": "io.serviceradar.alpr-console",
        "name": "ALPR Synthetic Console",
        "version": "1.0.0",
        "renderer": {
            "kind": "browser_module",
            "interface_version": "dashboard-browser-module-v1",
            "artifact": "renderer.js",
            "sha256": renderer_sha,
            "trust": trust,
        },
        "data_frames": [
            {
                "id": "plate_reads",
                "query": "in:camera_observations limit:50",
                "encoding": "json_rows",
            }
        ],
        "capabilities": ["srql.execute", "events.subscribe"],
        "settings_schema": {},
    }
    pipeline_json = {
        "id": "io.serviceradar.vantage-alpr.vehicle-plate",
        "slug": "alpr-vehicle-plate",
        "capability": "vantage.alpr.v1",
    }
    schema_json = {
        "id": "alpr_plate_read",
        "version": "1.0.0",
        "required": ["plate_text"],
    }
    display_json = {
        "id": "alpr_plate_read",
        "title": "Plate Read",
    }
    files_bytes: dict[str, bytes] = {
        "README.md": b"# Synthetic ALPR Pack\n\nGate West 01 (SR-0100, TEST-742).\n",
        "vantage_pipelines/alpr-vehicle-plate.json": json.dumps(pipeline_json).encode("utf-8"),
        "signal_schemas/alpr_plate_read.schema.json": json.dumps(schema_json).encode("utf-8"),
        "signal_schemas/alpr_plate_read.display.json": json.dumps(display_json).encode("utf-8"),
        "dashboard_packages/alpr-console/manifest.json": json.dumps(dash_manifest).encode("utf-8"),
        "dashboard_packages/alpr-console/renderer.js": renderer,
    }
    manifest = {
        "pack_format_version": 2,
        "id": "io.serviceradar.vantage-alpr",
        "slug": "vantage-alpr",
        "name": "Vantage ALPR Synthetic Pack",
        "version": "1.0.0",
        "license": "Apache-2.0",
        "resources": {
            "checks": [],
            "rules": [],
            "dashboards": [],
            "vantage_pipelines": [
                {
                    "id": "io.serviceradar.vantage-alpr.vehicle-plate",
                    "slug": "alpr-vehicle-plate",
                    "file": "vantage_pipelines/alpr-vehicle-plate.json",
                }
            ],
            "signal_schemas": [
                {
                    "id": "alpr_plate_read",
                    "version": "1.0.0",
                    "file": "signal_schemas/alpr_plate_read.schema.json",
                    "display_file": "signal_schemas/alpr_plate_read.display.json",
                }
            ],
            "dashboard_packages": [
                {
                    "slug": "alpr-console",
                    "dir": "dashboard_packages/alpr-console",
                    "manifest_file": "dashboard_packages/alpr-console/manifest.json",
                    "renderer_file": "dashboard_packages/alpr-console/renderer.js",
                }
            ],
        },
        "worker_dependencies": [{"capability": "vantage.alpr.v1", "optional": True}],
        "files": {path: _sha256_hex(content) for path, content in sorted(files_bytes.items())},
    }
    if extra_manifest_fields:
        manifest.update(extra_manifest_fields)
    files_bytes["manifest.json"] = json.dumps(manifest, indent=2).encode("utf-8") + b"\n"
    return files_bytes


def _build_valid_pack_v1_tree() -> dict[str, bytes]:
    check_bytes = json.dumps({"slug": "synthetic-check", "interval_seconds": 60}).encode("utf-8")
    files_bytes = {
        "README.md": b"# Synthetic v1 Pack\n",
        "checks/synthetic-check.json": check_bytes,
    }
    manifest = {
        "pack_format_version": 1,
        "id": "io.serviceradar.synthetic-v1",
        "slug": "synthetic-v1",
        "name": "Synthetic V1 Pack",
        "version": "1.0.0",
        "resources": {
            "checks": [{"file": "checks/synthetic-check.json", "slug": "synthetic-check"}],
            "rules": [],
            "dashboards": [],
        },
        "files": {path: _sha256_hex(content) for path, content in sorted(files_bytes.items())},
    }
    files_bytes["manifest.json"] = json.dumps(manifest).encode("utf-8")
    return files_bytes


class WireVectorContractsTest(unittest.TestCase):
    """Verify all canonical JSON wire vectors and size/field boundaries."""

    def setUp(self) -> None:
        self.vectors_dir = (
            vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures" / "wire_vectors"
        )

    def _load_vector(self, filename: str) -> dict:
        path = self.vectors_dir / filename
        self.assertTrue(path.is_file(), f"missing wire vector {path}")
        return json.loads(path.read_text(encoding="utf-8"))

    def test_repo_root_resolves_wire_vectors(self) -> None:
        self.assertTrue((self.vectors_dir / "vantage_job_v1.json").is_file())

    def test_vantage_job_v1_vectors_and_4096_boundary(self) -> None:
        vec = self._load_vector("vantage_job_v1.json")
        vc.validate_job_envelope(vec["positive"])
        for case in vec["negative"]:
            with self.subTest(case=case["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_job_envelope(case["payload"])
                self.assertIn(case["expected_error"], str(ctx.exception))

        # Exact 4096B boundary vs 4097B rejection
        base = copy.deepcopy(vec["positive"])
        base["vlm_config"]["prompt"] = "x"
        base_len = len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
        pad_exact = 4096 - base_len + 1
        base["vlm_config"]["prompt"] = "x" * pad_exact
        self.assertEqual(
            len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8")),
            vc.MAX_JOB_ENVELOPE_BYTES,
        )
        vc.validate_job_envelope(base)

        base["vlm_config"]["prompt"] = "x" * (pad_exact + 1)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_job_envelope(base)

    def test_vantage_result_v1_vectors_and_960kib_boundary(self) -> None:
        vec = self._load_vector("vantage_result_v1.json")
        vc.validate_result_envelope(vec["positive"])
        vc.validate_result_envelope(vec["positive_live"])
        for case in vec["negative"]:
            with self.subTest(case=case["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_result_envelope(case["payload"])
                self.assertIn(case["expected_error"], str(ctx.exception))

        # 960 KiB envelope boundary
        oversized = copy.deepcopy(vec["positive_live"])
        oversized["observations"][0]["search_text"] = "a" * (vc.MAX_RESULT_ENVELOPE_BYTES + 1)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(oversized)

    def test_vantage_heartbeat_v1_vectors(self) -> None:
        vec = self._load_vector("vantage_heartbeat_v1.json")
        vc.validate_heartbeat(vec["positive"])
        unhealthy = copy.deepcopy(vec["positive"])
        unhealthy["health"] = "unhealthy"
        vc.validate_heartbeat(unhealthy)

        bad_health = copy.deepcopy(vec["positive"])
        bad_health["health"] = "unknown"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_heartbeat(bad_health)

        for case in vec["negative"]:
            with self.subTest(case=case["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_heartbeat(case["payload"])
                self.assertIn(case["expected_error"], str(ctx.exception))

    def test_vantage_frame_v1_vectors(self) -> None:
        vec = self._load_vector("vantage_frame_v1.json")
        vc.validate_live_frame(vec["positive"])
        vc.validate_live_frame(vec["positive_payload_format"])

        annex_b = copy.deepcopy(vec["positive_payload_format"])
        annex_b["payload_format"] = "annex_b_idr"
        annex_b["payload_b64"] = base64.b64encode(b"\x00\x00\x00\x01\x65\x88\x84").decode("ascii")
        vc.validate_live_frame(annex_b)

        rgb8 = copy.deepcopy(vec["positive_payload_format"])
        rgb8["payload_format"] = "rgb8"
        rgb8["payload_b64"] = base64.b64encode(b"\x10\x20\x30\x40\x50\x60").decode("ascii")
        vc.validate_live_frame(rgb8)

        missing_b64 = copy.deepcopy(vec["positive_payload_format"])
        del missing_b64["payload_b64"]
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(missing_b64)

        bad_rgb = copy.deepcopy(rgb8)
        bad_rgb["payload_b64"] = base64.b64encode(b"\x10\x20").decode("ascii")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(bad_rgb)

        for case in vec["negative"]:
            with self.subTest(case=case["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_live_frame(case["payload"])
                self.assertIn(case["expected_error"], str(ctx.exception))

    def test_read_grant_response_vectors_and_credential_redaction(self) -> None:
        vec = self._load_vector("read_grant_response.json")
        vc.validate_read_grant_response(vec["positive_archive"])
        vc.validate_read_grant_response(vec["positive_local"])

        for case in vec["negative"]:
            with self.subTest(case=case["name"]):
                mutated = _apply_dotted_patch(vec[case["mutate_from"]], case["patch"])
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_read_grant_response(mutated)
                self.assertIn(case["expected_error"], str(ctx.exception))

        # Secret-bearing credential field leak must fail closed
        leaked = copy.deepcopy(vec["positive_archive"])
        leaked["credential"]["secret_access_key"] = "synthetic-leaked-key"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_read_grant_response(leaked)

    def test_signal_schema_vectors(self) -> None:
        alpr = self._load_vector("alpr_plate_read_schema.json")
        for pos in alpr["positive"]:
            vc.validate_alpr_attributes(pos)
        for neg in alpr["negative"]:
            with self.subTest(case=neg["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_alpr_attributes(neg["attributes"])
                self.assertIn(neg["expected_error"], str(ctx.exception))

        guidance = self._load_vector("bay_guidance_schema.json")
        for pos in guidance["positive"]:
            vc.validate_bay_guidance_attributes(pos)
        for neg in guidance["negative"]:
            with self.subTest(case=neg["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_bay_guidance_attributes(neg["attributes"])
                self.assertIn(neg["expected_error"], str(ctx.exception))


class UstarAndPackV2ContractsTest(unittest.TestCase):
    """Verify POSIX.1-1988 USTAR determinism and Solution Pack v1/v2 validation."""

    def test_ustar_determinism_layout_and_long_path_split(self) -> None:
        long_path = (
            "dashboard_packages/alpr-console/assets/"
            + "nested_segment_" * 5
            + "module_entry.js"
        )
        self.assertGreater(len(long_path.encode("utf-8")), 100)
        self.assertLessEqual(len(long_path.encode("utf-8")), vc.MAX_USTAR_PATH_BYTES)

        tree_a = {
            long_path: b"console.log('ok');",
            "manifest.json": b'{"ok":true}\n',
            "README.md": b"# Hi\n",
        }
        tree_b = {k: tree_a[k] for k in reversed(list(tree_a.keys()))}

        tar_a = vc.build_deterministic_ustar(tree_a)
        tar_b = vc.build_deterministic_ustar(tree_b)
        self.assertEqual(tar_a, tar_b)
        self.assertEqual(len(tar_a) % 512, 0)
        self.assertEqual(tar_a[-1024:], b"\x00" * 1024)

        # Verify first sorted header (`README.md`) POSIX.1-1988 fields
        hdr = tar_a[:512]
        self.assertTrue(hdr[0:9] == b"README.md")
        self.assertEqual(hdr[100:108], b"0000644\x00")
        self.assertEqual(hdr[108:116], b"0000000\x00")
        self.assertEqual(hdr[116:124], b"0000000\x00")
        self.assertEqual(hdr[136:148], b"00000000000\x00")
        self.assertEqual(hdr[156:157], b"0")
        self.assertEqual(hdr[257:263], b"ustar\x00")
        self.assertEqual(hdr[263:265], b"00")

        # Verify deterministic gzip header (mtime=0, OS=0xFF)
        gz_a = vc.build_deterministic_targz(tree_a)
        gz_b = vc.build_deterministic_targz(tree_b)
        self.assertEqual(gz_a, gz_b)
        self.assertEqual(gz_a[4:8], b"\x00\x00\x00\x00")
        self.assertEqual(gz_a[9], 0xFF)
        self.assertEqual(gzip.decompress(gz_a), tar_a)

    def test_ustar_rejects_traversal_and_240_byte_overflow(self) -> None:
        bad_paths = [
            "../escape.json",
            "checks/../secret.json",
            "/etc/passwd",
            "checks\\win.json",
            "checks/null\x00byte.json",
            "a/" + "b" * 239,  # 241 bytes > 240
        ]
        for bad in bad_paths:
            with self.subTest(path=bad):
                with self.assertRaises(vc.ContractValidationError):
                    vc.build_deterministic_ustar({bad: b"x"})

    def test_pack_v1_and_v2_validation_and_renderer_bounds(self) -> None:
        v1 = _build_valid_pack_v1_tree()
        res_v1 = vc.validate_pack_v2_tree(v1, compressed_bytes=vc.PACK_V1_LIMITS[0])
        self.assertEqual(res_v1["pack_format_version"], 1)
        self.assertEqual(res_v1["limits"], vc.PACK_V1_LIMITS)

        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(v1, compressed_bytes=vc.PACK_V1_LIMITS[0] + 1)

        v2 = _build_valid_pack_v2_tree()
        res_v2 = vc.validate_pack_v2_tree(v2, compressed_bytes=vc.PACK_V2_LIMITS[0])
        self.assertEqual(res_v2["pack_format_version"], 2)
        self.assertEqual(res_v2["limits"], vc.PACK_V2_LIMITS)
        self.assertTrue(res_v2["has_dashboard_packages"])

        # Compressed size > 32 MiB rejected for Pack v2
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(v2, compressed_bytes=vc.PACK_V2_LIMITS[0] + 1)

        # Renderer exact 8 MiB boundary vs 8 MiB + 1 rejection
        exact_8m = _build_valid_pack_v2_tree(renderer_bytes=b"x" * vc.MAX_RENDERER_BYTES)
        vc.validate_pack_v2_tree(exact_8m)

        over_8m = _build_valid_pack_v2_tree(renderer_bytes=b"x" * (vc.MAX_RENDERER_BYTES + 1))
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(over_8m)

        # trust != "trusted" rejected
        untrusted = _build_valid_pack_v2_tree(trust="untrusted")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(untrusted)

        # manifest.json forbidden inside manifest.files
        bad_files = copy.deepcopy(v2)
        manifest_obj = json.loads(bad_files["manifest.json"].decode("utf-8"))
        manifest_obj["files"]["manifest.json"] = "0" * 64
        bad_files["manifest.json"] = json.dumps(manifest_obj).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(bad_files)

        # SHA-256 mismatch between dashboard manifest and renderer.js rejected
        tampered = copy.deepcopy(v2)
        tampered["dashboard_packages/alpr-console/renderer.js"] = b"console.log('tampered');\n"
        # Even if root manifest.files is updated, dashboard manifest sha256 disagrees
        tampered_manifest = json.loads(tampered["manifest.json"].decode("utf-8"))
        tampered_manifest["files"]["dashboard_packages/alpr-console/renderer.js"] = _sha256_hex(
            tampered["dashboard_packages/alpr-console/renderer.js"]
        )
        tampered["manifest.json"] = json.dumps(tampered_manifest).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(tampered)

    def test_pack_v2_rejects_unregistered_and_unconfined_dashboard_packages(self) -> None:
        # 1. Unregistered dashboard_packages/<slug>/... omitted from resources.dashboard_packages
        rogue = _build_valid_pack_v2_tree()
        rogue_manifest = json.loads(rogue["manifest.json"].decode("utf-8"))
        rogue_manifest["resources"]["dashboard_packages"] = []
        rogue["manifest.json"] = json.dumps(rogue_manifest).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(rogue)
        self.assertIn("unregistered dashboard_packages", str(ctx.exception))

        # 2. Stray file directly under dashboard_packages/ without <slug>/ directory
        stray = _build_valid_pack_v2_tree()
        stray["dashboard_packages/stray.txt"] = b"stray"
        stray_manifest = json.loads(stray["manifest.json"].decode("utf-8"))
        stray_manifest["files"]["dashboard_packages/stray.txt"] = _sha256_hex(b"stray")
        stray["manifest.json"] = json.dumps(stray_manifest).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(stray)
        self.assertIn("unregistered dashboard_packages", str(ctx.exception))

        # 3. Unconfined renderer_file pointing outside dashboard_packages/<slug>/
        evil_renderer = _build_valid_pack_v2_tree()
        evil_renderer["assets/evil.js"] = b"export function evil() {}\n"
        evil_manifest = json.loads(evil_renderer["manifest.json"].decode("utf-8"))
        evil_manifest["files"]["assets/evil.js"] = _sha256_hex(evil_renderer["assets/evil.js"])
        evil_manifest["resources"]["dashboard_packages"][0]["renderer_file"] = "assets/evil.js"
        evil_renderer["manifest.json"] = json.dumps(evil_manifest).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(evil_renderer)
        self.assertIn("renderer_file", str(ctx.exception))

        # 4. Unconfined manifest_file pointing outside dashboard_packages/<slug>/
        evil_m = _build_valid_pack_v2_tree()
        evil_m["assets/manifest.json"] = evil_m["dashboard_packages/alpr-console/manifest.json"]
        evil_m_manifest = json.loads(evil_m["manifest.json"].decode("utf-8"))
        evil_m_manifest["files"]["assets/manifest.json"] = _sha256_hex(evil_m["assets/manifest.json"])
        evil_m_manifest["resources"]["dashboard_packages"][0]["manifest_file"] = "assets/manifest.json"
        evil_m["manifest.json"] = json.dumps(evil_m_manifest).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(evil_m)
        self.assertIn("manifest_file", str(ctx.exception))


class SecurityAndHygieneScannersTest(unittest.TestCase):
    """Verify SecretFreeValidator parity, synthetic-data hygiene, and test catalog helpers."""

    def test_secret_free_allows_clean_v2_pack_and_renderer_js_identifiers(self) -> None:
        v2 = _build_valid_pack_v2_tree(
            renderer_bytes=b"export function render(token, password) { return {token, password}; }\n"
        )
        self.assertEqual(vc.scan_secret_free(v2), [])

    def test_secret_free_catches_forbidden_keys_headers_and_token_literals(self) -> None:
        bad_json_tree = {
            "checks/bad.json": json.dumps(
                {
                    "api_key": "plaintext-key",
                    "headers": {
                        "Authorization": "Bearer live-secret-123456",
                        "X-Custom": "Basic dXNlcjpwYXNz",
                        "X-Allowed": "{{pack_param}}",
                    },
                }
            ).encode("utf-8")
        }
        violations = vc.scan_secret_free(bad_json_tree)
        codes = {v["code"] for v in violations}
        self.assertIn("forbidden_secret_key", codes)
        self.assertIn("forbidden_auth_header", codes)
        self.assertIn("forbidden_auth_header_value", codes)

        # Dynamically assemble token literals to verify all 8 patterns without static false alarms
        token_samples = {
            "pem_private_key": "-----BEGIN " + "RSA PRIVATE KEY-----\nMIIE",
            "github_pat": "ghp_" + "A1b2C3d4E5f6G7h8I9j0",
            "github_fine_grained_pat": "github_pat_" + "1234567890abcdef_xyz",
            "gitlab_pat": "glpat-" + "abcdef1234567890",
            "slack_token": "xoxb-" + "1234567890-abcdef",
            "aws_access_key": "AKIA" + "0123456789ABCDEF",
            "jwt_literal": "eyJhbGciOiJub25lIn0." + "eyJzdWIiOiJ0ZXN0In0." + "sig123456789",
            "auth_header_literal": "Authorization: Bearer " + "rawtoken123456",
        }
        for expected_code, literal in token_samples.items():
            with self.subTest(pattern=expected_code):
                tree = {"dashboard_packages/alpr-console/renderer.js": f"const x = '{literal}';\n"}
                found = {v["code"] for v in vc.scan_secret_free(tree)}
                self.assertIn(expected_code, found)

    def test_synthetic_hygiene_avoids_ordinary_english_false_positives(self) -> None:
        clean_text = (
            "Gate West 01 plate SR-0100 and Bay 04 Approach plate TEST-742 at "
            "https://s3.example.com/bucket via 192.0.2.10, 198.51.100.20, 203.0.113.30 "
            "(contact ops@example.org, 555-0142, (415) 555-0142, version 1.0.0). Ordinary words: "
            "equal, manual, actual, virtual, toEqual, quality."
        )
        self.assertEqual(vc.scan_synthetic_hygiene(clean_text), [])

    def test_synthetic_hygiene_rejects_live_ips_phones_domains_and_copyleft(self) -> None:
        bad_cases = [
            ("non_rfc5737_ipv4", "camera at 192.168.10.25"),
            ("non_rfc5737_ipv4", "dns 8.8.8.8"),
            ("non_synthetic_url_host", "https://prod.internal-company.io/v1"),
            ("non_synthetic_phone", "call 415-867-5309"),
            ("non_synthetic_phone", "call (415) 555-1234"),
            ("non_synthetic_phone", "call +1 (415) 555-1234"),
            ("disallowed_copyleft_reference", "powered by OpenALPR engine"),
        ]
        for expected_code, sample in bad_cases:
            with self.subTest(expected_code=expected_code, sample=sample):
                found = {v["code"] for v in vc.scan_synthetic_hygiene(sample)}
                self.assertIn(expected_code, found)

    def test_record_test_case_and_catalog_validation(self) -> None:
        entry = vc.record_test_case("F1", 1, "E2E-F1-T1-SAMPLE", "A", "Sample contract test")
        self.assertEqual(entry["tier"], 1)
        self.assertIn("E2E-F1-T1-SAMPLE", vc.get_registered_test_cases())

        # Valid complete synthetic catalog meets >= 162 minimums
        full_cases = []
        for f_idx in range(1, 15):
            for t in (1, 2):
                for n in range(1, 6):
                    full_cases.append(
                        {
                            "feature": f"F{f_idx}",
                            "tier": t,
                            "test_id": f"F{f_idx}-T{t}-{n}",
                            "mode": "A",
                            "description": f"Case {n}",
                        }
                    )
        for p in range(1, 16):
            full_cases.append(
                {
                    "feature": "T3",
                    "tier": 3,
                    "test_id": f"T3-{p}",
                    "mode": "B",
                    "description": f"Pair {p}",
                }
            )
        for w in range(1, 8):
            full_cases.append(
                {
                    "feature": "T4",
                    "tier": 4,
                    "test_id": f"T4-{w}",
                    "mode": "B",
                    "description": f"Workload {w}",
                }
            )
        summary = vc.validate_test_catalog(full_cases, enforce_minimums=True)
        self.assertEqual(summary["total"], 162)

        # Removing one Tier 4 workload fails enforce_minimums=True
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_test_catalog(full_cases[:-1], enforce_minimums=True)


class DriversFailClosedTest(unittest.TestCase):
    """Verify Mode B drivers fail closed (raise RuntimeError) when prerequisites are absent."""

    def test_env_probe_fails_closed_on_missing_binary_path_env_tcp_and_unwritable_scratch(self) -> None:
        with self.assertRaises(RuntimeError):
            env_probe.probe_binary("__nonexistent_vantage_binary__")
        with self.assertRaises(RuntimeError):
            env_probe.probe_path("/nonexistent/vantage/path/12345")
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                env_probe.probe_env_vars("SERVICERADAR_E2E_WEB_URL")
            with self.assertRaises(RuntimeError):
                env_probe.probe_mode_b_environment(require_services=True)
        with self.assertRaises(RuntimeError):
            env_probe.probe_tcp("127.0.0.1", 1, timeout=0.2)

        # Pointing VANTAGE_E2E_SCRATCH_DIR at an existing regular file must fail closed
        base_dir = Path(
            os.environ.get("TEST_TMPDIR") or "/Volumes/Build/scratch/vantage-ml-e2e/mode-a-probe"
        )
        base_dir.mkdir(parents=True, exist_ok=True)
        blocker_file = base_dir / "not_a_directory"
        blocker_file.write_text("file", encoding="utf-8")
        try:
            with mock.patch.dict(os.environ, {"VANTAGE_E2E_SCRATCH_DIR": str(blocker_file)}):
                with self.assertRaises(RuntimeError):
                    env_probe.get_scratch_dir()
        finally:
            if blocker_file.exists():
                blocker_file.unlink()

    def test_runtime_drivers_fail_closed_when_unconfigured_or_missing_tools(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                nats_driver.require_nats_url()
            with self.assertRaises(RuntimeError):
                cnpg_driver.require_database_url()
            with self.assertRaises(RuntimeError):
                http_ws_driver.require_web_url()
            with self.assertRaises(RuntimeError):
                sdk_driver.run_cargo_test(sdk_dir=Path("/nonexistent/sdk/path"))
            with self.assertRaises(RuntimeError):
                cli_driver.resolve_cli_entrypoint(repo=Path("/nonexistent/repo/path"))
            with mock.patch("shutil.which", return_value=None):
                with self.assertRaises(RuntimeError):
                    media_gen.generate_synthetic_h264_mp4()

    def test_phoenix_channel_client_wraps_oserror_and_answers_ping_with_masked_pong(self) -> None:
        # 1. Connecting to a closed ephemeral TCP port must raise RuntimeError (not ConnectionRefusedError)
        probe_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe_sock.bind(("127.0.0.1", 0))
        closed_port = probe_sock.getsockname()[1]
        probe_sock.close()
        with self.assertRaises(RuntimeError):
            http_ws_driver.PhoenixChannelClient(
                f"ws://127.0.0.1:{closed_port}/socket/websocket", timeout=1.0
            )

        # 2. Live loopback WebSocket server: handshake -> send Ping (0x89) -> verify masked Pong (0x8A) -> send JSON
        received_pong: dict[str, object] = {}
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        srv.settimeout(5.0)
        ws_port = srv.getsockname()[1]

        def _ws_server() -> None:
            conn, _ = srv.accept()
            conn.settimeout(5.0)
            try:
                req = b""
                while b"\r\n\r\n" not in req:
                    req += conn.recv(4096)
                ws_key = ""
                for line in req.decode("latin-1").splitlines():
                    if line.lower().startswith("sec-websocket-key:"):
                        ws_key = line.split(":", 1)[1].strip()
                accept = base64.b64encode(
                    hashlib.sha1(
                        (ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
                    ).digest()
                ).decode("ascii")
                conn.sendall(
                    (
                        "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                    ).encode("ascii")
                )
                # Send unmasked server Ping frame with payload b"hb1"
                conn.sendall(bytes([0x89, 3]) + b"hb1")
                # Read masked Pong frame from client
                hdr = conn.recv(2)
                b0, b1 = hdr[0], hdr[1]
                mask = conn.recv(4)
                masked_payload = conn.recv(b1 & 0x7F)
                unmasked = bytes(b ^ mask[i % 4] for i, b in enumerate(masked_payload))
                received_pong["b0"] = b0
                received_pong["masked"] = bool(b1 & 0x80)
                received_pong["payload"] = unmasked
                # Send JSON text frame
                msg = json.dumps(["1", "1", "room:lobby", "phx_reply", {"status": "ok"}]).encode(
                    "utf-8"
                )
                conn.sendall(bytes([0x81, len(msg)]) + msg)
            finally:
                conn.close()
                srv.close()

        thread = threading.Thread(target=_ws_server, daemon=True)
        thread.start()
        client = http_ws_driver.PhoenixChannelClient(
            f"ws://127.0.0.1:{ws_port}/socket/websocket", timeout=5.0
        )
        try:
            reply = client.recv_json()
            self.assertEqual(reply[3], "phx_reply")
            self.assertEqual(received_pong.get("b0"), 0x8A)
            self.assertTrue(received_pong.get("masked"))
            self.assertEqual(received_pong.get("payload"), b"hb1")
            client.close()
            with self.assertRaises(RuntimeError):
                client._send_text("after-close")
        finally:
            client.close()
            thread.join(timeout=5.0)

    def test_nats_driver_start_ephemeral_jetstream_polls_until_ready_and_cleans_up(self) -> None:
        fake_proc = mock.MagicMock()
        fake_proc.poll.return_value = None
        scratch_path = Path("/Volumes/Build/scratch/vantage-ml-e2e/nats/js-14222")
        with (
            mock.patch.object(env_probe, "probe_binary", return_value=Path("/usr/bin/nats-server")),
            mock.patch.object(env_probe, "get_scratch_dir", return_value=scratch_path),
            mock.patch("subprocess.Popen", return_value=fake_proc),
            mock.patch.object(
                env_probe,
                "probe_tcp",
                side_effect=[RuntimeError("refused"), RuntimeError("refused"), None],
            ) as probe_mock,
            mock.patch("time.sleep"),
        ):
            proc, url, store = nats_driver.start_ephemeral_jetstream(port=14222, timeout=2.0)
            self.assertIs(proc, fake_proc)
            self.assertEqual(url, "nats://127.0.0.1:14222")
            self.assertEqual(store, scratch_path)
            self.assertEqual(probe_mock.call_count, 3)
            fake_proc.terminate.assert_not_called()

        exited_proc = mock.MagicMock()
        exited_proc.poll.return_value = 1
        exited_proc.stderr = mock.MagicMock()
        exited_proc.stderr.read.return_value = b"address already in use"
        with (
            mock.patch.object(env_probe, "probe_binary", return_value=Path("/usr/bin/nats-server")),
            mock.patch.object(env_probe, "get_scratch_dir", return_value=scratch_path),
            mock.patch("subprocess.Popen", return_value=exited_proc),
        ):
            with self.assertRaises(RuntimeError) as ctx:
                nats_driver.start_ephemeral_jetstream(port=14222, timeout=2.0)
            self.assertIn("exited prematurely", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
