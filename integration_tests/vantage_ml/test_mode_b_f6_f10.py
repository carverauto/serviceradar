"""Mode B live cross-component E2E tests for F6-F10 (fail closed when prerequisites absent)."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import struct
import sys
import time
import unittest
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping

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
)


def _fixtures_root() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures"


def _load_f6_f10(filename: str) -> Any:
    path = _fixtures_root() / "f6_f10" / filename
    if not path.is_file():
        raise RuntimeError(f"missing Mode B fixture file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _derive_ws_url(web_url: str) -> str:
    explicit = os.environ.get("SERVICERADAR_E2E_WS_URL", "").strip()
    if explicit:
        return explicit
    parsed = urllib.parse.urlparse(web_url)
    scheme = "wss" if parsed.scheme == "https" else "ws"
    return f"{scheme}://{parsed.netloc}/socket/websocket?vsn=2.0.0"


def _auth_headers(token: str | None = None) -> dict[str, str]:
    tok = (token or os.environ.get("SERVICERADAR_E2E_AUTH_TOKEN", "")).strip()
    if not tok:
        raise RuntimeError(
            "SERVICERADAR_E2E_AUTH_TOKEN is required for authenticated Mode B HTTP/WebSocket API tests"
        )
    return {"Authorization": f"Bearer {tok}"}


def _write_pack_tree(dest_dir: Path, files_map: Mapping[str, str]) -> Path:
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    for rel_path, content in files_map.items():
        target = dest_dir / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return dest_dir


def _restamp_v2_tree(files_map: Mapping[str, str]) -> dict[str, str]:
    """Return a copy of files_map with recomputed renderer & manifest.files SHA-256 digests."""
    updated = dict(files_map)
    renderer_rel = "dashboard_packages/alpr-console/renderer.js"
    dm_rel = "dashboard_packages/alpr-console/manifest.json"
    if renderer_rel in updated and dm_rel in updated:
        dm = json.loads(updated[dm_rel])
        dm["renderer"]["sha256"] = hashlib.sha256(updated[renderer_rel].encode("utf-8")).hexdigest()
        updated[dm_rel] = json.dumps(dm, indent=2) + "\n"
    manifest = json.loads(updated["manifest.json"])
    manifest["files"] = {
        rel: hashlib.sha256(content.encode("utf-8")).hexdigest()
        for rel, content in sorted(updated.items())
        if rel != "manifest.json"
    }
    updated["manifest.json"] = json.dumps(manifest, indent=2) + "\n"
    return updated


def _require_cli_dist() -> Path:
    entrypoint = cli_driver.resolve_cli_entrypoint()
    dist_cli = vc.repo_root() / "js" / "cli" / "dist" / "cli.js"
    if not dist_cli.is_file():
        raise RuntimeError(
            f"serviceradar-cli build artifact missing at {dist_cli} (entrypoint={entrypoint}); "
            "run `npm run build` in js/cli before executing Mode B CLI tests"
        )
    return entrypoint


class DashboardChannelClient(http_ws_driver.PhoenixChannelClient):
    """Local Phoenix Channels v2 helper handling RFC 6455 fragmentation & async pre-join frames."""

    def __init__(
        self,
        ws_url: str,
        *,
        headers: Mapping[str, str] | None = None,
        timeout: float = 10.0,
    ) -> None:
        super().__init__(ws_url, headers=headers, timeout=timeout)
        self._join_refs: dict[str, str] = {}

    def recv_json(self) -> Any:
        fragments: bytearray | None = None
        message_opcode: int | None = None
        while True:
            b0, b1 = self._recv_exact(2)
            fin = bool(b0 & 0x80)
            opcode = b0 & 0x0F
            masked = bool(b1 & 0x80)
            length = b1 & 0x7F
            if length == 126:
                (length,) = struct.unpack("!H", self._recv_exact(2))
            elif length == 127:
                (length,) = struct.unpack("!Q", self._recv_exact(8))
            mask = self._recv_exact(4) if masked else b""
            payload = self._recv_exact(length)
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if opcode == 0x8:
                raise RuntimeError("WebSocket closed by remote peer")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue

            if opcode in (0x1, 0x2):
                if fragments is not None:
                    raise RuntimeError(
                        "received new WebSocket data frame before fragmented message completed"
                    )
                if fin:
                    if opcode == 0x1:
                        return json.loads(payload.decode("utf-8"))
                    continue
                fragments = bytearray(payload)
                message_opcode = opcode
                continue

            if opcode == 0x0:
                if fragments is None or message_opcode is None:
                    raise RuntimeError(
                        "received unexpected WebSocket continuation frame without initial frame"
                    )
                fragments.extend(payload)
                if fin:
                    full_payload = bytes(fragments)
                    full_opcode = message_opcode
                    fragments = None
                    message_opcode = None
                    if full_opcode == 0x1:
                        return json.loads(full_payload.decode("utf-8"))
                    continue

    def join_topic(self, topic: str, payload: Mapping[str, Any] | None = None) -> Any:
        ref = str(self._ref)
        self._ref += 1
        frame = [ref, ref, topic, "phx_join", dict(payload or {})]
        self._send_text(json.dumps(frame))
        reply = self.recv_matching(
            lambda m: (
                len(m) >= 5
                and str(m[1]) == ref
                and m[2] == topic
                and m[3] == "phx_reply"
            )
        )
        if isinstance(reply[4], Mapping) and reply[4].get("status") == "ok":
            self._join_refs[topic] = str(reply[0] if reply[0] is not None else ref)
        return reply

    def push_event(self, topic: str, event: str, payload: Mapping[str, Any] | None = None) -> str:
        ref = str(self._ref)
        self._ref += 1
        join_ref = self._join_refs.get(topic, ref)
        frame = [join_ref, ref, topic, event, dict(payload or {})]
        self._send_text(json.dumps(frame))
        return ref

    def recv_matching(
        self,
        predicate: Callable[[list[Any]], bool],
        *,
        timeout: float = 10.0,
    ) -> list[Any]:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("timed out waiting for matching PhoenixChannelClient frame")
            if self._sock is not None:
                self._sock.settimeout(remaining)
            msg = self.recv_json()
            if isinstance(msg, list) and predicate(msg):
                return msg

    def leave_topic(self, topic: str) -> list[Any]:
        ref = self.push_event(topic, "phx_leave", {})
        return self.recv_matching(
            lambda m: len(m) >= 4 and str(m[1]) == ref and m[3] == "phx_reply"
        )


def _assert_mode_b_prereqs() -> dict[str, Any]:
    """Verify full Mode B toolchain and live service endpoints (fails closed)."""
    return env_probe.probe_mode_b_environment(require_services=True)


def _run_mix_with_env(
    app_dir: str,
    elixir_script: str,
    *,
    extra_env: Mapping[str, str] | None = None,
) -> str:
    env = {"DATABASE_URL": cnpg_driver.require_database_url()}
    if extra_env:
        env.update(extra_env)
    proc = cnpg_driver.run_mix_eval(app_dir, elixir_script, extra_env=env)
    return proc.stdout


class F6LiveSolutionPackV2Test(unittest.TestCase):
    """F6 Mode B: Live Elixir PackArchive, PackManifest, DependencyChecker, Reconciler, PackExporter."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.env = _assert_mode_b_prereqs()
        cls.scratch = env_probe.get_scratch_dir("mode-b-f6")
        cls.v1_ref = _load_f6_f10("pack_v1_compat_reference.json")
        cls.v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        cls.neg = _load_f6_f10("pack_v2_negative_cases.json")
        cls.rbac = _load_f6_f10("rbac_approval_matrix.json")

    def test_f6_live_v1_compat_and_v2_reconcile_rbac_staging_upgrade_uninstall(self) -> None:
        uid = uuid.uuid4().hex[:8]
        v1_dir = _write_pack_tree(self.scratch / f"pack_v1_{uid}", self.v1_ref["files"])

        # Build isolated synthetic v2 v1.0.0 and v1.1.0 pack trees so concurrent/repeated runs stay isolated
        pack_id = f"io.serviceradar.e2e-alpr-{uid}"
        pack_slug = f"e2e-alpr-{uid}"
        dash_pkg_id = f"io.serviceradar.e2e-alpr-console-{uid}"
        detached_slug = f"e2e-alpr-detached-{uid}"
        pipeline_id = f"{pack_id}.vehicle-plate"
        check_slug = f"e2e-alpr-health-{uid}"
        rule_name = f"E2E ALPR Watchlist {uid}"

        def _make_v2_tree(version: str) -> dict[str, str]:
            files = dict(self.v2_ref["files"])
            chk = json.loads(files["checks/alpr-worker-health.json"])
            chk["slug"] = check_slug
            chk["name"] = f"E2E ALPR Worker Health {uid}"
            files["checks/alpr-worker-health.json"] = json.dumps(chk, indent=2) + "\n"

            rule = json.loads(files["rules/alpr-watchlist-alert.json"])
            rule["slug"] = f"e2e-alpr-watchlist-{uid}"
            rule["name"] = rule_name
            files["rules/alpr-watchlist-alert.json"] = json.dumps(rule, indent=2) + "\n"

            dash = json.loads(files["dashboards/alpr-overview.json"])
            dash["slug"] = f"e2e-alpr-overview-{uid}"
            dash["title"] = f"E2E ALPR Overview {uid} v{version}"
            files["dashboards/alpr-overview.json"] = json.dumps(dash, indent=2) + "\n"

            pipe = json.loads(files["vantage_pipelines/alpr-vehicle-plate.json"])
            pipe["pipeline_id"] = pipeline_id
            pipe["version"] = version
            files["vantage_pipelines/alpr-vehicle-plate.json"] = json.dumps(pipe, indent=2) + "\n"

            dm = json.loads(files["dashboard_packages/alpr-console/manifest.json"])
            dm["id"] = dash_pkg_id
            dm["version"] = version
            files["dashboard_packages/alpr-console/manifest.json"] = json.dumps(dm, indent=2) + "\n"
            files["dashboard_packages/alpr-console/renderer.js"] = (
                f'export const MODULE_VERSION = "dashboard-browser-module-v1";\n'
                f'export const PACK_VERSION = "{version}";\n'
                f'export function mountAlprConsole() {{ return {{ plate: "SR-0100" }}; }}\n'
            )

            m = json.loads(files["manifest.json"])
            m["id"] = pack_id
            m["slug"] = pack_slug
            m["version"] = version
            m["resources"]["checks"][0]["slug"] = check_slug
            m["resources"]["checks"][0]["name"] = chk["name"]
            m["resources"]["rules"][0]["name"] = rule_name
            m["resources"]["dashboards"][0]["slug"] = dash["slug"]
            m["resources"]["dashboards"][0]["title"] = dash["title"]
            m["resources"]["vantage_pipelines"][0]["id"] = pipeline_id
            m["resources"]["vantage_pipelines"][0]["slug"] = f"e2e-alpr-pipe-{uid}"
            files["manifest.json"] = json.dumps(m, indent=2) + "\n"
            return _restamp_v2_tree(files)

        v2_100_dir = _write_pack_tree(self.scratch / f"pack_v2_100_{uid}", _make_v2_tree("1.0.0"))
        v2_110_dir = _write_pack_tree(self.scratch / f"pack_v2_110_{uid}", _make_v2_tree("1.1.0"))

        elixir_script = """
        alias ServiceRadar.Actors.SystemActor
        alias ServiceRadar.Camera.VantagePipeline
        alias ServiceRadar.Catalog.{
          DependencyChecker,
          InstalledSolutionPack,
          PackArchive,
          PackExporter,
          PackManifest,
          Reconciler,
          SecretFreeValidator
        }
        alias ServiceRadar.Dashboards.{DashboardInstance, DashboardPackage}
        alias ServiceRadar.Identity.RBAC.Catalog, as: RbacCatalog
        require Ash.Query

        sys_actor = SystemActor.system(:mode_b_f6)
        v1_dir = System.fetch_env!("E2E_V1_DIR")
        v2_100_dir = System.fetch_env!("E2E_V2_100_DIR")
        v2_110_dir = System.fetch_env!("E2E_V2_110_DIR")
        pack_id = System.fetch_env!("E2E_PACK_ID")
        dash_pkg_id = System.fetch_env!("E2E_DASH_PKG_ID")
        detached_slug = System.fetch_env!("E2E_DETACHED_SLUG")
        pipeline_id = System.fetch_env!("E2E_PIPELINE_ID")
        check_slug = System.fetch_env!("E2E_CHECK_SLUG")
        rule_name = System.fetch_env!("E2E_RULE_NAME")

        read_tree = fn dir ->
          Path.wildcard(Path.join(dir, "**/*"), match_dot: false)
          |> Enum.filter(&File.regular?/1)
          |> Map.new(fn p -> {Path.relative_to(p, dir), File.read!(p)} end)
        end

        cleanup = fn ->
          ServiceRadar.Repo.query!("DELETE FROM platform.camera_vantage_pipelines WHERE pipeline_id = $1", [pipeline_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_instances WHERE route_slug = $1 OR pack_id = $2", [detached_slug, pack_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_packages WHERE dashboard_id = $1", [dash_pkg_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.declarative_checks WHERE slug = $1", [check_slug])
          ServiceRadar.Repo.query!("DELETE FROM platform.stateful_alert_rules WHERE name = $1", [rule_name])
          ServiceRadar.Repo.query!("DELETE FROM platform.installed_solution_packs WHERE pack_id = $1", [pack_id])
        end

        cleanup.()

        try do
          # 1. Pack v1 compatibility
          v1_files = read_tree.(v1_dir)
          {:ok, v1_validated} = PackManifest.validate_pack_tree(v1_files, [])
          1 = v1_validated.manifest["pack_format_version"]
          {:ok, v1_tar} = PackArchive.build(v1_files)
          {:ok, extracted_v1} = PackArchive.extract(v1_tar)
          1 = extracted_v1.manifest["pack_format_version"]

          # 2. Pack v2 validation, SecretFreeValidator, archive round-trip & DependencyChecker
          v2_100_files = read_tree.(v2_100_dir)
          {:ok, v2_validated} = PackManifest.validate_pack_tree(v2_100_files, [])
          2 = v2_validated.manifest["pack_format_version"]
          :ok = SecretFreeValidator.validate_pack_tree(v2_100_files)
          {:ok, v2_tar} = PackArchive.build(v2_100_files)
          {:ok, extracted_v2} = PackArchive.extract(v2_tar)
          true = Map.has_key?(extracted_v2.files, "dashboard_packages/alpr-console/renderer.js")

          {:ok, dep_report} = DependencyChecker.check(v2_validated.manifest, [])
          true = dep_report.ready?

          # 3. Stage-only install when caller lacks dashboards.packages.manage
          stage_actor = %{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install"])}
          {:ok, staged_res} = Reconciler.reconcile(v2_100_files, %{}, actor: stage_actor, approve_dashboard_packages: false)
          :staged = staged_res.dashboard_packages["alpr-console"].status

          # 4. Enabled install when caller holds catalog.packs.install + dashboards.packages.manage + approval
          true = RbacCatalog.holds?(MapSet.new(["dashboards.packages.manage"]), "dashboards.packages.manage")
          manage_actor = %{
            id: Ecto.UUID.generate(),
            permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage", "catalog.packs.export"])
          }
          {:ok, enabled_res} = Reconciler.reconcile(v2_100_files, %{}, actor: manage_actor, approve_dashboard_packages: true)
          :enabled = enabled_res.dashboard_packages["alpr-console"].status

          # Set operator parameter_overrides on VantagePipeline and create an operator-detached DashboardInstance (managed: false)
          {:ok, pipe_100} = VantagePipeline.get_by_pipeline_version(pipeline_id, "1.0.0", actor: sys_actor)
          {:ok, _} =
            pipe_100
            |> Ash.Changeset.for_update(:update, %{parameter_overrides: %{"max_jobs_per_minute" => 24}}, actor: sys_actor)
            |> Ash.update(actor: sys_actor)

          {:ok, pkg_100} =
            DashboardPackage
            |> Ash.Query.filter(dashboard_id == ^dash_pkg_id and version == "1.0.0")
            |> Ash.read_one(actor: sys_actor)

          {:ok, _detached} =
            DashboardInstance
            |> Ash.Changeset.for_create(:create, %{
              dashboard_package_id: pkg_100.id,
              name: "Operator Detached ALPR",
              route_slug: detached_slug,
              placement: :dashboard,
              enabled: true,
              pack_id: pack_id,
              pack_version: "1.0.0",
              managed: false
            }, actor: sys_actor)
            |> Ash.create(actor: sys_actor)

          # 5. Live Upgrade 1.0.0 -> 1.1.0 preserves parameter_overrides, paused rule, and detached instance
          v2_110_files = read_tree.(v2_110_dir)
          {:ok, upgrade_res} = Reconciler.reconcile(v2_110_files, %{}, actor: manage_actor, approve_dashboard_packages: true)
          "1.1.0" = upgrade_res.pack_version
          {:ok, pipe_110} = VantagePipeline.get_by_pipeline_version(pipeline_id, "1.1.0", actor: sys_actor)
          24 = pipe_110.parameter_overrides["max_jobs_per_minute"]
          rule_entry = Enum.find(upgrade_res.applied_rules, &(&1.name == rule_name))
          false = rule_entry.record.enabled
          {:ok, detached_after_up} =
            DashboardInstance
            |> Ash.Query.filter(route_slug == ^detached_slug)
            |> Ash.read_one(actor: sys_actor)
          false = detached_after_up.managed
          "1.0.0" = detached_after_up.pack_version

          # 6. Live Uninstall disables managed VantagePipeline and detaches managed DashboardInstance while keeping detached instance
          {:ok, _uninstalled} = Reconciler.uninstall(pack_id, actor: manage_actor)
          {:ok, pipe_after_un} = VantagePipeline.get_by_pipeline_version(pipeline_id, "1.1.0", actor: sys_actor)
          false = pipe_after_un.enabled
          {:ok, detached_after_un} =
            DashboardInstance
            |> Ash.Query.filter(route_slug == ^detached_slug)
            |> Ash.read_one(actor: sys_actor)
          false = detached_after_un.managed
          true = detached_after_un.enabled

          # 7. PackExporter.export_tree/2 with valid spec map strips live bindings and stays secret-free
          raw_check = Jason.decode!(v2_110_files["checks/alpr-worker-health.json"])
          raw_rule = Jason.decode!(v2_110_files["rules/alpr-watchlist-alert.json"])
          raw_dash = Jason.decode!(v2_110_files["dashboards/alpr-overview.json"])
          raw_pipe = Jason.decode!(v2_110_files["vantage_pipelines/alpr-vehicle-plate.json"])
          export_spec = %{
            id: pack_id,
            slug: v2_validated.manifest["slug"],
            name: v2_validated.manifest["name"],
            version: "1.1.0",
            checks: [Map.merge(raw_check, %{"id" => Ecto.UUID.generate(), "credential_secret_id" => Ecto.UUID.generate()})],
            rules: [raw_rule],
            dashboards: [raw_dash],
            vantage_pipelines: [Map.merge(raw_pipe, %{"id" => Ecto.UUID.generate()})]
          }
          {:ok, exported} = PackExporter.export_tree(export_spec, actor: manage_actor)
          :ok = SecretFreeValidator.validate_pack_tree(exported)
          {:ok, _} = PackManifest.validate_pack_tree(exported, [])
          IO.puts("F6_LIVE_OK")
        after
          cleanup.()
        end
        """
        stdout = _run_mix_with_env(
            "elixir/serviceradar_core",
            elixir_script,
            extra_env={
                "E2E_V1_DIR": str(v1_dir),
                "E2E_V2_100_DIR": str(v2_100_dir),
                "E2E_V2_110_DIR": str(v2_110_dir),
                "E2E_PACK_ID": pack_id,
                "E2E_DASH_PKG_ID": dash_pkg_id,
                "E2E_DETACHED_SLUG": detached_slug,
                "E2E_PIPELINE_ID": pipeline_id,
                "E2E_CHECK_SLUG": check_slug,
                "E2E_RULE_NAME": rule_name,
            },
        )
        self.assertIn("F6_LIVE_OK", stdout)

    def test_f6_live_negative_tamper_size_immutability_and_forbidden_fail_closed(self) -> None:
        uid = uuid.uuid4().hex[:8]
        v2_dir = _write_pack_tree(self.scratch / f"pack_v2_neg_{uid}", self.v2_ref["files"])
        tamper = self.neg["tampered_renderer_case"]
        token_lit = "".join(self.neg["secret_leaks"]["token_literal_parts"][0]["parts"])

        # Construct real oversized, traversal, and symlink USTAR archives via vantage_contracts
        oversized_renderer_bytes = b"a" * (vc.MAX_RENDERER_BYTES + 1)
        over_renderer_tree = {k: v.encode("utf-8") for k, v in self.v2_ref["files"].items()}
        over_renderer_tree["dashboard_packages/alpr-console/renderer.js"] = oversized_renderer_bytes
        dm_over = json.loads(
            over_renderer_tree["dashboard_packages/alpr-console/manifest.json"].decode("utf-8")
        )
        dm_over["renderer"]["sha256"] = hashlib.sha256(oversized_renderer_bytes).hexdigest()
        over_renderer_tree["dashboard_packages/alpr-console/manifest.json"] = json.dumps(
            dm_over
        ).encode("utf-8")
        rm_over = json.loads(over_renderer_tree["manifest.json"].decode("utf-8"))
        rm_over["files"] = {
            p: hashlib.sha256(b).hexdigest()
            for p, b in sorted(over_renderer_tree.items())
            if p != "manifest.json"
        }
        over_renderer_tree["manifest.json"] = json.dumps(rm_over).encode("utf-8")
        over_renderer_tar = self.scratch / f"over_renderer_{uid}.tar"
        over_renderer_tar.write_bytes(
            vc.build_deterministic_ustar(over_renderer_tree, max_uncompressed_bytes=120_000_000)
        )

        traversal_tar = self.scratch / f"traversal_{uid}.tar"
        hdr = bytearray(512)
        name_b = b"../escape.json"
        hdr[0 : len(name_b)] = name_b
        hdr[100:108] = b"0000644\x00"
        hdr[108:116] = b"0000000\x00"
        hdr[116:124] = b"0000000\x00"
        hdr[124:136] = b"00000000002\x00"
        hdr[136:148] = b"00000000000\x00"
        hdr[148:156] = b"        "
        hdr[156] = ord("0")
        hdr[257:263] = b"ustar\x00"
        hdr[263:265] = b"00"
        chksum = sum(hdr)
        hdr[148:156] = f"{chksum:06o}\x00 ".encode("ascii")
        traversal_tar.write_bytes(bytes(hdr) + b"{}" + (b"\x00" * 510) + (b"\x00" * 1024))

        symlink_tar = self.scratch / f"symlink_{uid}.tar"
        shdr = bytearray(512)
        sname = b"dashboard_packages/alpr-console/link.js"
        slink = b"../../etc/passwd"
        shdr[0 : len(sname)] = sname
        shdr[100:108] = b"0000777\x00"
        shdr[108:116] = b"0000000\x00"
        shdr[116:124] = b"0000000\x00"
        shdr[124:136] = b"00000000000\x00"
        shdr[136:148] = b"00000000000\x00"
        shdr[148:156] = b"        "
        shdr[156] = ord("2")
        shdr[157 : 157 + len(slink)] = slink
        shdr[257:263] = b"ustar\x00"
        shdr[263:265] = b"00"
        schk = sum(shdr)
        shdr[148:156] = f"{schk:06o}\x00 ".encode("ascii")
        symlink_tar.write_bytes(bytes(shdr) + (b"\x00" * 1024))

        elixir_script = """
        alias ServiceRadar.Actors.SystemActor
        alias ServiceRadar.Catalog.{PackArchive, PackManifest, DependencyChecker, Reconciler, SecretFreeValidator}
        alias ServiceRadar.Dashboards.{DashboardPackage, PackageImport}
        require Ash.Query

        sys_actor = SystemActor.system(:mode_b_f6_neg)
        v2_dir = System.fetch_env!("E2E_V2_DIR")
        tamper_file = System.fetch_env!("E2E_TAMPER_FILE")
        tamper_content = System.fetch_env!("E2E_TAMPER_CONTENT")
        token_lit = System.fetch_env!("E2E_TOKEN_LIT")
        over_renderer_tar = System.fetch_env!("E2E_OVER_RENDERER_TAR")
        traversal_tar = System.fetch_env!("E2E_TRAVERSAL_TAR")
        symlink_tar = System.fetch_env!("E2E_SYMLINK_TAR")
        uid = System.fetch_env!("E2E_UID")

        v2_files =
          Path.wildcard(Path.join(v2_dir, "**/*"), match_dot: false)
          |> Enum.filter(&File.regular?/1)
          |> Map.new(fn p -> {Path.relative_to(p, v2_dir), File.read!(p)} end)

        # 1. Tampered renderer fails validation
        tampered = Map.put(v2_files, tamper_file, tamper_content)
        {:error, _} = PackManifest.validate_pack_tree(tampered, [])

        # 2. Missing catalog.packs.install must fail closed with Forbidden
        denied_actor = %{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view", "dashboards.packages.manage"])}
        {:error, %Ash.Error.Forbidden{}} = Reconciler.reconcile(v2_files, %{}, actor: denied_actor)

        # 3. Required worker_dependencies without healthy worker blocks activation
        req_manifest =
          v2_files["manifest.json"]
          |> Jason.decode!()
          |> Map.put("worker_dependencies", [
            %{
              "capability" => "vantage.alpr.v1",
              "min_protocol_version" => "vantage.worker.v1",
              "optional" => false,
              "fallback_runner" => nil
            }
          ])
        {:ok, req_report} = DependencyChecker.check(req_manifest, [])
        false = req_report.ready?
        1 = req_report.blocking_count

        # 4. Digest verification fails closed on mismatched renderer bytes (bytes first, renderer map second)
        dm = Jason.decode!(v2_files["dashboard_packages/alpr-console/manifest.json"])
        {:error, :digest_mismatch} = PackageImport.verify_artifact_digest("tampered-bytes", dm["renderer"])

        # 5. PackArchive.extract rejects > 8 MiB renderer, > 32 MiB compressed, > 96 MiB uncompressed, ../ traversal, and symlinks
        {:error, _} = PackArchive.extract(File.read!(over_renderer_tar))
        {:error, :compressed_archive_too_large} = PackArchive.extract(:binary.copy(<<0>>, 33_554_433))
        {:error, _} = PackArchive.extract(File.read!(traversal_tar))
        {:error, :symlink_forbidden} = PackArchive.extract(File.read!(symlink_tar))
        over_uncomp_gz = :zlib.gzip(:binary.copy(<<0>>, 100_663_297))
        {:error, :uncompressed_archive_too_large} =
          PackArchive.extract(over_uncomp_gz, max_uncompressed_bytes: 100_663_296)
        big_asset = :binary.copy(<<"A">>, 100_663_297)
        {:error, :uncompressed_archive_too_large} =
          PackArchive.build(Map.put(v2_files, "assets/oversize.bin", big_asset), max_uncompressed_bytes: 100_663_296)

        # 6. SecretFreeValidator rejects literal token and credential_secret_id
        {:error, token_violations} =
          SecretFreeValidator.validate_pack_tree(Map.put(v2_files, "dashboard_packages/alpr-console/renderer.js", "export const a=" <> Jason.encode!(token_lit) <> ";\\n"))
        true = length(token_violations) > 0

        pipe_leak =
          v2_files["vantage_pipelines/alpr-vehicle-plate.json"]
          |> Jason.decode!()
          |> Map.put("credential_secret_id", Ecto.UUID.generate())
          |> Jason.encode!()
        {:error, key_violations} =
          SecretFreeValidator.validate_pack_tree(Map.put(v2_files, "vantage_pipelines/alpr-vehicle-plate.json", pipe_leak))
        true = length(key_violations) > 0

        # 7. version_already_published immutability conflict on enabled DashboardPackage@1.0.0 with different content_hash
        dash_id = "io.serviceradar.e2e-imm-" <> uid
        pack_id = "io.serviceradar.e2e-imm-pack-" <> uid
        try do
          {:ok, pkg} =
            DashboardPackage
            |> Ash.Changeset.for_create(:create, %{
              dashboard_id: dash_id,
              name: "Immutable ALPR Console",
              version: "1.0.0",
              manifest: Map.put(dm, "id", dash_id),
              renderer: dm["renderer"],
              data_frames: dm["data_frames"],
              capabilities: dm["capabilities"],
              settings_schema: dm["settings_schema"],
              content_hash: String.duplicate("1", 64),
              verification_status: "verified"
            }, actor: sys_actor)
            |> Ash.create(actor: sys_actor)
          {:ok, _enabled} = pkg |> Ash.Changeset.for_update(:enable, %{}, actor: sys_actor) |> Ash.update(actor: sys_actor)

          new_renderer = "export function mountAlprConsole() { return { modified: true }; }\\n"
          new_sha = :sha256 |> :crypto.hash(new_renderer) |> Base.encode16(case: :lower)
          conflict_dm =
            dm
            |> Map.put("id", dash_id)
            |> put_in(["renderer", "sha256"], new_sha)
          conflict_files =
            v2_files
            |> Map.put("dashboard_packages/alpr-console/manifest.json", Jason.encode!(conflict_dm))
            |> Map.put("dashboard_packages/alpr-console/renderer.js", new_renderer)
          manifest_obj =
            v2_files["manifest.json"]
            |> Jason.decode!()
            |> Map.put("id", pack_id)
            |> Map.put("slug", "e2e-imm-" <> uid)
          {:ok, _m, stamped_conflict} = PackManifest.refresh_manifest_digests(manifest_obj, conflict_files)
          manage_actor = %{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])}
          {:error, reason} = Reconciler.reconcile(stamped_conflict, %{}, actor: manage_actor, approve_dashboard_packages: true)
          true = reason == :version_already_published or (is_tuple(reason) and elem(reason, 0) == :version_already_published)

          # Confirm existing enabled content_hash was NOT mutated
          {:ok, still_pkg} =
            DashboardPackage
            |> Ash.Query.filter(dashboard_id == ^dash_id and version == "1.0.0")
            |> Ash.read_one(actor: sys_actor)
          true = still_pkg.content_hash == String.duplicate("1", 64)
        after
          ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_packages WHERE dashboard_id = $1", [dash_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.installed_solution_packs WHERE pack_id = $1", [pack_id])
        end

        IO.puts("F6_LIVE_NEG_OK")
        """
        stdout = _run_mix_with_env(
            "elixir/serviceradar_core",
            elixir_script,
            extra_env={
                "E2E_V2_DIR": str(v2_dir),
                "E2E_TAMPER_FILE": tamper["target_file"],
                "E2E_TAMPER_CONTENT": tamper["tampered_content"],
                "E2E_TOKEN_LIT": token_lit,
                "E2E_OVER_RENDERER_TAR": str(over_renderer_tar),
                "E2E_TRAVERSAL_TAR": str(traversal_tar),
                "E2E_SYMLINK_TAR": str(symlink_tar),
                "E2E_UID": uid,
            },
        )
        self.assertIn("F6_LIVE_NEG_OK", stdout)


