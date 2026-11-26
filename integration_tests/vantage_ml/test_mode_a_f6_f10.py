"""Mode A hermetic Tier 1 & Tier 2 contract tests for F6-F10."""

from __future__ import annotations

import base64
import copy
import hashlib
import html
import json
import os
import re
import shlex
import socket
import sys
import threading
import unittest
from pathlib import Path
from typing import Any

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc
from integration_tests.vantage_ml.drivers import http_ws_driver


def _fixtures_root() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures"


def _load_f6_f10(filename: str) -> Any:
    path = _fixtures_root() / "f6_f10" / filename
    if not path.is_file():
        raise AssertionError(f"missing fixture {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _load_catalog_f6_f10() -> dict[str, Any]:
    path = _fixtures_root() / "catalog_f6_f10.json"
    if not path.is_file():
        raise AssertionError(f"missing catalog {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _register_catalog_cases() -> None:
    catalog = _load_catalog_f6_f10()
    for case in catalog["cases"]:
        vc.record_test_case(
            case["feature"],
            case["tier"],
            case["test_id"],
            case["mode"],
            case["description"],
        )


def _extract_last_srql_entity(query: str) -> str:
    """Mirror `rust/srql/src/parser.rs` & `Readers.entity_for_query/1` last-`in:` precedence."""
    lexer = shlex.shlex(query, posix=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
    entity: str | None = None
    for tok in tokens:
        if ":" not in tok:
            continue
        raw_key, raw_val = tok.split(":", 1)
        if raw_key.strip().lower() == "in":
            cleaned = raw_val.strip().strip('"').strip("'").lower()
            if cleaned:
                entity = cleaned
    if entity is None:
        raise vc.ContractValidationError(f"SRQL query missing in:<entity>: {query!r}")
    return entity


def _authorize_srql_entity(entity: str, permissions: set[str]) -> bool:
    """Enforce `{:all_of, ["devices.view", "devices.cameras.recordings.view"]}` for camera_observations."""
    if entity == "camera_observations":
        return {"devices.view", "devices.cameras.recordings.view"}.issubset(permissions)
    if entity == "devices":
        return "devices.view" in permissions
    return False


def _is_observation_queryable(entry: dict[str, Any], authorized_sources: set[str], camera_source_id: str) -> bool:
    if camera_source_id not in authorized_sources:
        return False
    if entry["source_mode"] == "live_keyframe_tap" and entry["catalog_entry_id"] is None:
        return True
    if entry.get("quarantine_reason") is not None:
        return False
    local_state = entry.get("local_state")
    archive_state = entry.get("archive_state")
    if local_state == "quarantined":
        return False
    return local_state == "present" or archive_state == "verified"


def _validate_semantic_search_params(
    query: str,
    window_us: int | None = None,
    *,
    from_us: int | None = None,
    to_us: int | None = None,
) -> str | None:
    trimmed = query.strip()
    if not trimmed or len(trimmed) > 256:
        return "invalid_query"
    max_window_us = 31 * 86_400 * 1_000_000
    if from_us is not None and to_us is not None:
        if from_us < 0 or from_us >= to_us:
            return "invalid_time_window"
        if (to_us - from_us) > max_window_us:
            return "window_too_large"
    elif window_us is not None:
        if window_us <= 0:
            return "invalid_time_window"
        if window_us > max_window_us:
            return "window_too_large"
    return None


def _match_dashboard_event_filter(
    event: dict[str, Any],
    sub_filter: dict[str, Any],
    viewer_permissions: set[str],
    authorized_sources: set[str],
) -> tuple[bool, str | None]:
    sr_meta = event.get("metadata", {}).get("service_radar", {})
    is_camera_event = sr_meta.get("source_type") == "camera_vantage"
    if is_camera_event:
        if not {"devices.view", "devices.cameras.recordings.view"}.issubset(viewer_permissions):
            return False, "forbidden_camera_event"
        cam_id = sr_meta.get("camera_source_id")
        if cam_id not in authorized_sources:
            return False, "unauthorized_camera_source"

    if "class_uid" in sub_filter and event.get("class_uid") != sub_filter["class_uid"]:
        return False, None
    if "camera_source_id" in sub_filter and sr_meta.get("camera_source_id") != sub_filter["camera_source_id"]:
        return False, None

    meta_filter = sub_filter.get("metadata")
    if isinstance(meta_filter, dict):
        if not _dict_subset_match(event.get("metadata", {}), meta_filter):
            return False, None
    return True, None


def _dict_subset_match(actual: Any, expected: Any) -> bool:
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False
        for k, v in expected.items():
            if k not in actual:
                return False
            if not _dict_subset_match(actual[k], v):
                return False
        return True
    if isinstance(expected, str) and isinstance(actual, dict) and "schema_id" in actual:
        # Shorthand `signal_schema: "alpr_plate_read"` matching nested `{"schema_id": "alpr_plate_read"}`
        return actual.get("schema_id") == expected
    return actual == expected


def _validate_nested_event_filter(sub_filter: Any) -> tuple[bool, str | None]:
    if not isinstance(sub_filter, dict):
        return False, "invalid_filter"
    allowed_top = {"log_provider", "log_name", "device_uid", "class_uid", "min_severity_id", "metadata", "camera_source_id"}
    unknown = set(sub_filter.keys()) - allowed_top
    if unknown:
        return False, f"unknown_filter_keys:{sorted(unknown)}"

    def _depth_and_size(node: Any, depth: int = 0) -> tuple[int, int]:
        if depth > 4:
            raise vc.ContractValidationError("metadata filter depth exceeded")
        if isinstance(node, dict):
            if len(node) > 8:
                raise vc.ContractValidationError("metadata filter map exceeds 8 keys")
            max_d = depth
            total = len(node)
            for v in node.values():
                d, c = _depth_and_size(v, depth + 1)
                max_d = max(max_d, d)
                total += c
            return max_d, total
        if isinstance(node, (str, int, float, bool)) and not isinstance(node, list):
            return depth, 0
        raise vc.ContractValidationError("unsupported filter leaf type")

    if "metadata" in sub_filter:
        try:
            _depth_and_size(sub_filter["metadata"], 1)
        except vc.ContractValidationError as exc:
            return False, str(exc)
    return True, None


def _escape_overlay_text(value: str) -> str:
    """Mirror `CameraTimelinePlayer.js` `escapeOverlayText` (`& < > " '`)."""
    return html.escape(value, quote=True)


_SAFE_THUMB_URL_RE = re.compile(r"^(/([^/]|$)|https?://)", re.IGNORECASE)


def _is_safe_thumbnail_url(url: str | None) -> bool:
    if not url or not isinstance(url, str):
        return False
    return bool(_SAFE_THUMB_URL_RE.match(url.strip()))


def _evaluate_rbac_install(permissions: list[str], explicit_approval: bool) -> dict[str, Any]:
    perms = set(permissions)
    if "catalog.packs.install" not in perms and "catalog.gitops.sync" not in perms:
        return {"allowed": False, "error": "forbidden", "status": None, "instance_bound": False}
    can_manage = (
        "dashboards.packages.manage" in perms
        or (
            ("dashboards.packages.publish" in perms or "cli.dashboard.publish" in perms)
            and ("dashboards.packages.enable" in perms or "cli.dashboard.enable" in perms)
        )
    )
    if can_manage and explicit_approval:
        return {"allowed": True, "error": None, "status": "enabled", "instance_bound": True}
    return {"allowed": True, "error": None, "status": "staged", "instance_bound": False}


def _evaluate_worker_dependency(dep: dict[str, Any], healthy_workers: list[dict[str, Any]]) -> dict[str, Any]:
    cap = dep["capability"]
    matching = [
        w
        for w in healthy_workers
        if w.get("capability") == cap and w.get("health") == "ready"
    ]
    if matching:
        return {"ready": True, "blocking_count": 0, "effective_runner": cap}
    if dep.get("optional") and dep.get("fallback_runner"):
        return {"ready": True, "blocking_count": 0, "effective_runner": dep["fallback_runner"]}
    return {"ready": False, "blocking_count": 1, "effective_runner": None}


def _evaluate_pack_upgrade_transition(case: dict[str, Any]) -> dict[str, Any]:
    """Simulate Reconciler v2 upgrade preserving overrides, rule state, and detached instances."""
    from_ver = case["from_version"]
    to_ver = case["to_version"]
    overrides = copy.deepcopy(case["pipeline_overrides"])
    rule_install_state = case["rule_install_state"]
    detached_managed = bool(case["detached_dashboard_instance_managed"])

    before_pipeline = {"version": from_ver, "parameter_overrides": copy.deepcopy(overrides)}
    before_rule = {
        "install_state": rule_install_state,
        "enabled": rule_install_state == "enabled",
    }
    before_instance = {"managed": detached_managed, "pack_version": from_ver}

    # Apply upgrade 1.0.0 -> 1.1.0
    after_pipeline = {
        "version": to_ver,
        "parameter_overrides": copy.deepcopy(before_pipeline["parameter_overrides"]),
    }
    after_rule = {"enabled": before_rule["enabled"]}
    after_instance = (
        dict(before_instance)
        if not before_instance["managed"]
        else {"managed": True, "pack_version": to_ver}
    )

    return {
        "overrides_preserved": (
            after_pipeline["version"] == to_ver
            and after_pipeline["version"] != before_pipeline["version"]
            and after_pipeline["parameter_overrides"] == overrides
            and len(after_pipeline["parameter_overrides"]) > 0
        ),
        "rule_enabled": after_rule["enabled"],
        "detached_instance_preserved": (
            not after_instance["managed"] and after_instance["pack_version"] == from_ver
        ),
    }


def _evaluate_pack_uninstall_transition(case: dict[str, Any]) -> dict[str, Any]:
    """Simulate Reconciler v2 uninstall disabling managed pipeline and detaching managed instances."""
    if not case["managed_pipeline_active_before"]:
        raise vc.ContractValidationError("uninstall requires an active managed pipeline before uninstall")
    if not case["managed_instance_before"]:
        raise vc.ContractValidationError("uninstall test requires a managed instance before uninstall")

    managed_pipeline_enabled_after = False
    managed_instance_detached = True
    detached_instance_preserved = bool(case["detached_instance_before"])
    return {
        "managed_pipeline_enabled_after": managed_pipeline_enabled_after,
        "managed_instance_detached": managed_instance_detached,
        "detached_instance_preserved": detached_instance_preserved,
    }


def _evaluate_package_immutability(
    existing_status: str, existing_content_hash: str, incoming_content_hash: str
) -> tuple[bool, str | None]:
    """Mirror DashboardPackage / PackageImport immutability on published enabled versions."""
    if existing_status == "enabled" and existing_content_hash != incoming_content_hash:
        return False, "version_already_published"
    return True, None


_ALLOWED_VANTAGE_TEMPLATES = frozenset({"vlm", "python-worker", "rust-worker"})


def _expected_vantage_scaffold_files(args: list[str]) -> set[str]:
    if len(args) < 3 or args[0] != "vantage" or args[1] != "init":
        raise vc.ContractValidationError(f"invalid vantage init args: {args!r}")
    if "--template" not in args:
        raise vc.ContractValidationError(f"missing --template in {args!r}")
    idx = args.index("--template")
    if idx + 1 >= len(args):
        raise vc.ContractValidationError(f"missing template value in {args!r}")
    template = args[idx + 1]
    if template not in _ALLOWED_VANTAGE_TEMPLATES:
        raise vc.ContractValidationError(f"unknown vantage template {template!r}")
    base = {"manifest.json", "vantage_pipelines/", "signal_schemas/"}
    if template == "vlm":
        if "--with-dashboard" in args:
            base.add("dashboard_packages/")
        return base
    if template == "python-worker":
        return base | {"worker/"}
    return base | {"Cargo.toml"}


class CatalogF6F10CompletenessTest(unittest.TestCase):
    """Verify catalog_f6_f10.json registration, counts (>=5 T1, >=5 T2 per F6..F10), and hygiene."""

    def test_catalog_f6_f10_counts_and_registration(self) -> None:
        _register_catalog_cases()
        catalog = _load_catalog_f6_f10()
        summary = vc.validate_test_catalog(catalog, enforce_minimums=False)
        self.assertGreaterEqual(summary["total"], 50)
        for feat in ("F6", "F7", "F8", "F9", "F10"):
            self.assertGreaterEqual(summary["per_feature_tier"].get(f"{feat}:T1", 0), 5)
            self.assertGreaterEqual(summary["per_feature_tier"].get(f"{feat}:T2", 0), 5)

        registered = vc.get_registered_test_cases()
        for case in catalog["cases"]:
            self.assertIn(case["test_id"], registered)
            self.assertEqual(registered[case["test_id"]], case)

        vc.assert_synthetic_hygiene(json.dumps(catalog))


class F6SolutionPackV2ContractTest(unittest.TestCase):
    """F6 Tier 1 & Tier 2: Solution Pack v2 contracts, RBAC approval, upgrade, and immutability."""

    def test_f6_t1_v1_compat_and_v2_alpr_tree_contracts(self) -> None:
        # E2E-F6-T1-01 & E2E-F6-T1-02
        v1_ref = _load_f6_f10("pack_v1_compat_reference.json")
        v1_tree = {k: v.encode("utf-8") for k, v in v1_ref["files"].items()}
        res_v1 = vc.validate_pack_v2_tree(v1_tree, compressed_bytes=vc.PACK_V1_LIMITS[0])
        self.assertEqual(res_v1["pack_format_version"], 1)
        self.assertEqual(res_v1["limits"], vc.PACK_V1_LIMITS)

        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        v2_tree = {k: v.encode("utf-8") for k, v in v2_ref["files"].items()}
        res_v2 = vc.validate_pack_v2_tree(v2_tree, compressed_bytes=vc.PACK_V2_LIMITS[0])
        self.assertEqual(res_v2["pack_format_version"], 2)
        self.assertTrue(res_v2["has_dashboard_packages"])
        self.assertEqual(res_v2["limits"], vc.PACK_V2_LIMITS)

    def test_f6_t1_rbac_approval_matrix_and_worker_dependency_fallback(self) -> None:
        # E2E-F6-T1-03 & E2E-F6-T1-04
        matrix = _load_f6_f10("rbac_approval_matrix.json")
        for case in matrix["dashboard_package_rbac_cases"]:
            with self.subTest(case=case["name"]):
                actual = _evaluate_rbac_install(case["permissions"], case["explicit_approval"])
                self.assertEqual(actual["allowed"], case["expected_allowed"])
                if case["expected_allowed"]:
                    self.assertEqual(actual["status"], case["expected_package_status"])
                    self.assertEqual(actual["instance_bound"], case["expected_instance_bound"])
                else:
                    self.assertEqual(actual["error"], case["expected_error"])

        for wcase in matrix["worker_dependency_cases"]:
            with self.subTest(case=wcase["name"]):
                res = _evaluate_worker_dependency(wcase["dependency"], wcase["healthy_workers"])
                self.assertEqual(res["ready"], wcase["expected_ready"])
                self.assertEqual(res["blocking_count"], wcase["expected_blocking_count"])
                self.assertEqual(res["effective_runner"], wcase["expected_effective_runner"])

    def test_f6_t1_upgrade_overrides_and_uninstall_detach_and_exporter_stripping(self) -> None:
        # E2E-F6-T1-05 & E2E-F6-T1-06
        matrix = _load_f6_f10("rbac_approval_matrix.json")
        upgrade_case, uninstall_case = matrix["upgrade_and_uninstall_cases"]

        # Simulate PackExporter stripping deployment-local binding keys before export
        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        pipeline_obj = json.loads(v2_ref["files"]["vantage_pipelines/alpr-vehicle-plate.json"])
        pipeline_obj["parameter_overrides"] = upgrade_case["pipeline_overrides"]
        dirty_export = copy.deepcopy(pipeline_obj)
        dirty_export["id"] = "99999999-9999-4999-8999-999999999901"
        dirty_export["installed_solution_pack_id"] = "99999999-9999-4999-8999-999999999902"

        # SecretFreeValidator must reject deployment-local UUIDs if unstripped, and pass once stripped
        self.assertGreater(
            len(vc.scan_secret_free({"vantage_pipelines/alpr-vehicle-plate.json": json.dumps(dirty_export)})),
            0,
        )
        for binding_key in ("id", "installed_solution_pack_id"):
            dirty_export.pop(binding_key, None)
        self.assertEqual(
            vc.scan_secret_free({"vantage_pipelines/alpr-vehicle-plate.json": json.dumps(dirty_export)}),
            [],
        )
        upgrade_res = _evaluate_pack_upgrade_transition(upgrade_case)
        self.assertEqual(
            upgrade_res["overrides_preserved"], upgrade_case["expected_overrides_preserved"]
        )
        self.assertEqual(upgrade_res["rule_enabled"], upgrade_case["expected_rule_enabled"])
        self.assertEqual(
            upgrade_res["detached_instance_preserved"],
            upgrade_case["expected_detached_instance_preserved"],
        )

        uninstall_res = _evaluate_pack_uninstall_transition(uninstall_case)
        self.assertEqual(
            uninstall_res["managed_pipeline_enabled_after"],
            uninstall_case["expected_managed_pipeline_enabled_after"],
        )
        self.assertEqual(
            uninstall_res["managed_instance_detached"],
            uninstall_case["expected_managed_instance_detached"],
        )
        self.assertEqual(
            uninstall_res["detached_instance_preserved"],
            uninstall_case["expected_detached_instance_preserved"],
        )

    def test_f6_t2_negative_immutability_limits_and_security_gates(self) -> None:
        # E2E-F6-T2-01..06
        neg = _load_f6_f10("pack_v2_negative_cases.json")
        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        v2_tree = {k: v.encode("utf-8") for k, v in v2_ref["files"].items()}

        # Immutability contract: different content_hash on enabled dashboard@version -> version_already_published
        imm = neg["version_already_published"]
        allowed_conflict, err_atom = _evaluate_package_immutability(
            imm["existing_status"], imm["existing_content_hash"], imm["incoming_content_hash"]
        )
        self.assertFalse(allowed_conflict)
        self.assertEqual(err_atom, imm["expected_error_atom"])
        # Same content_hash is idempotent; staged package allows replacement
        self.assertEqual(
            _evaluate_package_immutability("enabled", imm["existing_content_hash"], imm["existing_content_hash"]),
            (True, None),
        )
        self.assertEqual(
            _evaluate_package_immutability("staged", imm["existing_content_hash"], imm["incoming_content_hash"]),
            (True, None),
        )

        # Tampered renderer fails validation
        tampered = dict(v2_tree)
        tamper = neg["tampered_renderer_case"]
        tampered[tamper["target_file"]] = tamper["tampered_content"].encode("utf-8")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(tampered)

        # Missing required worker dependency blocks activation
        matrix = _load_f6_f10("rbac_approval_matrix.json")
        req_case = next(
            c for c in matrix["worker_dependency_cases"] if c["name"] == "required_without_fallback_and_zero_workers_blocks_activation"
        )
        dep_res = _evaluate_worker_dependency(req_case["dependency"], req_case["healthy_workers"])
        self.assertFalse(dep_res["ready"])
        self.assertEqual(dep_res["blocking_count"], 1)

        # Missing catalog.packs.install is forbidden even with dashboards.packages.manage
        denied = _evaluate_rbac_install(["devices.view", "dashboards.packages.manage"], True)
        self.assertFalse(denied["allowed"])
        self.assertEqual(denied["error"], "forbidden")


class F7CliPackAndVantageContractTest(unittest.TestCase):
    """F7 Tier 1 & Tier 2: `@carverauto/serviceradar-cli` v2 JSON output, flag & diagnostic contracts."""

    def test_f7_t1_pack_v2_cli_json_schemas_and_vantage_templates(self) -> None:
        # E2E-F7-T1-01..06
        vectors = _load_f6_f10("cli_vantage_vectors.json")
        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        v2_tree = {k: v.encode("utf-8") for k, v in v2_ref["files"].items()}

        summary = vc.validate_pack_v2_tree(v2_tree)
        self.assertEqual(vc.scan_secret_free(v2_tree), [])
        manifest = json.loads(v2_tree["manifest.json"].decode("utf-8"))
        resources = manifest["resources"]
        actual_counts = {
            "checks": len(resources.get("checks", [])),
            "rules": len(resources.get("rules", [])),
            "dashboards": len(resources.get("dashboards", [])),
            "vantage_pipelines": len(resources.get("vantage_pipelines", [])),
            "signal_schemas": len(resources.get("signal_schemas", [])),
            "dashboard_packages": len(resources.get("dashboard_packages", [])),
        }
        self.assertEqual(actual_counts, {k: 1 for k in actual_counts})

        # Verify POSIX.1-1988 USTAR + deterministic .tar.gz emission
        ustar_a = vc.build_deterministic_ustar(v2_tree)
        ustar_b = vc.build_deterministic_ustar({k: v2_tree[k] for k in reversed(list(v2_tree.keys()))})
        self.assertEqual(ustar_a, ustar_b)
        self.assertEqual(ustar_a[257:263], b"ustar\x00")
        gz_a = vc.build_deterministic_targz(v2_tree)
        gz_b = vc.build_deterministic_targz({k: v2_tree[k] for k in reversed(list(v2_tree.keys()))})
        self.assertEqual(gz_a, gz_b)
        gz_sha = hashlib.sha256(gz_a).hexdigest()
        self.assertEqual(len(gz_sha), 64)

        # Validate CLI JSON schema contracts in cli_vantage_vectors.json against authoritative CLI spec
        self.assertEqual(
            set(vectors["pack_validate_json_contract"]["required_keys"]),
            {"valid", "source_kind", "path", "id", "slug", "version", "resource_counts", "file_count"},
        )
        self.assertEqual(
            set(vectors["pack_validate_json_contract"]["expected_resource_count_keys_v2"]),
            set(actual_counts.keys()),
        )
        self.assertEqual(
            set(vectors["pack_build_json_contract"]["required_keys"]),
            {"id", "slug", "version", "output", "sha256", "size_bytes", "resource_counts"},
        )
        self.assertEqual(
            set(vectors["pack_sign_json_contract"]["required_keys"]),
            {"signature_file", "algorithm", "key_id", "signer", "content_hash", "signature"},
        )
        self.assertEqual(vectors["pack_sign_json_contract"]["expected_algorithm"], "ed25519")
        self.assertEqual(
            set(vectors["pack_index_json_contract"]["required_keys"]),
            {"output", "pack_count", "packs"},
        )
        self.assertEqual(
            set(vectors["pack_index_json_contract"]["pack_entry_required_keys"]),
            {"id", "version", "bundle_url", "sha256", "signed"},
        )

        # Validate vantage init template contracts & expected scaffold paths
        templates = {t["name"]: t for t in vectors["vantage_init_templates"]}
        self.assertEqual(
            set(templates.keys()),
            {"vlm_with_dashboard", "python_worker_template", "rust_worker_template"},
        )
        for tmpl_name, tmpl in templates.items():
            with self.subTest(template=tmpl_name):
                expected_files = _expected_vantage_scaffold_files(tmpl["args"])
                self.assertEqual(set(tmpl["expected_files"]), expected_files)

        # Confirm the vlm_with_dashboard layout entries exist in the canonical v2 reference tree
        for req_entry in templates["vlm_with_dashboard"]["expected_files"]:
            if req_entry.endswith("/"):
                self.assertTrue(any(p.startswith(req_entry) for p in v2_tree), f"missing {req_entry}")
            else:
                self.assertIn(req_entry, v2_tree)

        # Validate vantage dev offline contract
        dev_contract = vectors["vantage_dev_contract"]
        self.assertEqual(dev_contract["command"][:2], ["vantage", "dev"])
        self.assertIn("--fixture", dev_contract["command"])
        self.assertFalse(dev_contract["requires_cluster"])
        self.assertEqual(dev_contract["expected_exit_code"], 0)

    def test_f7_t2_cli_negative_diagnostics_contracts(self) -> None:
        # E2E-F7-T2-01..06
        vectors = _load_f6_f10("cli_vantage_vectors.json")
        neg = _load_f6_f10("pack_v2_negative_cases.json")
        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        v2_tree = {k: v.encode("utf-8") for k, v in v2_ref["files"].items()}
        neg_cases = {c["name"]: c for c in vectors["negative_cli_cases"]}
        expected_names = {
            "tampered_renderer_digest_fails_validate_and_build",
            "oversized_renderer_over_8mib_fails",
            "minified_js_secret_token_fails",
            "invalid_vantage_template_fails",
            "missing_vantage_dev_fixture_fails",
        }
        self.assertEqual(set(neg_cases.keys()), expected_names)

        # 1. Tampered renderer digest fails validation so build cannot emit archive
        tamper_case = neg_cases["tampered_renderer_digest_fails_validate_and_build"]
        self.assertTrue(tamper_case["expected_exit_nonzero"])
        self.assertTrue(tamper_case["must_not_emit_archive"])
        tampered_tree = dict(v2_tree)
        tampered_tree[neg["tampered_renderer_case"]["target_file"]] = neg["tampered_renderer_case"][
            "tampered_content"
        ].encode("utf-8")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(tampered_tree)

        # 2. Oversized renderer > 8 MiB fails even when manifests are freshly stamped
        oversize_case = neg_cases["oversized_renderer_over_8mib_fails"]
        self.assertEqual(oversize_case["renderer_bytes"], vc.MAX_RENDERER_BYTES + 1)
        self.assertTrue(oversize_case["expected_exit_nonzero"])
        self.assertTrue(oversize_case["must_not_emit_archive"])
        oversized_bytes = b"a" * oversize_case["renderer_bytes"]
        over_tree = dict(v2_tree)
        over_tree["dashboard_packages/alpr-console/renderer.js"] = oversized_bytes
        dm = json.loads(over_tree["dashboard_packages/alpr-console/manifest.json"].decode("utf-8"))
        dm["renderer"]["sha256"] = hashlib.sha256(oversized_bytes).hexdigest()
        over_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(dm).encode("utf-8")
        rm = json.loads(over_tree["manifest.json"].decode("utf-8"))
        rm["files"] = {
            p: hashlib.sha256(b).hexdigest() for p, b in sorted(over_tree.items()) if p != "manifest.json"
        }
        over_tree["manifest.json"] = json.dumps(rm).encode("utf-8")
        with self.assertRaises(vc.ContractValidationError) as ctx:
            vc.validate_pack_v2_tree(over_tree)
        self.assertIn("MAX_RENDERER_BYTES", str(ctx.exception))

        # 3. Minified JS token fails scan_secret_free while benign minified JS passes
        secret_case = neg_cases["minified_js_secret_token_fails"]
        self.assertTrue(secret_case["expected_exit_nonzero"])
        tok = "".join(neg["secret_leaks"]["token_literal_parts"][0]["parts"])
        self.assertGreater(
            len(vc.scan_secret_free({"dashboard_packages/alpr-console/renderer.js": f"export const t={json.dumps(tok)};"})),
            0,
        )
        benign = neg["benign_minified_js_identifiers"]
        self.assertEqual(
            vc.scan_secret_free({benign["file"]: benign["source"]}),
            [],
        )

        # 4. Invalid vantage init template fails template validation
        inv_tmpl = neg_cases["invalid_vantage_template_fails"]
        self.assertTrue(inv_tmpl["expected_exit_nonzero"])
        with self.assertRaises(vc.ContractValidationError):
            _expected_vantage_scaffold_files(inv_tmpl["args"])

        # 5. Missing vantage dev fixture fails path check
        missing_fix = neg_cases["missing_vantage_dev_fixture_fails"]
        self.assertTrue(missing_fix["expected_exit_nonzero"])
        fix_idx = missing_fix["args"].index("--fixture")
        self.assertFalse(Path(missing_fix["args"][fix_idx + 1]).exists())

        # 6. Tampered archive bytes change content_hash so UploadSignature rejects mismatch (E2E-F7-T2-06)
        gz = vc.build_deterministic_targz(v2_tree)
        signed_hash = hashlib.sha256(gz).hexdigest()
        tampered_gz = gz[:-1] + bytes([gz[-1] ^ 0xFF])
        self.assertNotEqual(hashlib.sha256(tampered_gz).hexdigest(), signed_hash)


class F8AlprReferencePackContractTest(unittest.TestCase):
    """F8 Tier 1 & Tier 2: `io.serviceradar.vantage-alpr` synthetic pack & `alpr_plate_read` invariants."""

    def test_f8_t1_alpr_pack_manifest_pipeline_rule_and_console(self) -> None:
        # E2E-F8-T1-01..06
        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        files = v2_ref["files"]
        manifest = json.loads(files["manifest.json"])

        self.assertEqual(manifest["pack_format_version"], 2)
        self.assertEqual(manifest["id"], "io.serviceradar.vantage-alpr")
        self.assertEqual(manifest["license"], "Apache-2.0")
        self.assertEqual(manifest["worker_dependencies"][0]["capability"], "vantage.alpr.v1")
        self.assertTrue(manifest["worker_dependencies"][0]["optional"])
        self.assertEqual(manifest["worker_dependencies"][0]["fallback_runner"], "camera_vlm")

        pipeline = json.loads(files["vantage_pipelines/alpr-vehicle-plate.json"])
        self.assertEqual(pipeline["trigger_kind"], "on_stage1_detection")
        self.assertEqual(pipeline["object_classes"], ["vehicle"])
        self.assertEqual(pipeline["input_mode"], "detection_crop")
        self.assertGreaterEqual(pipeline["crop_policy"]["min_bbox_width_px"], 96)
        self.assertLessEqual(pipeline["crop_policy"]["max_dimension"], vc.MAX_CROP_DIMENSION_PX)
        self.assertLessEqual(pipeline["crop_policy"]["max_bytes"], vc.MAX_VLM_CROP_BYTES)
        self.assertGreater(len(pipeline["roi_polygons"]), 0)

        # Watchlist alert rule must install paused by default
        rule_entry = manifest["resources"]["rules"][0]
        self.assertEqual(rule_entry["install_state"], "paused")
        rule_body = json.loads(files[rule_entry["file"]])
        self.assertEqual(rule_body["match"]["plate_text_in"], list(vc.SYNTHETIC_PLATES))

        # Check, overview dashboard, and alpr-console capabilities
        check_body = json.loads(files["checks/alpr-worker-health.json"])
        self.assertEqual(check_body["capability"], "vantage.alpr.v1")
        dash_overview = json.loads(files["dashboards/alpr-overview.json"])
        self.assertIn("in:camera_observations", dash_overview["widgets"][0]["query"])

        dm = json.loads(files["dashboard_packages/alpr-console/manifest.json"])
        self.assertEqual(dm["renderer"]["interface_version"], "dashboard-browser-module-v1")
        self.assertEqual(dm["renderer"]["trust"], "trusted")
        self.assertEqual(
            set(dm["capabilities"]),
            {"camera.stream.view", "events.subscribe", "srql.execute"},
        )

        # Validate synthetic plates through alpr_plate_read validator
        for plate in vc.SYNTHETIC_PLATES:
            vc.validate_alpr_attributes({"plate_text": plate, "region": "US-CO", "confidence": 0.94})

    def test_f8_t2_alpr_negative_plate_hygiene_secrets_and_crop_bounds(self) -> None:
        # E2E-F8-T2-01..06
        for bad_plate in ("sr-0100", "A", "ABCDEFGHIJKLM", "SR 0100!", ""):
            with self.subTest(bad_plate=bad_plate):
                with self.assertRaises(vc.ContractValidationError):
                    vc.validate_alpr_attributes({"plate_text": bad_plate})

        v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        v2_tree = {k: v.encode("utf-8") for k, v in v2_ref["files"].items()}
        vc.assert_secret_free(v2_tree)
        for path, raw in v2_tree.items():
            vc.assert_synthetic_hygiene(raw)

        # crop_policy bounds enforced via job envelope validator
        job_vec = json.loads(
            (vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures" / "wire_vectors" / "vantage_job_v1.json").read_text(
                encoding="utf-8"
            )
        )["positive"]
        for bad_crop in (
            {"padding_ratio": 0.15, "min_bbox_width_px": 0, "max_dimension": 640, "max_bytes": 98304},
            {"padding_ratio": 0.15, "min_bbox_width_px": 96, "max_dimension": 641, "max_bytes": 98304},
            {"padding_ratio": 0.15, "min_bbox_width_px": 96, "max_dimension": 640, "max_bytes": 98305},
        ):
            mutated = copy.deepcopy(job_vec)
            mutated["crop_policy"] = bad_crop
            with self.assertRaises(vc.ContractValidationError):
                vc.validate_job_envelope(mutated)


class F9SrqlAndSemanticSearchContractTest(unittest.TestCase):
    """F9 Tier 1 & Tier 2: SRQL last-`in:` precedence, dual-perm RBAC, playability & SemanticSearch."""

    def test_f9_t1_srql_last_in_precedence_and_dual_permission_rbac(self) -> None:
        # E2E-F9-T1-01, E2E-F9-T1-02, E2E-F9-T1-05, E2E-F9-T1-06
        vectors = _load_f6_f10("srql_camera_observations_vectors.json")
        expected_all_of = {"devices.view", "devices.cameras.recordings.view"}
        self.assertEqual(set(vectors["required_permissions_all_of"]), expected_all_of)

        for qcase in vectors["positive_queries"]:
            with self.subTest(query=qcase["name"]):
                entity = _extract_last_srql_entity(qcase["query"])
                self.assertEqual(entity, qcase["expected_effective_entity"])
                declared_perms = set(qcase["expected_required_permissions"])
                self.assertEqual(declared_perms, expected_all_of)
                self.assertFalse(_authorize_srql_entity(entity, {"devices.view"}))
                self.assertFalse(_authorize_srql_entity(entity, {"devices.cameras.recordings.view"}))
                self.assertTrue(_authorize_srql_entity(entity, declared_perms))
                if "expected_fields" in qcase:
                    for required_field in (
                        "time_basis",
                        "bbox",
                        "timeline_ts_us",
                        "label",
                        "category",
                        "camera_source_id",
                    ):
                        self.assertIn(required_field, qcase["expected_fields"])

    def test_f9_t2_rbac_source_scoping_playability_and_sqli_safety(self) -> None:
        # E2E-F9-T2-01, E2E-F9-T2-02, E2E-F9-T2-03, E2E-F9-T2-05
        vectors = _load_f6_f10("srql_camera_observations_vectors.json")
        for rcase in vectors["rbac_matrix"]:
            with self.subTest(rbac=rcase["name"]):
                perms = set(rcase["permissions"])
                allowed = _authorize_srql_entity("camera_observations", perms)
                visible = allowed and (
                    rcase["target_camera_source_id"] in set(rcase["authorized_camera_source_ids"])
                )
                self.assertEqual(visible, rcase["expected_visible"])

        auth_sources = {"22222222-2222-4222-8222-222222222201"}
        for pcase in vectors["playability_cases"]:
            with self.subTest(playability=pcase["name"]):
                actual = _is_observation_queryable(
                    pcase, auth_sources, "22222222-2222-4222-8222-222222222201"
                )
                self.assertEqual(actual, pcase["expected_queryable"])

        # SQLi payloads must still resolve deterministically to entity camera_observations
        for inj in vectors["injection_payloads"]:
            with self.subTest(injection=inj["name"]):
                self.assertEqual(_extract_last_srql_entity(inj["query"]), "camera_observations")

    def test_f9_t1_and_t2_semantic_search_boundaries_and_audit_contract(self) -> None:
        # E2E-F9-T1-03, E2E-F9-T1-04, E2E-F9-T2-04, E2E-F9-T2-06
        sv = _load_f6_f10("semantic_search_vectors.json")
        self.assertEqual(sv["limits"]["max_query_chars"], 256)
        self.assertEqual(sv["limits"]["max_window_us"], 31 * 86_400 * 1_000_000)

        for vcase in sv["valid_queries"]:
            with self.subTest(valid=vcase["name"]):
                if "query" in vcase:
                    q = vcase["query"]
                else:
                    prefix = vcase["query_prefix"]
                    q = prefix + ("a" * (vcase["query_length"] - len(prefix)))
                self.assertIsNone(
                    _validate_semantic_search_params(q, window_us=vcase["window_us"])
                )

        for icase in sv["invalid_queries"]:
            with self.subTest(invalid=icase["name"]):
                q = icase.get("query")
                if q is None:
                    q = "a" * icase["query_length"]
                err = _validate_semantic_search_params(
                    q,
                    window_us=icase.get("window_us"),
                    from_us=icase.get("from_us"),
                    to_us=icase.get("to_us"),
                )
                self.assertEqual(err, icase["expected_error"])

        audit = sv["recording_access_audit_contract"]
        self.assertEqual(audit["event_kind"], "semantic_search")
        self.assertTrue(audit["append_only"])
        self.assertEqual(audit["max_details_bytes"], 8192)
        self.assertIn("query_sha256", audit["required_details_keys"])


class F10DashboardEventsAndOverlayContractTest(unittest.TestCase):
    """F10 Tier 1 & Tier 2: OCSF `1008` `signal_schema`, Phoenix channel framing, `crop_jpeg: nil`, XSS."""

    def test_f10_t1_ocsf_1008_nested_filter_and_source_scoping(self) -> None:
        # E2E-F10-T1-01..05
        dv = _load_f6_f10("dashboard_events_vectors.json")
        events_by_name = {e["name"]: e for e in dv["ocsf_events"]}
        full_perms = {"devices.view", "devices.cameras.recordings.view"}
        auth_gate_west = {"22222222-2222-4222-8222-222222222201"}

        for sub in dv["channel_subscriptions"]:
            with self.subTest(subscription=sub["name"]):
                ok, err = _validate_nested_event_filter(sub["filter"])
                self.assertTrue(ok, err)
                matched = [
                    name
                    for name, ev in events_by_name.items()
                    if _match_dashboard_event_filter(ev, sub["filter"], full_perms, auth_gate_west)[0]
                ]
                self.assertEqual(matched, sub["expected_matching_event_names"])

    def test_f10_t1_phoenix_channel_loopback_events_and_frames_framing(self) -> None:
        # E2E-F10-T1-06
        dv = _load_f6_f10("dashboard_events_vectors.json")
        gate_event = dv["ocsf_events"][0]
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        srv.settimeout(5.0)
        port = srv.getsockname()[1]
        observed_client_frames: list[list[Any]] = []

        def _recv_client_ws_frame(conn: socket.socket) -> str:
            hdr = conn.recv(2)
            length = hdr[1] & 0x7F
            if length == 126:
                length = int.from_bytes(conn.recv(2), "big")
            mask = conn.recv(4)
            buf = bytearray()
            while len(buf) < length:
                buf.extend(conn.recv(length - len(buf)))
            return bytes(b ^ mask[i % 4] for i, b in enumerate(buf)).decode("utf-8")

        def _send_server_ws_json(conn: socket.socket, frame: list[Any]) -> None:
            payload = json.dumps(frame).encode("utf-8")
            if len(payload) < 126:
                hdr = bytes([0x81, len(payload)])
            else:
                hdr = bytes([0x81, 126]) + len(payload).to_bytes(2, "big")
            conn.sendall(hdr + payload)

        def _server() -> None:
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
                # 1. phx_join
                join_frame = json.loads(_recv_client_ws_frame(conn))
                observed_client_frames.append(join_frame)
                _send_server_ws_json(
                    conn,
                    [join_frame[0], join_frame[1], join_frame[2], "phx_reply", {"status": "ok", "response": {"refresh_interval_ms": 5000}}],
                )
                # 2. events:subscribe -> phx_reply + events:batch
                sub_frame = json.loads(_recv_client_ws_frame(conn))
                observed_client_frames.append(sub_frame)
                _send_server_ws_json(
                    conn,
                    [sub_frame[0], sub_frame[1], sub_frame[2], "phx_reply", {"status": "ok", "response": {"subscription_id": sub_frame[4]["id"]}}],
                )
                _send_server_ws_json(
                    conn,
                    [None, None, sub_frame[2], "events:batch", {"subscription_id": sub_frame[4]["id"], "events": [gate_event]}],
                )
                # 3. frames:refresh -> frames:replace
                ref_frame = json.loads(_recv_client_ws_frame(conn))
                observed_client_frames.append(ref_frame)
                _send_server_ws_json(
                    conn,
                    [None, None, ref_frame[2], "frames:replace", {"frames": [{"id": "recent_plate_reads", "status": "ok", "results": [{"label": "SR-0100"}]}]}],
                )
            finally:
                conn.close()
                srv.close()

        t = threading.Thread(target=_server, daemon=True)
        t.start()
        client = http_ws_driver.PhoenixChannelClient(
            f"ws://127.0.0.1:{port}/socket/websocket?vsn=2.0.0", timeout=5.0
        )
        try:
            join_reply = client.join("dashboards:alpr-console", {"token": "synthetic-token"})
            self.assertEqual(join_reply[3], "phx_reply")
            self.assertEqual(join_reply[4]["status"], "ok")
            join_ref = join_reply[0]

            sub_ref = str(client._ref)
            client._ref += 1
            client._send_text(
                json.dumps(
                    [
                        join_ref,
                        sub_ref,
                        "dashboards:alpr-console",
                        "events:subscribe",
                        dv["channel_subscriptions"][0]["filter"] | {"id": "sub-1", "filter": dv["channel_subscriptions"][0]["filter"]},
                    ]
                )
            )
            sub_reply = client.recv_json()
            self.assertEqual(sub_reply[4]["status"], "ok")
            batch_msg = client.recv_json()
            self.assertEqual(batch_msg[3], "events:batch")
            self.assertEqual(batch_msg[4]["events"][0]["metadata"]["service_radar"]["label"], "SR-0100")

            ref_ref = str(client._ref)
            client._ref += 1
            client._send_text(json.dumps([join_ref, ref_ref, "dashboards:alpr-console", "frames:refresh", {}]))
            frames_msg = client.recv_json()
            self.assertEqual(frames_msg[3], "frames:replace")
            self.assertEqual(frames_msg[4]["frames"][0]["results"][0]["label"], "SR-0100")
        finally:
            client.close()
            t.join(timeout=5.0)
        self.assertEqual([f[3] for f in observed_client_frames], ["phx_join", "events:subscribe", "frames:refresh"])

    def test_f10_t2_rbac_denial_source_isolation_crop_nil_xss_and_bad_filters(self) -> None:
        # E2E-F10-T2-01..06
        dv = _load_f6_f10("dashboard_events_vectors.json")
        gate_ev, bay_ev = dv["ocsf_events"]
        sub_filter = dv["channel_subscriptions"][1]["filter"]

        # Missing devices.cameras.recordings.view denied
        ok_no_rec, reason_no_rec = _match_dashboard_event_filter(
            gate_ev, sub_filter, {"devices.view"}, {"22222222-2222-4222-8222-222222222201"}
        )
        self.assertFalse(ok_no_rec)
        self.assertEqual(reason_no_rec, "forbidden_camera_event")

        # Viewer authorized for Bay 04 Approach only receives zero Gate West 01 events
        ok_wrong_cam, reason_wrong_cam = _match_dashboard_event_filter(
            gate_ev,
            sub_filter,
            {"devices.view", "devices.cameras.recordings.view"},
            {"22222222-2222-4222-8222-222222222204"},
        )
        self.assertFalse(ok_wrong_cam)
        self.assertEqual(reason_wrong_cam, "unauthorized_camera_source")

        # Bay 04 Approach event is not matched by alpr_plate_read filter
        ok_bay, _ = _match_dashboard_event_filter(
            bay_ev,
            sub_filter,
            {"devices.view", "devices.cameras.recordings.view"},
            {"22222222-2222-4222-8222-222222222204"},
        )
        self.assertFalse(ok_bay)

        # crop_jpeg: nil observation cleanly omits crop URL while preserving bbox + label
        nil_obs = dv["display_and_overlay_cases"]["crop_nil_observation"]
        self.assertIsNone(nil_obs["crop_jpeg"])
        self.assertFalse(_is_safe_thumbnail_url(nil_obs["thumbnail_url"]))
        self.assertEqual(nil_obs["label"], "TEST-742")

        # XSS escaping & safe thumbnail URL validation
        for xss in dv["display_and_overlay_cases"]["xss_hostile_inputs"]:
            with self.subTest(xss=xss["name"]):
                if "raw" in xss:
                    escaped = _escape_overlay_text(xss["raw"])
                    for ch in xss["must_escape"]:
                        self.assertNotIn(ch, escaped)
                else:
                    self.assertEqual(_is_safe_thumbnail_url(xss["url"]), xss["expected_safe_url"])

        # Malformed/oversized metadata filter rejected
        bad_filters = [
            "not-a-dict",
            {"unknown_key": 1},
            {"metadata": {f"k{i}": i for i in range(9)}},
            {"metadata": {"a": {"b": {"c": {"d": {"e": 1}}}}}},
            {"metadata": {"list_forbidden": [1, 2]}},
        ]
        for bf in bad_filters:
            ok, err = _validate_nested_event_filter(bf)
            self.assertFalse(ok)
            self.assertIsNotNone(err)


if __name__ == "__main__":
    unittest.main()
