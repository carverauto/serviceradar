"""Mode A hermetic Solution Pack v2, USTAR archive, SHA-256, secret-free & hygiene suite."""

from __future__ import annotations

import copy
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
import unittest
from pathlib import Path
from typing import Any

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc


def _fixtures_dir() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures" / "f6_f10"


def _load_json(filename: str) -> Any:
    path = _fixtures_dir() / filename
    if not path.is_file():
        raise AssertionError(f"missing fixture file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256_hex(data: bytes | str) -> str:
    raw = data.encode("utf-8") if isinstance(data, str) else data
    return hashlib.sha256(raw).hexdigest()


def _canonical_json(obj: Any) -> str:
    """Canonical JSON matching Elixir `ServiceRadar.Catalog.UploadSignature.canonical_json/1`."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _tree_to_bytes(files_map: dict[str, str | bytes]) -> dict[str, bytes]:
    return {
        k: (v.encode("utf-8") if isinstance(v, str) else bytes(v))
        for k, v in files_map.items()
    }


def _recompute_manifest_files(tree: dict[str, bytes]) -> dict[str, bytes]:
    updated = dict(tree)
    manifest = json.loads(updated["manifest.json"].decode("utf-8"))
    manifest["files"] = {
        path: _sha256_hex(content)
        for path, content in sorted(updated.items())
        if path != "manifest.json"
    }
    updated["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    return updated


def _build_symlink_ustar(path: str, linkname: str) -> bytes:
    """Construct a POSIX.1-1988 USTAR tar stream containing a symlink entry (typeflag '2')."""
    header = bytearray(512)
    name_b = path.encode("utf-8")
    link_b = linkname.encode("utf-8")
    header[0 : len(name_b)] = name_b
    header[100:108] = b"0000777\x00"
    header[108:116] = b"0000000\x00"
    header[116:124] = b"0000000\x00"
    header[124:136] = b"00000000000\x00"
    header[136:148] = b"00000000000\x00"
    header[148:156] = b"        "
    header[156] = ord("2")
    header[157 : 157 + len(link_b)] = link_b
    header[257:263] = b"ustar\x00"
    header[263:265] = b"00"
    header[329:337] = b"0000000\x00"
    header[337:345] = b"0000000\x00"
    checksum = sum(header)
    header[148:156] = f"{checksum:06o}\x00 ".encode("ascii")
    return bytes(header) + (b"\x00" * 1024)


def _validate_extracted_ustar_members(tar_bytes: bytes) -> dict[str, bytes]:
    """Read USTAR tar bytes via stdlib tarfile and fail closed on symlinks/unsafe paths."""
    extracted: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for member in tf.getmembers():
            if member.issym() or member.islnk():
                raise vc.ContractValidationError("symlink_forbidden")
            if not member.isreg():
                raise vc.ContractValidationError(f"non_regular_entry_forbidden:{member.type!r}")
            if member.name.startswith("/") or ".." in member.name.split("/"):
                raise vc.ContractValidationError(f"unsafe_archive_path:{member.name!r}")
            fobj = tf.extractfile(member)
            if fobj is None:
                raise vc.ContractValidationError(f"unreadable_archive_member:{member.name!r}")
            extracted[member.name] = fobj.read()
    return extracted


class PackV2ArchiveAndManifestTest(unittest.TestCase):
    """Verify Solution Pack v1 compatibility, v2 schema/archive bounds, and USTAR round-trips."""

    def test_v1_compat_reference_validates_with_25_64_limits_and_rejects_v2_keys(self) -> None:
        v1_ref = _load_json("pack_v1_compat_reference.json")
        neg = _load_json("pack_v2_negative_cases.json")
        tree = _tree_to_bytes(v1_ref["files"])

        summary = vc.validate_pack_v2_tree(tree, compressed_bytes=vc.PACK_V1_LIMITS[0])
        self.assertEqual(summary["pack_format_version"], 1)
        self.assertFalse(summary["has_dashboard_packages"])
        self.assertEqual(summary["limits"], vc.PACK_V1_LIMITS)

        for case in neg["v1_with_v2_fields"]:
            with self.subTest(case=case["name"]):
                mutated = dict(tree)
                manifest = json.loads(mutated["manifest.json"].decode("utf-8"))
                if case["scope"] == "resources":
                    manifest["resources"][case["field"]] = case["value"]
                else:
                    manifest[case["field"]] = case["value"]
                mutated["manifest.json"] = json.dumps(manifest).encode("utf-8")
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_pack_v2_tree(mutated)
                self.assertIn(case["expected_error_substring"], str(ctx.exception))

    def test_v2_without_vs_with_dashboard_packages_and_archive_bounds(self) -> None:
        v2_ref = _load_json("pack_v2_alpr_reference.json")
        neg = _load_json("pack_v2_negative_cases.json")
        v2_tree = _tree_to_bytes(v2_ref["files"])

        # Build a v2 tree WITHOUT dashboard_packages (must retain 25 MiB / 64 MiB limits)
        v2_no_dash = {
            k: v for k, v in v2_tree.items() if not k.startswith("dashboard_packages/")
        }
        m_no_dash = json.loads(v2_no_dash["manifest.json"].decode("utf-8"))
        del m_no_dash["resources"]["dashboard_packages"]
        v2_no_dash["manifest.json"] = json.dumps(m_no_dash).encode("utf-8")
        v2_no_dash = _recompute_manifest_files(v2_no_dash)

        res_no_dash = vc.validate_pack_v2_tree(v2_no_dash, compressed_bytes=vc.PACK_V1_LIMITS[0])
        self.assertFalse(res_no_dash["has_dashboard_packages"])
        self.assertEqual(res_no_dash["limits"], vc.PACK_V1_LIMITS)

        for case in neg["archive_bounds_cases"]:
            with self.subTest(case=case["name"]):
                if case["pack_format_version"] == 1:
                    target_tree = _tree_to_bytes(_load_json("pack_v1_compat_reference.json")["files"])
                elif case["has_dashboard_packages"]:
                    target_tree = v2_tree
                else:
                    target_tree = v2_no_dash

                if "attempted_uncompressed_bytes" in case:
                    with self.assertRaises(vc.ContractValidationError) as ctx:
                        vc.build_deterministic_ustar(
                            {"assets/blob.bin": b"x" * case["attempted_uncompressed_bytes"]},
                            max_uncompressed_bytes=case["max_uncompressed_bytes"],
                        )
                    self.assertIn(case["expected_error_substring"], str(ctx.exception))
                elif case["should_pass"]:
                    res = vc.validate_pack_v2_tree(
                        target_tree, compressed_bytes=case["compressed_bytes"]
                    )
                    self.assertEqual(res["pack_format_version"], case["pack_format_version"])
                else:
                    with self.assertRaises(vc.ContractValidationError) as ctx:
                        vc.validate_pack_v2_tree(
                            target_tree, compressed_bytes=case["compressed_bytes"]
                        )
                    self.assertIn(case["expected_error_substring"], str(ctx.exception))

    def test_renderer_8mib_exact_vs_plus_one_and_dashboard_manifest_limits(self) -> None:
        v2_ref = _load_json("pack_v2_alpr_reference.json")
        neg = _load_json("pack_v2_negative_cases.json")
        base_tree = _tree_to_bytes(v2_ref["files"])

        def _with_renderer(raw_renderer: bytes) -> dict[str, bytes]:
            t = dict(base_tree)
            t["dashboard_packages/alpr-console/renderer.js"] = raw_renderer
            dm = json.loads(t["dashboard_packages/alpr-console/manifest.json"].decode("utf-8"))
            dm["renderer"]["sha256"] = _sha256_hex(raw_renderer)
            t["dashboard_packages/alpr-console/manifest.json"] = json.dumps(dm).encode("utf-8")
            return _recompute_manifest_files(t)

        exact_bytes = neg["renderer_size_cases"]["exact_allowed_bytes"]
        self.assertEqual(exact_bytes, vc.MAX_RENDERER_BYTES)
        exact_tree = _with_renderer(b"a" * exact_bytes)
        res = vc.validate_pack_v2_tree(exact_tree)
        self.assertTrue(res["has_dashboard_packages"])

        over_bytes = neg["renderer_size_cases"]["rejected_over_bytes"]
        over_tree = _with_renderer(b"a" * over_bytes)
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(over_tree)
        self.assertIn(neg["renderer_size_cases"]["expected_error_substring"], str(ctx.exception))

        # Dashboard manifest > 262_144 bytes rejected
        dm_obj = json.loads(base_tree["dashboard_packages/alpr-console/manifest.json"].decode("utf-8"))
        dm_obj["description"] = "d" * vc.MAX_DASHBOARD_MANIFEST_BYTES
        oversized_dm_tree = dict(base_tree)
        oversized_dm_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(dm_obj).encode(
            "utf-8"
        )
        oversized_dm_tree = _recompute_manifest_files(oversized_dm_tree)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(oversized_dm_tree)

    def test_dashboard_browser_module_v1_capabilities_trust_data_frames_and_deps(self) -> None:
        v2_ref = _load_json("pack_v2_alpr_reference.json")
        base_tree = _tree_to_bytes(v2_ref["files"])

        # All 12 ALLOWED_DASHBOARD_CAPABILITIES accepted
        dm_all_caps = json.loads(base_tree["dashboard_packages/alpr-console/manifest.json"].decode("utf-8"))
        dm_all_caps["capabilities"] = sorted(vc.ALLOWED_DASHBOARD_CAPABILITIES)
        all_caps_tree = dict(base_tree)
        all_caps_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(
            dm_all_caps
        ).encode("utf-8")
        all_caps_tree = _recompute_manifest_files(all_caps_tree)
        vc.validate_pack_v2_tree(all_caps_tree)

        # Unknown capability rejected
        dm_bad_cap = copy.deepcopy(dm_all_caps)
        dm_bad_cap["capabilities"] = ["camera.stream.view", "kernel.shell.exec"]
        bad_cap_tree = dict(base_tree)
        bad_cap_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(
            dm_bad_cap
        ).encode("utf-8")
        bad_cap_tree = _recompute_manifest_files(bad_cap_tree)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(bad_cap_tree)

        # trust != "trusted" rejected
        dm_untrusted = copy.deepcopy(dm_all_caps)
        dm_untrusted["renderer"]["trust"] = "community"
        untrusted_tree = dict(base_tree)
        untrusted_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(
            dm_untrusted
        ).encode("utf-8")
        untrusted_tree = _recompute_manifest_files(untrusted_tree)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(untrusted_tree)

        # Empty data_frames rejected
        dm_empty_df = copy.deepcopy(dm_all_caps)
        dm_empty_df["data_frames"] = []
        empty_df_tree = dict(base_tree)
        empty_df_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(
            dm_empty_df
        ).encode("utf-8")
        empty_df_tree = _recompute_manifest_files(empty_df_tree)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(empty_df_tree)

        # Valid dashboard_package_dependencies string & dict formats accepted; bad ref rejected
        for valid_deps in (
            ["io.serviceradar.alpr-console@1.0.0"],
            [{"dashboard_id": "io.serviceradar.alpr-console", "version_range": ">=1.0.0"}],
        ):
            dep_tree = dict(base_tree)
            m = json.loads(dep_tree["manifest.json"].decode("utf-8"))
            m["dashboard_package_dependencies"] = valid_deps
            dep_tree["manifest.json"] = json.dumps(m).encode("utf-8")
            vc.validate_pack_v2_tree(dep_tree)

        bad_dep_tree = dict(base_tree)
        m_bad = json.loads(bad_dep_tree["manifest.json"].decode("utf-8"))
        m_bad["dashboard_package_dependencies"] = ["missing-at-version"]
        bad_dep_tree["manifest.json"] = json.dumps(m_bad).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(bad_dep_tree)

    def test_triple_sha256_parity_and_tampered_renderer_rejection(self) -> None:
        v2_ref = _load_json("pack_v2_alpr_reference.json")
        neg = _load_json("pack_v2_negative_cases.json")
        v2_tree = _tree_to_bytes(v2_ref["files"])

        dm = json.loads(v2_tree["dashboard_packages/alpr-console/manifest.json"].decode("utf-8"))
        root_manifest = json.loads(v2_tree["manifest.json"].decode("utf-8"))
        actual_sha = _sha256_hex(v2_tree["dashboard_packages/alpr-console/renderer.js"])
        self.assertEqual(dm["renderer"]["sha256"], actual_sha)
        self.assertEqual(
            root_manifest["files"]["dashboard_packages/alpr-console/renderer.js"], actual_sha
        )

        # Tamper renderer.js and only update root manifest.files -> dashboard manifest mismatch fails
        tamper = neg["tampered_renderer_case"]
        tampered_tree = dict(v2_tree)
        tampered_tree[tamper["target_file"]] = tamper["tampered_content"].encode("utf-8")
        tampered_tree = _recompute_manifest_files(tampered_tree)
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(tampered_tree)
        self.assertIn(tamper["expected_error_substring"], str(ctx.exception))

    def test_deterministic_ustar_targz_roundtrip_and_unsafe_paths_and_symlinks(self) -> None:
        v2_ref = _load_json("pack_v2_alpr_reference.json")
        neg = _load_json("pack_v2_negative_cases.json")
        v2_tree = _tree_to_bytes(v2_ref["files"])

        reversed_tree = {k: v2_tree[k] for k in reversed(list(v2_tree.keys()))}
        gz_a = vc.build_deterministic_targz(v2_tree)
        gz_b = vc.build_deterministic_targz(reversed_tree)
        self.assertEqual(gz_a, gz_b)
        self.assertEqual(gz_a[4:8], b"\x00\x00\x00\x00")
        self.assertEqual(gz_a[9], 0xFF)

        tar_bytes = gzip.decompress(gz_a)
        extracted = _validate_extracted_ustar_members(tar_bytes)
        self.assertEqual(set(extracted.keys()), set(v2_tree.keys()))
        for path, content in v2_tree.items():
            self.assertEqual(extracted[path], content)
        vc.validate_pack_v2_tree(extracted, compressed_bytes=len(gz_a))

        # Unsafe paths and >240 byte paths rejected
        for bad_path in neg["unsafe_paths"]:
            with self.subTest(bad_path=bad_path):
                with self.assertRaises(vc.ContractValidationError):
                    vc.build_deterministic_ustar({bad_path: b"x"})

        # Symlink entry in USTAR stream rejected
        sym = neg["symlink_entry"]
        symlink_tar = _build_symlink_ustar(sym["path"], sym["linkname"])
        with self.assertRaises(vc.ContractValidationError) as ctx:
            _validate_extracted_ustar_members(symlink_tar)
        self.assertIn(sym["expected_error"], str(ctx.exception))

    def test_secret_free_minified_js_rules_and_upload_signature_canonical_payload(self) -> None:
        v2_ref = _load_json("pack_v2_alpr_reference.json")
        neg = _load_json("pack_v2_negative_cases.json")
        v2_tree = _tree_to_bytes(v2_ref["files"])

        # Benign minified JS identifiers allowed
        benign = neg["benign_minified_js_identifiers"]
        benign_tree = dict(v2_tree)
        benign_tree[benign["file"]] = benign["source"].encode("utf-8")
        self.assertEqual(len(vc.scan_secret_free(benign_tree)), benign["expected_violations"])

        # Assembled token literals inside renderer.js rejected
        for case in neg["secret_leaks"]["token_literal_parts"]:
            with self.subTest(case=case["name"]):
                literal = "".join(case["parts"])
                leak_tree = {
                    "dashboard_packages/alpr-console/renderer.js": f"const x = {json.dumps(literal)};\n"
                }
                codes = {v["code"] for v in vc.scan_secret_free(leak_tree)}
                self.assertIn(case["expected_code"], codes)

        # Forbidden JSON keys and literal Authorization headers rejected
        for case in neg["secret_leaks"]["json_forbidden_keys"]:
            with self.subTest(case=case["name"]):
                obj = json.loads(v2_tree[case["file"]].decode("utf-8"))
                obj[case["key"]] = case["value"]
                codes = {v["code"] for v in vc.scan_secret_free({case["file"]: json.dumps(obj)})}
                for expected_code in case["expected_codes"]:
                    self.assertIn(expected_code, codes)

        # UploadSignature canonical JSON payload determinism (key-order invariant)
        manifest_a = json.loads(v2_tree["manifest.json"].decode("utf-8"))
        manifest_b = {k: manifest_a[k] for k in reversed(list(manifest_a.keys()))}
        gz_bytes = vc.build_deterministic_targz(v2_tree)
        content_hash = _sha256_hex(gz_bytes)
        payload_a = _canonical_json({"manifest": manifest_a, "content_hash": content_hash})
        payload_b = _canonical_json({"content_hash": content_hash, "manifest": manifest_b})
        self.assertEqual(payload_a, payload_b)
        self.assertTrue(payload_a.startswith('{"content_hash":"' + content_hash + '","manifest":{'))

    def test_synthetic_hygiene_across_all_f6_f10_fixtures_and_catalog(self) -> None:
        fdir = _fixtures_dir()
        json_files = sorted(fdir.glob("*.json"))
        self.assertGreaterEqual(len(json_files), 8)
        for p in json_files:
            with self.subTest(fixture=p.name):
                vc.assert_synthetic_hygiene(p.read_text(encoding="utf-8"))

        catalog_path = vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures" / "catalog_f6_f10.json"
        vc.assert_synthetic_hygiene(catalog_path.read_text(encoding="utf-8"))

    def test_shipped_vantage_alpr_pack_passes_mode_a_and_wire_vectors(self) -> None:
        pack_dir = (
            vc.repo_root()
            / "elixir"
            / "serviceradar_core"
            / "priv"
            / "solution_packs"
            / "vantage-alpr"
        )
        self.assertTrue((pack_dir / "manifest.json").is_file(), f"missing {pack_dir}")

        tree_bytes = {
            p.relative_to(pack_dir).as_posix(): p.read_bytes()
            for p in sorted(pack_dir.rglob("*"))
            if p.is_file() and not p.name.startswith(".")
        }

        summary = vc.validate_pack_v2_tree(tree_bytes)
        self.assertEqual(summary["pack_format_version"], 2)
        self.assertEqual(summary["id"], "io.serviceradar.vantage-alpr")
        self.assertEqual(summary["slug"], "vantage-alpr")
        self.assertTrue(summary["has_dashboard_packages"])
        self.assertEqual(vc.scan_secret_free(tree_bytes), [])

        standard_spec_hosts = {"www.w3.org", "json-schema.org", "react.dev"}
        for rel_path, content in tree_bytes.items():
            text = content.decode("ascii")
            self.assertGreater(len(text), 0, rel_path)
            violations = vc.scan_synthetic_hygiene(text)
            unexpected = [
                v
                for v in violations
                if not (
                    v["code"] == "non_synthetic_url_host"
                    and v["match"] in standard_spec_hosts
                    and rel_path
                    in {
                        "assets/architecture.svg",
                        "signal_schemas/alpr_plate_read.schema.json",
                        "dashboard_packages/alpr-console/renderer.js",
                    }
                )
            ]
            self.assertEqual(unexpected, [], f"hygiene violations in {rel_path}: {unexpected}")

        gz_a = vc.build_deterministic_targz(tree_bytes)
        gz_b = vc.build_deterministic_targz(dict(reversed(list(tree_bytes.items()))))
        self.assertEqual(gz_a, gz_b)
        vc.validate_pack_v2_tree(tree_bytes, compressed_bytes=len(gz_a))

        schema_doc = json.loads(
            tree_bytes["signal_schemas/alpr_plate_read.schema.json"].decode("utf-8")
        )
        wire_vec = json.loads(
            (
                vc.repo_root()
                / "integration_tests"
                / "vantage_ml"
                / "fixtures"
                / "wire_vectors"
                / "alpr_plate_read_schema.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(schema_doc["schema_id"], wire_vec["schema_id"])
        self.assertEqual(schema_doc["version"], wire_vec["schema_version"])
        self.assertEqual(schema_doc["required"], ["plate_text"])
        self.assertIs(schema_doc["additionalProperties"], False)

        for pos in wire_vec["positive"]:
            vc.validate_alpr_attributes(pos)
        for neg_case in wire_vec["negative"]:
            with self.subTest(negative=neg_case["name"]):
                with self.assertRaises(vc.ContractValidationError):
                    vc.validate_alpr_attributes(neg_case["attributes"])


if __name__ == "__main__":
    unittest.main()