class F7LiveCliPackAndVantageTest(unittest.TestCase):
    """F7 Mode B: Live `@carverauto/serviceradar-cli` pack v2 & vantage commands."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.env = _assert_mode_b_prereqs()
        _require_cli_dist()
        cls.scratch = env_probe.get_scratch_dir("mode-b-f7")
        cls.v2_ref = _load_f6_f10("pack_v2_alpr_reference.json")
        cls.neg = _load_f6_f10("pack_v2_negative_cases.json")

    def test_f7_live_pack_v2_validate_build_sign_verify_index_and_elixir_extract(self) -> None:
        uid = uuid.uuid4().hex[:8]
        pack_dir = _write_pack_tree(self.scratch / f"vantage-alpr-{uid}", self.v2_ref["files"])
        srpack_path = self.scratch / f"vantage-alpr-1.0.0-{uid}.srpack"
        key_dir = self.scratch / f"keys-{uid}"
        key_dir.mkdir(parents=True, exist_ok=True)
        priv_key = key_dir / "release.ed25519.key"
        pub_key = key_dir / "release.ed25519.pub"
        index_path = self.scratch / f"serviceradar-pack-index-{uid}.json"

        val_proc = cli_driver.run_cli(["pack", "validate", str(pack_dir), "--json"])
        val_json = json.loads(val_proc.stdout)
        self.assertTrue(val_json["valid"])
        self.assertEqual(val_json["id"], "io.serviceradar.vantage-alpr")
        self.assertEqual(val_json["resource_counts"]["vantage_pipelines"], 1)
        self.assertEqual(val_json["resource_counts"]["signal_schemas"], 1)
        self.assertEqual(val_json["resource_counts"]["dashboard_packages"], 1)

        build_proc = cli_driver.run_cli(
            ["pack", "build", str(pack_dir), "-o", str(srpack_path), "--json"]
        )
        build_json = json.loads(build_proc.stdout)
        self.assertEqual(build_json["id"], "io.serviceradar.vantage-alpr")
        self.assertTrue(srpack_path.is_file())

        keygen_proc = cli_driver.run_cli(
            [
                "pack",
                "keygen",
                "--private-key-out",
                str(priv_key),
                "--public-key-out",
                str(pub_key),
                "--key-id",
                "synthetic-key-01",
                "--json",
            ]
        )
        keygen_json = json.loads(keygen_proc.stdout)
        self.assertEqual(keygen_json["algorithm"], "ed25519")
        self.assertTrue(priv_key.is_file())
        self.assertTrue(pub_key.is_file())

        sign_proc = cli_driver.run_cli(
            [
                "pack",
                "sign",
                str(srpack_path),
                "--key",
                str(priv_key),
                "--key-id",
                "synthetic-key-01",
                "--signer",
                "ServiceRadar Synthetic Signer",
                "--json",
            ]
        )
        sign_json = json.loads(sign_proc.stdout)
        self.assertEqual(sign_json["algorithm"], "ed25519")
        sig_file = Path(sign_json["signature_file"])
        self.assertTrue(sig_file.is_file())

        verify_proc = cli_driver.run_cli(
            [
                "pack",
                "verify",
                str(srpack_path),
                "--sig",
                str(sig_file),
                "--public-key",
                str(pub_key),
                "--json",
            ]
        )
        verify_json = json.loads(verify_proc.stdout)
        self.assertTrue(verify_json["verified"])

        idx_proc = cli_driver.run_cli(
            [
                "pack",
                "index",
                str(srpack_path),
                "--out",
                str(index_path),
                "--base-url",
                "https://packages.example.com/",
                "--json",
            ]
        )
        idx_json = json.loads(idx_proc.stdout)
        self.assertEqual(idx_json["pack_count"], 1)

        # Cross-verify CLI .srpack & .sig in Elixir PackArchive + UploadSignature
        elixir_script = """
        alias ServiceRadar.Catalog.{PackArchive, UploadSignature}
        srpack_path = System.fetch_env!("E2E_SRPACK_PATH")
        sig_file = System.fetch_env!("E2E_SIG_FILE")
        pub_key = System.fetch_env!("E2E_PUB_KEY")

        tar_bytes = File.read!(srpack_path)
        content_hash = :sha256 |> :crypto.hash(tar_bytes) |> Base.encode16(case: :lower)
        {:ok, extracted} = PackArchive.extract(tar_bytes)
        manifest = extracted.manifest
        sig = Jason.decode!(File.read!(sig_file))
        pub = String.trim(File.read!(pub_key))
        :ok = UploadSignature.verify(sig, manifest, content_hash, %{sig["key_id"] => pub})
        IO.puts("F7_ELIXIR_EXTRACT_VERIFY_OK")
        """
        stdout = _run_mix_with_env(
            "elixir/serviceradar_core",
            elixir_script,
            extra_env={
                "E2E_SRPACK_PATH": str(srpack_path),
                "E2E_SIG_FILE": str(sig_file),
                "E2E_PUB_KEY": str(pub_key),
            },
        )
        self.assertIn("F7_ELIXIR_EXTRACT_VERIFY_OK", stdout)

    def test_f7_live_vantage_init_validate_and_offline_dev_fixture(self) -> None:
        clip_path = media_gen.generate_synthetic_h264_mp4(
            "f7_vantage_dev_gate_west_01.mp4", duration_s=1, fps=10, scratch_subdir="mode-b-f7"
        )
        work_root = self.scratch / "scaffolds"
        if work_root.exists():
            shutil.rmtree(work_root)
        work_root.mkdir(parents=True, exist_ok=True)

        for name, extra in (
            ("demo-alpr-vlm", ["--template", "vlm", "--with-dashboard"]),
            ("demo-alpr-py", ["--template", "python-worker"]),
            ("demo-alpr-rs", ["--template", "rust-worker"]),
        ):
            cli_driver.run_cli(["vantage", "init", name, *extra], cwd=work_root)
            cli_driver.run_cli(["vantage", "validate", str(work_root / name), "--json"])

        dev_proc = cli_driver.run_cli(
            [
                "vantage",
                "dev",
                str(work_root / "demo-alpr-vlm"),
                "--fixture",
                str(clip_path),
                "--json",
            ]
        )
        dev_out = json.loads(dev_proc.stdout)
        self.assertEqual(dev_out.get("status"), "ok")

    def test_f7_live_negative_tamper_oversize_secret_and_bad_args(self) -> None:
        uid = uuid.uuid4().hex[:8]
        # 1. Tampered renderer fails pack build without emitting .srpack
        tamper_dir = _write_pack_tree(self.scratch / f"pack_tamper_{uid}", self.v2_ref["files"])
        (tamper_dir / "dashboard_packages/alpr-console/renderer.js").write_text(
            "export const tampered = true;\n", encoding="utf-8"
        )
        bad_srpack = self.scratch / f"should_not_exist_{uid}.srpack"
        if bad_srpack.exists():
            bad_srpack.unlink()
        res_tamper = cli_driver.run_cli(
            ["pack", "build", str(tamper_dir), "-o", str(bad_srpack)], check=False
        )
        self.assertNotEqual(res_tamper.returncode, 0)
        self.assertFalse(bad_srpack.exists())

        # 2. > 8 MiB (8_388_609B) renderer fails pack build without emitting .srpack
        oversize_files = dict(self.v2_ref["files"])
        oversize_files["dashboard_packages/alpr-console/renderer.js"] = "a" * (
            vc.MAX_RENDERER_BYTES + 1
        )
        oversize_dir = _write_pack_tree(
            self.scratch / f"pack_oversize_{uid}", _restamp_v2_tree(oversize_files)
        )
        oversize_srpack = self.scratch / f"should_not_exist_over_{uid}.srpack"
        if oversize_srpack.exists():
            oversize_srpack.unlink()
        res_over = cli_driver.run_cli(
            ["pack", "build", str(oversize_dir), "-o", str(oversize_srpack)], check=False
        )
        self.assertNotEqual(res_over.returncode, 0)
        self.assertFalse(oversize_srpack.exists())

        # 3. Benign minified JS identifiers pass pack validate while literal token fails
        benign = self.neg["benign_minified_js_identifiers"]
        benign_files = dict(self.v2_ref["files"])
        benign_files[benign["file"]] = benign["source"]
        benign_dir = _write_pack_tree(
            self.scratch / f"pack_benign_js_{uid}", _restamp_v2_tree(benign_files)
        )
        benign_proc = cli_driver.run_cli(["pack", "validate", str(benign_dir), "--json"])
        self.assertTrue(json.loads(benign_proc.stdout)["valid"])

        secret_files = dict(self.v2_ref["files"])
        token_lit = "".join(self.neg["secret_leaks"]["token_literal_parts"][0]["parts"])
        secret_files["dashboard_packages/alpr-console/renderer.js"] = (
            f"export const a={json.dumps(token_lit)};\n"
        )
        secret_dir = _write_pack_tree(
            self.scratch / f"pack_secret_js_{uid}", _restamp_v2_tree(secret_files)
        )
        res_secret = cli_driver.run_cli(["pack", "validate", str(secret_dir)], check=False)
        self.assertNotEqual(res_secret.returncode, 0)

        # 4. pack verify rejects tampered .srpack and mismatched .sig / wrong key
        good_dir = _write_pack_tree(self.scratch / f"pack_verify_neg_{uid}", self.v2_ref["files"])
        good_srpack = self.scratch / f"verify_neg_{uid}.srpack"
        priv1 = self.scratch / f"k1_{uid}.key"
        pub1 = self.scratch / f"k1_{uid}.pub"
        priv2 = self.scratch / f"k2_{uid}.key"
        pub2 = self.scratch / f"k2_{uid}.pub"
        cli_driver.run_cli(["pack", "build", str(good_dir), "-o", str(good_srpack)])
        cli_driver.run_cli(
            [
                "pack",
                "keygen",
                "--private-key-out",
                str(priv1),
                "--public-key-out",
                str(pub1),
                "--key-id",
                "k1",
            ]
        )
        cli_driver.run_cli(
            [
                "pack",
                "keygen",
                "--private-key-out",
                str(priv2),
                "--public-key-out",
                str(pub2),
                "--key-id",
                "k2",
            ]
        )
        sign_res = json.loads(
            cli_driver.run_cli(
                ["pack", "sign", str(good_srpack), "--key", str(priv1), "--key-id", "k1", "--json"]
            ).stdout
        )
        sig_path = Path(sign_res["signature_file"])

        # Mismatched public key
        res_wrong_key = cli_driver.run_cli(
            ["pack", "verify", str(good_srpack), "--sig", str(sig_path), "--public-key", str(pub2)],
            check=False,
        )
        self.assertNotEqual(res_wrong_key.returncode, 0)

        # Tampered .srpack bytes
        tampered_srpack = self.scratch / f"tampered_archive_{uid}.srpack"
        raw_srpack = bytearray(good_srpack.read_bytes())
        raw_srpack[-1] ^= 0xFF
        tampered_srpack.write_bytes(bytes(raw_srpack))
        res_bad_arc = cli_driver.run_cli(
            [
                "pack",
                "verify",
                str(tampered_srpack),
                "--sig",
                str(sig_path),
                "--public-key",
                str(pub1),
            ],
            check=False,
        )
        self.assertNotEqual(res_bad_arc.returncode, 0)

        # 5. Invalid template and missing dev fixture fail closed
        bad_tmpl = cli_driver.run_cli(
            ["vantage", "init", f"bad-pack-{uid}", "--template", "invalid-tmpl"],
            cwd=self.scratch,
            check=False,
        )
        self.assertNotEqual(bad_tmpl.returncode, 0)
        bad_fix = cli_driver.run_cli(
            ["vantage", "dev", str(good_dir), "--fixture", "/nonexistent/synthetic.mp4"],
            check=False,
        )
        self.assertNotEqual(bad_fix.returncode, 0)


class F8LiveAlprBuiltinPackTest(unittest.TestCase):
    """F8 Mode B: Live `io.serviceradar.vantage-alpr` built-in pack load, reconcile, fallback & upgrade."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.env = _assert_mode_b_prereqs()

    def test_f8_live_builtin_vantage_alpr_load_fallback_reconcile_and_hygiene(self) -> None:
        uid = uuid.uuid4().hex[:8]
        elixir_script = """
        alias ServiceRadar.Actors.SystemActor
        alias ServiceRadar.Camera.{VantagePipeline, VantageWorkerRegistration}
        alias ServiceRadar.Camera.Validations.VantageSignalSchema
        alias ServiceRadar.Catalog.{BuiltinPacks, DependencyChecker, PackManifest, Reconciler, SecretFreeValidator}
        require Ash.Query

        sys_actor = SystemActor.system(:mode_b_f8)
        worker_id = "alpr-e2e-worker-" <> System.fetch_env!("E2E_UID")
        pack_id = "io.serviceradar.vantage-alpr"
        pipe_id = "io.serviceradar.vantage-alpr.vehicle-plate"
        dash_id = "io.serviceradar.alpr-console"

        cleanup = fn ->
          ServiceRadar.Repo.query!("DELETE FROM platform.vantage_worker_registrations WHERE worker_id = $1", [worker_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.camera_vantage_pipelines WHERE pipeline_id = $1", [pipe_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_instances WHERE pack_id = $1", [pack_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_packages WHERE dashboard_id = $1", [dash_id])
          ServiceRadar.Repo.query!("DELETE FROM platform.declarative_checks WHERE slug = 'alpr-worker-health'")
          ServiceRadar.Repo.query!("DELETE FROM platform.stateful_alert_rules WHERE name = 'ALPR Synthetic Watchlist Alert'")
          ServiceRadar.Repo.query!("DELETE FROM platform.installed_solution_packs WHERE pack_id = $1", [pack_id])
        end

        cleanup.()

        try do
          # 1. BuiltinPacks.load_builtin_pack/1 returns %{manifest: manifest, files: files, ...}
          {:ok, %{manifest: manifest, files: files} = pack} = BuiltinPacks.load_builtin_pack("vantage-alpr")
          :ok = SecretFreeValidator.validate_pack_tree(files)
          ^pack_id = manifest["id"]
          2 = manifest["pack_format_version"]
          "Apache-2.0" = manifest["license"]

          # Watchlist alert rule defaults to paused
          [rule_entry] = manifest["resources"]["rules"]
          "paused" = rule_entry["install_state"]

          # 2. Ramp 1 fallback readiness when 0 vantage.alpr.v1 workers exist
          {:ok, dep_report_ramp1} = DependencyChecker.check(manifest, [])
          true = dep_report_ramp1.ready?

          # 3. Ramp 2: VantageWorkerRegistration advertising vantage.alpr.v1
          now = DateTime.utc_now()
          {:ok, _worker} =
            VantageWorkerRegistration
            |> Ash.Changeset.for_create(:upsert_heartbeat, %{
              worker_id: worker_id,
              worker_kind: :external_rust,
              protocol_version: "vantage.worker.v1",
              capabilities: ["vantage.alpr.v1"],
              supported_source_modes: ["recorded_block"],
              execution_backend: "onnx",
              architecture: "arm64",
              model_id: "synthetic-alpr",
              model_version: "1.0.0",
              max_concurrency: 2,
              active_jobs: 0,
              health: :ready,
              last_heartbeat_at: now,
              expires_at: DateTime.add(now, 120, :second)
            }, actor: sys_actor)
            |> Ash.create(actor: sys_actor)

          {:ok, active_workers} = VantageWorkerRegistration.active_for_capability("vantage.alpr.v1", now, actor: sys_actor)
          true = Enum.any?(active_workers, &(&1.worker_id == worker_id))
          {:ok, dep_report_ramp2} = DependencyChecker.check(manifest, [])
          true = dep_report_ramp2.ready?

          # 4. Reconcile v1.0.0 and inspect applied_rules + VantagePipeline attributes
          actor = %{
            id: Ecto.UUID.generate(),
            permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])
          }
          {:ok, result} = Reconciler.reconcile(pack, %{}, actor: actor, approve_dashboard_packages: true)
          alpr_rule =
            Enum.find(result.applied_rules, fn r ->
              r.name in ["alpr-watchlist-alert", "ALPR Synthetic Watchlist Alert"]
            end)
          false = is_nil(alpr_rule)
          false = alpr_rule.record.enabled
          :enabled = result.dashboard_packages["alpr-console"].status

          {:ok, pipe} = VantagePipeline.get_by_pipeline_version(pipe_id, "1.0.0", actor: sys_actor)
          :on_stage1_detection = pipe.trigger_kind
          :detection_crop = pipe.input_mode
          true = pipe.crop_policy["min_bbox_width_px"] >= 96

          # 5. alpr_plate_read rejects invalid plate_text and accepts synthetic SR-0100 / TEST-742
          schema = Jason.decode!(files["signal_schemas/alpr_plate_read.schema.json"])
          :ok = VantageSignalSchema.validate_attributes(%{"plate_text" => "SR-0100", "region" => "US-CO"}, schema)
          :ok = VantageSignalSchema.validate_attributes(%{"plate_text" => "TEST-742"}, schema)
          {:error, _} = VantageSignalSchema.validate_attributes(%{"plate_text" => "sr-0100"}, schema)
          {:error, _} = VantageSignalSchema.validate_attributes(%{"plate_text" => "A"}, schema)
          {:error, _} = VantageSignalSchema.validate_attributes(%{"plate_text" => "SR 0100!"}, schema)

          # 6. Upgrade preserves operator-enabled rule and parameter_overrides; uninstall disables managed pipeline
          {:ok, _enabled_rule} =
            alpr_rule.record
            |> Ash.Changeset.for_update(:update, %{enabled: true, parameter_overrides: %{"enabled" => true}}, actor: sys_actor)
            |> Ash.update(actor: sys_actor)
          {:ok, _tuned_pipe} =
            pipe
            |> Ash.Changeset.for_update(:update, %{parameter_overrides: %{"max_jobs_per_minute" => 30}}, actor: sys_actor)
            |> Ash.update(actor: sys_actor)

          up_manifest = Map.put(manifest, "version", "1.1.0")
          up_pipe =
            files["vantage_pipelines/alpr-vehicle-plate.json"]
            |> Jason.decode!()
            |> Map.put("version", "1.1.0")
            |> Jason.encode!()
          up_dm =
            files["dashboard_packages/alpr-console/manifest.json"]
            |> Jason.decode!()
            |> Map.put("version", "1.1.0")
            |> Jason.encode!()
          up_files =
            files
            |> Map.put("vantage_pipelines/alpr-vehicle-plate.json", up_pipe)
            |> Map.put("dashboard_packages/alpr-console/manifest.json", up_dm)
          {:ok, _m, stamped_up} = PackManifest.refresh_manifest_digests(up_manifest, up_files)
          {:ok, up_res} = Reconciler.reconcile(stamped_up, %{}, actor: actor, approve_dashboard_packages: true)
          up_rule = Enum.find(up_res.applied_rules, &(&1.name == alpr_rule.name))
          true = up_rule.record.enabled
          {:ok, pipe_110} = VantagePipeline.get_by_pipeline_version(pipe_id, "1.1.0", actor: sys_actor)
          30 = pipe_110.parameter_overrides["max_jobs_per_minute"]

          {:ok, _un} = Reconciler.uninstall(pack_id, actor: actor)
          {:ok, pipe_after_un} = VantagePipeline.get_by_pipeline_version(pipe_id, "1.1.0", actor: sys_actor)
          false = pipe_after_un.enabled

          IO.puts("F8_BUILTIN_ALPR_OK")
        after
          cleanup.()
        end
        """
        stdout = _run_mix_with_env(
            "elixir/serviceradar_core",
            elixir_script,
            extra_env={"E2E_UID": uid},
        )
        self.assertIn("F8_BUILTIN_ALPR_OK", stdout)


class F9LiveSrqlAndSemanticSearchTest(unittest.TestCase):
    """F9 Mode B: Live `in:camera_observations` SRQL, RBAC, Source scoping, playability, and SemanticSearch."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.env = _assert_mode_b_prereqs()
        cls.web_url = http_ws_driver.require_web_url()
        cls.srql_vectors = _load_f6_f10("srql_camera_observations_vectors.json")
        cls.search_vectors = _load_f6_f10("semantic_search_vectors.json")

    def _seed_observations_fixture(self) -> dict[str, Any]:
        uid = uuid.uuid4().hex[:8]
        now_us = int(time.time() * 1_000_000)
        elixir_script = """
        alias ServiceRadar.Actors.SystemActor
        alias ServiceRadar.Camera.{RecordingCatalogEntry, Source, StreamProfile, VantageObservation}

        sys_actor = SystemActor.system(:mode_b_f9_seed)
        uid = System.fetch_env!("E2E_UID")
        now_us = String.to_integer(System.fetch_env!("E2E_NOW_US"))
        storage_id = Ecto.UUID.generate()
        now = DateTime.utc_now()

        {:ok, cam_gate} = Source.create_source(%{
          device_uid: "sr:e2e-gate-west-" <> uid,
          vendor: "synthetic",
          vendor_camera_id: "gate-" <> uid,
          display_name: "Gate West 01",
          assigned_agent_id: "agent-synthetic",
          assigned_gateway_id: "gateway-synthetic"
        }, actor: sys_actor)
        {:ok, prof_gate} = StreamProfile.create_profile(%{
          camera_source_id: cam_gate.id,
          profile_name: "main",
          relay_eligible: true
        }, actor: sys_actor)

        {:ok, cam_bay} = Source.create_source(%{
          device_uid: "sr:e2e-bay-04-" <> uid,
          vendor: "synthetic",
          vendor_camera_id: "bay-" <> uid,
          display_name: "Bay 04 Approach",
          assigned_agent_id: "agent-synthetic",
          assigned_gateway_id: "gateway-synthetic"
        }, actor: sys_actor)
        {:ok, prof_bay} = StreamProfile.create_profile(%{
          camera_source_id: cam_bay.id,
          profile_name: "main",
          relay_eligible: true
        }, actor: sys_actor)

        mk_block = fn cam_id, prof_id, tag, local_state, archive_state, q_reason ->
          block_id = Ecto.UUID.generate()
          bkey = :sha256 |> :crypto.hash("b-" <> tag <> "-" <> uid) |> Base.encode16(case: :lower)
          dsha = :sha256 |> :crypto.hash("d-" <> tag <> "-" <> uid) |> Base.encode16(case: :lower)
          isha = :sha256 |> :crypto.hash("i-" <> tag <> "-" <> uid) |> Base.encode16(case: :lower)
          desc = Jason.encode!(%{"version" => 1, "format" => %{"codec" => "avc1.42c00a", "timescale" => 90000}})
          ServiceRadar.Repo.query!(\"\"\"
            INSERT INTO platform.camera_recording_blocks
              (id, block_key, camera_source_id, stream_profile_id, ingest_owner_id, ingest_epoch,
               recorder_claim_id, recorder_epoch, block_sequence, relay_session_id, media_ingest_id,
               storage_id, state, descriptor, descriptor_sha256, reconciliation_state, clock,
               inserted_at, updated_at)
            VALUES
              ($1, $2, $3, $4, $5, 1, $6, 1, 0, $7, $8, $9, 'sealed', $10::jsonb, $11, 'unresolved', '{}'::jsonb, $12, $12)
          \"\"\", [
            Ecto.UUID.dump!(block_id), bkey, Ecto.UUID.dump!(cam_id), Ecto.UUID.dump!(prof_id),
            Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(storage_id), desc, dsha, now
          ])
          entry_id = Ecto.UUID.generate()
          ServiceRadar.Repo.query!(\"\"\"
            INSERT INTO platform.camera_recording_catalog
              (id, recording_block_id, camera_source_id, stream_profile_id, storage_id, block_key,
               media_start_ns, media_end_ns, timeline_start_us, timeline_end_us, time_basis,
               fragment_count, media_bytes, init_sha256, descriptor_sha256, local_state,
               local_state_at, archive_state, archive_state_at, archive_deleted_reason,
               quarantine_reason, quarantine_receipt, quarantined_bytes, sealed_at,
               inserted_at, updated_at)
            VALUES
              ($1, $2, $3, $4, $5, $6, 0, 2000000000, $7, $8, 'received',
               1, 1024, $9, $10, $11, $12, $13, $12, $14,
               $15, $16::jsonb, $17, $12, $12, $12)
          \"\"\", [
            Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(block_id),
            Ecto.UUID.dump!(cam_id), Ecto.UUID.dump!(prof_id),
            Ecto.UUID.dump!(storage_id), bkey,
            now_us - 10_000_000, now_us, isha, dsha,
            local_state, now, archive_state,
            if(archive_state == "deleted", do: "operator", else: nil),
            q_reason,
            if(q_reason, do: Jason.encode!(%{"reason" => q_reason}), else: nil),
            if(q_reason, do: 1024, else: nil)
          ])
          entry_id
        end

        gate_present = mk_block.(cam_gate.id, prof_gate.id, "gate-ok", "present", "not_required", nil)
        gate_quar = mk_block.(cam_gate.id, prof_gate.id, "gate-quar", "quarantined", "not_required", "binding_compromised")
        gate_recl = mk_block.(cam_gate.id, prof_gate.id, "gate-recl", "reclaimed", "deleted", nil)
        bay_present = mk_block.(cam_bay.id, prof_bay.id, "bay-ok", "present", "not_required", nil)

        mk_obs = fn key_tag, cam_id, prof_id, entry_id, source_mode, ts_us, label, plate, schema_id ->
          {:ok, obs} =
            VantageObservation
            |> Ash.Changeset.for_create(:upsert_observation, %{
              observation_key: key_tag <> "-" <> uid,
              pack_id: "io.serviceradar.vantage-alpr",
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              worker_id: "e2e-worker-" <> uid,
              model_id: "synthetic-vlm",
              model_version: "1.0.0",
              catalog_entry_id: entry_id,
              camera_source_id: cam_id,
              stream_profile_id: prof_id,
              source_mode: source_mode,
              timeline_ts_us: ts_us,
              time_basis: :received,
              category: "license_plate",
              label: label,
              confidence: 0.94,
              bbox: %{"x1" => 0.32, "y1" => 0.58, "x2" => 0.48, "y2" => 0.66},
              attributes: %{"plate_text" => plate, "region" => "US-CO"},
              signal_schema_id: schema_id,
              signal_schema_version: "1.0.0",
              display_contract_id: schema_id,
              search_text: plate <> " US-CO Gate West 01 license_plate"
            }, actor: sys_actor)
            |> Ash.create(actor: sys_actor)
          obs.id
        end

        _ = mk_obs.("sr-0100-rec", cam_gate.id, prof_gate.id, gate_present, :recorded_block, now_us - 1_000_000, "SR-0100", "SR-0100", "alpr_plate_read")
        _ = mk_obs.("sr-0100-page", cam_gate.id, prof_gate.id, gate_present, :recorded_block, now_us - 2_000_000, "SR-0100", "SR-0100", "alpr_plate_read")
        _ = mk_obs.("test-742-live", cam_gate.id, prof_gate.id, nil, :live_keyframe_tap, now_us - 500_000, "TEST-742", "TEST-742", "alpr_plate_read")
        _ = mk_obs.("quar-sr-0100", cam_gate.id, prof_gate.id, gate_quar, :recorded_block, now_us - 3_000_000, "QUAR-999", "QUAR-999", "alpr_plate_read")
        _ = mk_obs.("recl-sr-0100", cam_gate.id, prof_gate.id, gate_recl, :recorded_block, now_us - 4_000_000, "RECL-999", "RECL-999", "alpr_plate_read")
        _ = mk_obs.("bay-04-rec", cam_bay.id, prof_bay.id, bay_present, :recorded_block, now_us - 800_000, "BAY-0400", "BAY-0400", "alpr_plate_read")

        IO.puts("__F9_SEED__:" <> Jason.encode!(%{
          "gate_source_id" => cam_gate.id,
          "bay_source_id" => cam_bay.id,
          "gate_present_entry_id" => gate_present
        }))
        """
        stdout = _run_mix_with_env(
            "elixir/serviceradar_core",
            elixir_script,
            extra_env={"E2E_UID": uid, "E2E_NOW_US": str(now_us)},
        )
        for line in reversed(stdout.splitlines()):
            if line.startswith("__F9_SEED__:"):
                return json.loads(line[len("__F9_SEED__:") :])
        raise RuntimeError(f"failed to parse F9 seed output: {stdout!r}")

    def _cleanup_observations_fixture(self, seeded: Mapping[str, Any]) -> None:
        gate_id = str(uuid.UUID(seeded["gate_source_id"]))
        bay_id = str(uuid.UUID(seeded["bay_source_id"]))
        cnpg_driver.run_psql(
            f"""
            DELETE FROM platform.camera_vantage_observations WHERE camera_source_id IN ('{gate_id}', '{bay_id}');
            DELETE FROM platform.camera_vantage_jobs WHERE camera_source_id IN ('{gate_id}', '{bay_id}');
            DELETE FROM platform.camera_recording_catalog WHERE camera_source_id IN ('{gate_id}', '{bay_id}');
            DELETE FROM platform.camera_recording_blocks WHERE camera_source_id IN ('{gate_id}', '{bay_id}');
            DELETE FROM platform.camera_stream_profiles WHERE camera_source_id IN ('{gate_id}', '{bay_id}');
            DELETE FROM platform.camera_sources WHERE id IN ('{gate_id}', '{bay_id}');
            """,
            database_url=cnpg_driver.require_database_url(),
        )

    def test_f9_live_srql_camera_observations_and_last_in_precedence(self) -> None:
        seeded = self._seed_observations_fixture()
        try:
            headers = _auth_headers()
            for qcase in self.srql_vectors["positive_queries"]:
                with self.subTest(query=qcase["name"]):
                    status, _hdrs, raw = http_ws_driver.http_request(
                        "POST",
                        "/api/query",
                        base_url=self.web_url,
                        headers=headers,
                        json_body={"query": qcase["query"]},
                    )
                    self.assertEqual(status, 200, f"POST /api/query failed ({status}): {raw!r}")
                    body = json.loads(raw.decode("utf-8"))
                    self.assertIn("results", body)
                    self.assertGreaterEqual(len(body["results"]), 1, f"expected seeded rows for {qcase['name']}")
                    row = body["results"][0]
                    for field in ("time_basis", "bbox", "timeline_ts_us", "label", "category", "camera_source_id"):
                        self.assertIn(field, row)

            # Verify quarantined & reclaimed+deleted observations are excluded
            status_q, _, raw_q = http_ws_driver.http_request(
                "POST",
                "/api/query",
                base_url=self.web_url,
                headers=headers,
                json_body={"query": "in:camera_observations limit:100"},
            )
            self.assertEqual(status_q, 200)
            all_labels = {r.get("label") for r in json.loads(raw_q.decode("utf-8"))["results"]}
            self.assertIn("SR-0100", all_labels)
            self.assertIn("TEST-742", all_labels)
            self.assertNotIn("QUAR-999", all_labels)
            self.assertNotIn("RECL-999", all_labels)

            # Verify cursor pagination (next_cursor -> disjoint second page -> prev_cursor)
            p1_status, _, p1_raw = http_ws_driver.http_request(
                "POST",
                "/api/query",
                base_url=self.web_url,
                headers=headers,
                json_body={
                    "query": f"in:camera_observations camera_source_id:{seeded['gate_source_id']} sort:timeline_ts_us:desc limit:1",
                    "limit": 1,
                },
            )
            self.assertEqual(p1_status, 200)
            p1_body = json.loads(p1_raw.decode("utf-8"))
            self.assertEqual(len(p1_body["results"]), 1)
            next_cursor = (
                p1_body.get("pagination", {}).get("next_cursor")
                or p1_body.get("next_cursor")
            )
            self.assertTrue(next_cursor, f"missing next_cursor in pagination response: {p1_body!r}")

            p2_status, _, p2_raw = http_ws_driver.http_request(
                "POST",
                "/api/query",
                base_url=self.web_url,
                headers=headers,
                json_body={
                    "query": f"in:camera_observations camera_source_id:{seeded['gate_source_id']} sort:timeline_ts_us:desc limit:1",
                    "limit": 1,
                    "cursor": next_cursor,
                    "direction": "next",
                },
            )
            self.assertEqual(p2_status, 200)
            p2_body = json.loads(p2_raw.decode("utf-8"))
            self.assertEqual(len(p2_body["results"]), 1)
            self.assertNotEqual(p1_body["results"][0]["id"], p2_body["results"][0]["id"])
            prev_cursor = (
                p2_body.get("pagination", {}).get("prev_cursor")
                or p2_body.get("prev_cursor")
            )
            self.assertTrue(prev_cursor, f"missing prev_cursor in page 2 response: {p2_body!r}")

            # Injection payloads must return HTTP 200 (safe parameterized) or 400, never 500
            for inj in self.srql_vectors["injection_payloads"]:
                with self.subTest(injection=inj["name"]):
                    status, _hdrs, raw = http_ws_driver.http_request(
                        "POST",
                        "/api/query",
                        base_url=self.web_url,
                        headers=headers,
                        json_body={"query": inj["query"]},
                    )
                    self.assertIn(status, (200, 400), f"unsafe SQLi status {status}: {raw!r}")
        finally:
            self._cleanup_observations_fixture(seeded)

    def test_f9_live_srql_catalog_and_rbac_source_playability_and_semantic_search(self) -> None:
        seeded = self._seed_observations_fixture()
        try:
            elixir_script = """
            alias ServiceRadarWebNG.Api.Access
            alias ServiceRadarWebNG.SRQL.EntityAccess
            alias ServiceRadarWebNGWeb.SRQL.Catalog, as: SrqlCatalog
            alias ServiceRadar.Camera.{RecordingAccessAudit, SemanticSearch}
            alias ServiceRadar.Actors.SystemActor
            require Ash.Query

            gate_id = System.fetch_env!("E2E_GATE_SOURCE_ID")
            bay_id = System.fetch_env!("E2E_BAY_SOURCE_ID")

            # 1. SRQL Catalog registers camera_observations
            true = Enum.any?(SrqlCatalog.entities(), &(&1.id == "camera_observations"))

            # 2. EntityAccess requires BOTH devices.view and devices.cameras.recordings.view even with in:devices prefix (MapSet!)
            bypass_q = "in:devices in:camera_observations label:SR-0100 limit:25"
            {:error, :forbidden} = EntityAccess.authorize(bypass_q, %{permissions: MapSet.new(["devices.view"])})
            {:error, :forbidden} = EntityAccess.authorize(bypass_q, %{permissions: MapSet.new(["devices.cameras.recordings.view"])})
            :ok = EntityAccess.authorize(bypass_q, %{permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])})

            # 3. Access.execute_query enforces 403 forbidden and Source scoping (Bay 04 Approach sees 0 Gate West 01 rows)
            {:error, :forbidden} = Access.execute_query(%{permissions: MapSet.new(["devices.view"])}, %{"query" => "in:camera_observations limit:10"})
            bay_scope = %{
              user: %{id: Ecto.UUID.generate()},
              permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"]),
              authorized_camera_source_ids: [bay_id]
            }
            {:ok, bay_resp} = Access.execute_query(bay_scope, %{"query" => "in:camera_observations limit:50"})
            false = Enum.any?(bay_resp["results"], &(&1["camera_source_id"] == gate_id))

            # Explicit unauthorized camera_source_id filter must be denied or return 0 Gate West rows
            case Access.execute_query(bay_scope, %{"query" => "in:camera_observations camera_source_id:" <> gate_id <> " limit:10"}) do
              {:error, :forbidden} -> :ok
              {:ok, %{"results" => []}} -> :ok
            end

            # 4. SemanticSearch RBAC & boundary checks (MapSet!)
            no_rec_scope = %{actor: %{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view"])}}
            {:error, %Ash.Error.Forbidden{}} = SemanticSearch.search(%{query: "SR-0100"}, scope: no_rec_scope)

            ok_scope = %{
              actor: %{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])},
              authorized_camera_source_ids: [gate_id]
            }
            {:error, :invalid_query} = SemanticSearch.search(%{query: ""}, scope: ok_scope, loaders: %{skip_db_audit: true})
            {:error, :invalid_query} = SemanticSearch.search(%{query: String.duplicate("a", 257)}, scope: ok_scope, loaders: %{skip_db_audit: true})
            now_us = System.system_time(:microsecond)
            too_wide_from = now_us - (31 * 86_400 * 1_000_000 + 1_000_000)
            {:error, :window_too_large} = SemanticSearch.search(%{query: "SR-0100", from_us: too_wide_from, to_us: now_us}, scope: ok_scope, loaders: %{skip_db_audit: true})

            # 5. Authorized SemanticSearch returns SR-0100 & plate_text:TEST-742 hits and excludes Bay/quarantined/reclaimed
            {:ok, sr_res} = SemanticSearch.search(%{query: "SR-0100"}, scope: ok_scope)
            true = Enum.any?(sr_res.results, &(&1.camera_source_id == gate_id and (&1[:label] == "SR-0100" or get_in(&1, [:attributes, "plate_text"]) == "SR-0100")))
            {:ok, attr_res} = SemanticSearch.search(%{query: "plate_text:TEST-742"}, scope: ok_scope)
            true = Enum.any?(attr_res.results, &(&1.camera_source_id == gate_id))

            # Bay 04 scope sees 0 Gate West 01 hits
            {:ok, bay_search} = SemanticSearch.search(%{query: "SR-0100"}, scope: Map.put(ok_scope, :authorized_camera_source_ids, [bay_id]), loaders: %{skip_db_audit: true})
            false = Enum.any?(bay_search.results, &(&1.camera_source_id == gate_id))

            # 6. RecordingAccessAudit (event_kind: :semantic_search) persisted + append-only trigger rejects UPDATE/DELETE
            sys_actor = SystemActor.system(:mode_b_f9_audit)
            actor_id_str = ok_scope.actor.id
            {:ok, audits} =
              RecordingAccessAudit
              |> Ash.Query.filter(actor_id == ^actor_id_str and event_kind == :semantic_search)
              |> Ash.read(actor: sys_actor)
            true = length(audits) >= 1
            audit_id = hd(audits).id
            true = is_binary(hd(audits).details["query_sha256"])

            {:error, %Postgrex.Error{}} =
              ServiceRadar.Repo.query("UPDATE platform.camera_recording_access_audits SET actor_id = 'tampered' WHERE id = $1", [Ecto.UUID.dump!(audit_id)])
            {:error, %Postgrex.Error{}} =
              ServiceRadar.Repo.query("DELETE FROM platform.camera_recording_access_audits WHERE id = $1", [Ecto.UUID.dump!(audit_id)])

            IO.puts("F9_LIVE_ELIXIR_OK")
            """
            stdout = _run_mix_with_env(
                "elixir/web-ng",
                elixir_script,
                extra_env={
                    "E2E_GATE_SOURCE_ID": seeded["gate_source_id"],
                    "E2E_BAY_SOURCE_ID": seeded["bay_source_id"],
                },
            )
            self.assertIn("F9_LIVE_ELIXIR_OK", stdout)

            # Verify /api/cameras/search authorized request and boundary 400s
            headers = _auth_headers()
            status_ok, hdrs_ok, raw_ok = http_ws_driver.http_request(
                "GET",
                "/api/cameras/search?q=SR-0100",
                base_url=self.web_url,
                headers=headers,
            )
            self.assertEqual(status_ok, 200, f"GET /api/cameras/search failed: {raw_ok!r}")
            self.assertEqual(hdrs_ok.get("cache-control"), "private, no-store")

            status_400, _hdrs_400, _raw_400 = http_ws_driver.http_request(
                "GET",
                "/api/cameras/search?q=" + ("a" * 257),
                base_url=self.web_url,
                headers=headers,
            )
            self.assertEqual(status_400, 400)
        finally:
            self._cleanup_observations_fixture(seeded)


class F10LiveDashboardEventsAndUiTest(unittest.TestCase):
    """F10 Mode B: Live `DashboardFrameChannel` nested `signal_schema` + RBAC and `CameraLive.Recordings`."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.env = _assert_mode_b_prereqs()
        cls.web_url = http_ws_driver.require_web_url()
        cls.dv = _load_f6_f10("dashboard_events_vectors.json")

    def test_f10_live_dashboard_frame_channel_events_subscribe_and_scoping(self) -> None:
        stream_token = os.environ.get("SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN", "").strip()
        route_slug = os.environ.get("SERVICERADAR_E2E_ALPR_DASHBOARD_SLUG", "alpr-console").strip()
        if not stream_token:
            raise RuntimeError(
                "SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN is required for live DashboardFrameChannel tests"
            )

        ws_url = _derive_ws_url(self.web_url)
        topic = f"dashboards:{route_slug}"
        client = DashboardChannelClient(ws_url, headers=_auth_headers(), timeout=10.0)
        try:
            join_reply = client.join_topic(topic, {"token": stream_token})
            self.assertEqual(join_reply[3], "phx_reply")
            self.assertEqual(join_reply[4]["status"], "ok")

            sub_cfg = self.dv["channel_subscriptions"][0]
            sub_ref = client.push_event(
                topic,
                "events:subscribe",
                {"id": sub_cfg["id"], "filter": sub_cfg["filter"]},
            )
            sub_reply = client.recv_matching(
                lambda m: len(m) >= 4 and str(m[1]) == sub_ref and m[3] == "phx_reply"
            )
            self.assertEqual(sub_reply[4]["status"], "ok")

            # Emit matching OCSF 1008 event onto JetStream / PubSub and verify events:batch delivery
            nats_driver.publish_json(
                "events.internal.camera",
                self.dv["ocsf_events"][0],
                msg_id=f"e2e-f10-{uuid.uuid4().hex}",
            )
            batch_msg = client.recv_matching(
                lambda m: len(m) >= 5 and m[3] == "events:batch", timeout=10.0
            )
            self.assertEqual(batch_msg[4]["subscription_id"], sub_cfg["id"])
            self.assertGreaterEqual(len(batch_msg[4]["events"]), 1)

            # events:unsubscribe drops subscription so subsequent events do not arrive
            unsub_ref = client.push_event(topic, "events:unsubscribe", {"id": sub_cfg["id"]})
            unsub_reply = client.recv_matching(
                lambda m: len(m) >= 4 and str(m[1]) == unsub_ref and m[3] == "phx_reply"
            )
            self.assertEqual(unsub_reply[4]["status"], "ok")

            # Publish a matching alpr_plate_read event and verify zero events:batch deliveries for unsubscribed id
            nats_driver.publish_json(
                "events.internal.camera",
                self.dv["ocsf_events"][0],
                msg_id=f"e2e-f10-unsub-{uuid.uuid4().hex}",
            )
            try:
                unexpected_batch = client.recv_matching(
                    lambda m: (
                        len(m) >= 5
                        and m[3] == "events:batch"
                        and isinstance(m[4], Mapping)
                        and m[4].get("subscription_id") == sub_cfg["id"]
                    ),
                    timeout=1.0,
                )
            except (TimeoutError, socket.timeout, RuntimeError) as exc:
                if isinstance(exc, RuntimeError) and not (
                    "timed out" in str(exc).lower()
                    or isinstance(exc.__cause__, (TimeoutError, socket.timeout))
                ):
                    raise
            else:
                self.fail(
                    f"received unexpected events:batch after events:unsubscribe for {sub_cfg['id']!r}: {unexpected_batch!r}"
                )

            # Reject oversized/invalid metadata filter
            bad_ref = client.push_event(
                topic,
                "events:subscribe",
                {"id": "sub-bad", "filter": {"metadata": {"a": {"b": {"c": {"d": {"e": 1}}}}}}},
            )
            bad_reply = client.recv_matching(
                lambda m: len(m) >= 4 and str(m[1]) == bad_ref and m[3] == "phx_reply"
            )
            self.assertEqual(bad_reply[4]["status"], "error")

            # frames:refresh acknowledged cleanly
            ref_ref = client.push_event(topic, "frames:refresh", {})
            ref_reply = client.recv_matching(
                lambda m: len(m) >= 4 and str(m[1]) == ref_ref and m[3] == "phx_reply"
            )
            self.assertIn(ref_reply[4]["status"], ("ok", "error"))

            client.leave_topic(topic)
        finally:
            client.close()

    def test_f10_live_elixir_events_filter_and_camera_recordings_xss_safety(self) -> None:
        elixir_script = """
        alias ServiceRadarWebNG.Dashboards.FrameRunner
        alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
        alias ServiceRadarWebNGWeb.DashboardFrameChannel
        alias ServiceRadarWebNGWeb.DashboardFrameChannel.Events

        # 1. Nested signal_schema and camera_source_id filter acceptance & RBAC denial
        valid_filter = %{
          "class_uid" => 1008,
          "camera_source_id" => "22222222-2222-4222-8222-222222222201",
          "metadata" => %{"service_radar" => %{"signal_schema" => %{"schema_id" => "alpr_plate_read"}}}
        }
        {:ok, normalized} = Events.normalize_filter(valid_filter)

        no_rec_scope = %{
          actor: %{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view"])},
          permissions: MapSet.new(["devices.view"]),
          authorized_camera_source_ids: []
        }
        {:error, :forbidden} = Events.authorize_filter(normalized, no_rec_scope)

        # 2. camera_source_id-omitted filter still enforces viewer authorized Source scoping
        unscoped_filter = %{
          "class_uid" => 1008,
          "metadata" => %{"service_radar" => %{"signal_schema" => "alpr_plate_read"}}
        }
        {:ok, norm_unscoped} = Events.normalize_filter(unscoped_filter)
        bay_only_scope = %{
          actor: %{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])},
          permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"]),
          authorized_camera_source_ids: ["22222222-2222-4222-8222-222222222204"]
        }
        gate_event = %{
          "id" => "66666666-6666-4666-8666-666666666601",
          "class_uid" => 1008,
          "metadata" => %{
            "service_radar" => %{
              "source_type" => "camera_vantage",
              "camera_source_id" => "22222222-2222-4222-8222-222222222201",
              "signal_schema" => %{"schema_id" => "alpr_plate_read"}
            }
          }
        }
        [] = Events.filter_visible([gate_event], norm_unscoped, bay_only_scope)

        # 3. Denied in:camera_observations data frame returns status: "error" with zero rows
        [denied_frame] =
          FrameRunner.run(
            [%{"id" => "recent_plate_reads", "query" => "in:camera_observations limit:10"}],
            no_rec_scope
          )
        "error" = denied_frame["status"]
        [] = denied_frame["results"]

        # 4. Mid-session RBAC revocation drops subscriptions and emits events:error
        revoked_socket = %Phoenix.Socket{
          joined: true,
          transport_pid: self(),
          serializer: Phoenix.Socket.V2.JSONSerializer,
          topic: "dashboards:alpr-console",
          join_ref: "1",
          assigns: %{
            current_scope: no_rec_scope,
            event_subscriptions: %{"sub-alpr" => normalized},
            events_authorized_at: nil
          }
        }
        {:noreply, post_revoke_socket} =
          DashboardFrameChannel.handle_info({:ocsf_event_rows, [gate_event]}, revoked_socket)
        true = post_revoke_socket.assigns.event_subscriptions == %{}
        receive do
          {:socket_push, :text, payload} ->
            decoded = payload |> IO.iodata_to_binary() |> Jason.decode!()
            ["1", nil, "dashboards:alpr-console", "events:error", %{"reason" => _reason}] = decoded
        after
          500 -> raise "expected events:error push on revoked socket"
        end

        # 5. CameraLive.Recordings / RecordingsComponents scrubber markers, SVG bbox, crop_jpeg: nil, seek=, & XSS escaping
        now_us = 1_700_000_000_000_000
        rendered =
          Phoenix.LiveViewTest.rendered_to_string(
            RecordingsComponents.recordings(%{
              source: %{id: "22222222-2222-4222-8222-222222222201", display_name: "Gate West 01", device_uid: "sr:gate-west-01"},
              items: [],
              next_cursor: nil,
              selected: nil,
              error: nil,
              loading: false,
              timezone: "Etc/UTC",
              can_view_recording_settings: false,
              mode: :timeline,
              can_manage_holds: false,
              can_view_live: true,
              can_edit_detection_zones: false,
              stream_profiles: [],
              live_mode?: false,
              live_tile: nil,
              roi_drawer_open?: false,
              roi_paint_mode: "focus",
              roi_focus_cells: nil,
              roi_ignore_cells: nil,
              roi_saved_focus_cells: nil,
              roi_saved_ignore_cells: nil,
              roi_feedback: nil,
              roi_grid_cols: 12,
              roi_grid_rows: 8,
              timeline_profile_id: "33333333-3333-4333-8333-333333333301",
              timeline_span: "1h",
              timeline_source: "auto",
              timeline_anchored_latest?: true,
              timeline_coverage: %{from_us: now_us - 600_000_000, to_us: now_us + 600_000_000, buckets: [], blocks: [], gaps: []},
              archive_playback_available: false,
              timeline_playlist_path: nil,
              timeline_play_from_us: now_us - 300_000_000,
              timeline_play_to_us: now_us + 300_000_000,
              timeline_playlist_origin_us: nil,
              timeline_seek_offset_seconds: 12.0,
              timeline_highlight_frame_id: nil,
              timeline_search_query: "",
              timeline_search_object_class: "",
              timeline_search_results: [],
              timeline_search_executed?: false,
              timeline_search_error: nil,
              timeline_embedder_unavailable?: false,
              timeline_overlay_detections: [
                %{
                  id: "obs-1",
                  label: "<script>alert(1)</script>SR-0100",
                  bbox: [0.32, 0.58, 0.48, 0.66],
                  confidence: 0.94,
                  crop_jpeg: nil,
                  thumbnail_url: "javascript:alert(1)"
                }
              ],
              timeline_jump_at: "",
              timeline_has_adjacent_window: false,
              timeline_holds: [],
              timeline_event_clips: [],
              timeline_event_markers: [
                %{
                  id: "obs-1",
                  peak_ts_us: now_us,
                  start_us: now_us,
                  timeline_ts_us: now_us,
                  category: :vehicle,
                  label: "<script>alert(1)</script>SR-0100",
                  confidence: 0.94
                }
              ],
              timeline_clips_mode: "all",
              timeline_clips_category: "all",
              timeline_min_confidence: 50,
              timeline_clips_page: 1,
              timeline_clips_total_count: 0,
              timeline_clips_total_pages: 1,
              timeline_clips_counts: %{},
              timeline_selected_clip_id: nil,
              clip_modal: %{
                id: "obs-2",
                camera_name: "Gate West 01",
                category: :vehicle,
                label: "TEST-742",
                playlist_path: nil,
                playlist_origin_us: now_us - 30_000_000,
                play_from_us: now_us - 30_000_000,
                play_to_us: now_us + 30_000_000,
                seek_offset_seconds: 0.0,
                highlight_frame_id: nil,
                overlay_detections: [],
                bbox: [0.4, 0.5, 0.6, 0.65],
                crop_jpeg: nil,
                thumbnail_url: "javascript:alert(1)"
              },
              gaps_page: 1,
              gaps_per_page: 10,
              timeline_manage_drawer_open?: false,
              switcher_cameras: [],
              switcher_search: "",
              switcher_page: 1,
              switcher_total_count: 0,
              switcher_total_pages: 1,
              switcher_open_mobile?: false,
              hold_form: nil
            })
          )
        true = String.contains?(rendered, "SR-0100")
        true = String.contains?(rendered, "TEST-742")
        true = String.contains?(rendered, "camera-clip-playback-modal")
        true = String.contains?(rendered, "semantic-bbox-overlay")
        true = String.contains?(rendered, "camera-timeline-event-marker-0")
        false = String.contains?(rendered, "<script>alert(1)</script>")
        false = String.contains?(rendered, "javascript:alert(1)")

        IO.puts("F10_LIVE_EVENTS_CONTRACT_OK")
        """
        stdout = _run_mix_with_env("elixir/web-ng", elixir_script)
        self.assertIn("F10_LIVE_EVENTS_CONTRACT_OK", stdout)


if __name__ == "__main__":
    unittest.main()
