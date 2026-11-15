#!/usr/bin/env python3
"""Regression gate for pod DNS resolver bounds and 4-dot intra-cluster Service FQDNs.

Enforces OpenSpec change `harden-pod-dns-and-cluster-resolver`:
1. Every chart-managed Deployment, StatefulSet, Job, and CronJob in `helm/serviceradar`
   (all 36 workload manifests across default and gated renders) and the unpacked
   `helm/serviceradar/charts/dgraph` subchart (all 5 workload manifests) renders
   `dnsConfig.options` with `ndots=2`, `timeout=2`, `attempts=2`, `single-request-reopen`.
2. Intra-cluster Service endpoints in rendered ConfigMaps, Jobs, workload environments,
   and `values-demo.yaml` use 4-dot `<service-name>.<ns>.svc.cluster.local` (plus
   `lab-fe-service.starrocks.svc.cluster.local` and `https://kubernetes.default.svc.cluster.local`),
   never bare `<svc>:<port>`, 2-dot `<svc>.<ns>.svc`, or `ExternalName` aliases.
"""

from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml


def _repo_root() -> Path:
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent.parent


REPO_ROOT = _repo_root()
CHART_DIR = REPO_ROOT / "helm" / "serviceradar"
RELEASE = "serviceradar"
NAMESPACE = "sr-dns-test"

EXPECTED_DNS_OPTIONS = [
    {"name": "ndots", "value": "2"},
    {"name": "timeout", "value": "2"},
    {"name": "attempts", "value": "2"},
    {"name": "single-request-reopen"},
]

POD_KINDS = {"Deployment", "StatefulSet", "Job", "CronJob", "DaemonSet", "Pod"}

# Synthetic values enabling every gated workload in helm/serviceradar.
ALL_GATED_OVERRIDES = {
    "otelExporter.enabled": True,
    "archiveReader.enabled": True,
    "archiveReader.revision": "4",
    "archiveReader.configSecretName": "synthetic-archive-reader-cfg",
    "archiveReader.providerSecretName": "synthetic-archive-reader-provider",
    "archiveReader.authSecretName": "synthetic-archive-reader-auth",
    "archiveReader.tlsSecretName": "synthetic-archive-reader-server-tls",
    "archiveReader.client.configSecretName": "synthetic-archive-reader-client-cfg",
    "archiveReader.client.tlsSecretName": "synthetic-archive-reader-client-tls",
    "archiveReader.providerEgress.cidrs": ["192.0.2.90/32"],
    "webNg.archiveStorage.enabled": True,
    "webNg.archiveStorage.revision": "8",
    "webNg.archiveStorage.configSecretName": "synthetic-storage-control-cfg",
    "webNg.archiveStorage.authSecretName": "synthetic-storage-control-auth",
    "webNg.archiveStorage.tlsSecretName": "synthetic-storage-control-tls",
    "webNg.controlPlaneRuntime.media.enabled": True,
    "webNg.controlPlaneRuntime.media.deploymentRef": "11111111-2222-4333-8444-555555555555",
    "webNg.controlPlaneRuntime.media.generation": "3",
    "mediaStorage.enabled": True,
    "mediaStorage.revision": "8",
    "mediaStorage.configSecretName": "synthetic-media-storage-cfg",
    "mediaStorage.providerSecretName": "synthetic-media-storage-provider",
    "mediaStorage.authSecretName": "synthetic-media-storage-auth",
    "mediaStorage.tlsSecretName": "synthetic-media-storage-tls",
    "mediaStorage.providerEgress.cidrs": ["192.0.2.17/32"],
    "bmpCollector.enabled": True,
    "faker.enabled": True,
    "flowCollector.enabled": True,
    "gobgp.enabled": True,
    "k8sInventory.enabled": True,
    "logCollectorTcp.enabled": True,
    "rperfClient.enabled": True,
    "trivySidecar.enabled": True,
    "webrtc.iceCredentials.backend": "static_secret",
    "webrtc.iceCredentials.staticSecret.existingSecretName": "synthetic-turn-shared-secret",
    "webrtc.turnServer.enabled": True,
    "webrtc.turnServer.exposure": "service",
    "webrtc.turnServer.externalHostname": "turn.example.com",
    "nvr.enabled": True,
    "nvr.replicas": 2,
    "nvr.storage.storageClassName": "synthetic-replicated-csi",
    "nvr.storage.storageIds.serviceradar-nvr-0": "00000000-0000-4000-8000-000000000011",
    "nvr.storage.storageIds.serviceradar-nvr-1": "00000000-0000-4000-8000-000000000012",
    "nvr.recovery.existingConfigMap": "synthetic-nvr-recovery",
    "certs.regenerator.enabled": True,
    "checkerTemplates.enabled": True,
    "kv.enabled": True,
    "cnpg.requireClientCert": True,
    "cnpg.clientCAFromCerts": True,
    "cnpg.clientCASecret": "synthetic-cnpg-client-ca",
    "cnpg.extensionUpdate.enabled": True,
    "dgraph.enabled": True,
    "dgraph.alpha.acl.enabled": True,
    "analytics.starrocks.enabled": True,
    "analytics.starrocks.profile": "sharedData",
    "analytics.starrocks.sharedData.secretName": "synthetic-sr-object-store",
    "analytics.starrocks.sharedData.objectStorageBucket": "synthetic-sr-bucket",
    "analytics.starrocks.catalog.enabled": True,
    "analytics.starrocks.catalog.fePasswordSecretName": "synthetic-sr-fe-password",
}


def _render_templates(source_chart: Path, templates: list[str], overrides: dict, release_ns: str = NAMESPACE) -> dict[str, list[dict]]:
    """Render each template via helm-unittest snapshot mode and return {template: [docs]}."""
    binary = Path(os.environ["SERVICERADAR_HELM_UNITTEST_BINARY"]).resolve()
    results: dict[str, list[dict]] = {}
    with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
        chart = Path(tmp) / "chart"
        chart.mkdir()
        for entry in source_chart.iterdir():
            if entry.name in ("tests", "__snapshot__"):
                continue
            dest = chart / entry.name
            if entry.is_dir():
                shutil.copytree(entry, dest)
            elif entry.is_file():
                shutil.copy2(entry, dest)
        tests_dir = chart / "tests"
        tests_dir.mkdir()

        suite = {
            "suite": "render templates",
            "templates": templates,
            "release": {"name": RELEASE, "namespace": release_ns},
            "tests": [
                {
                    "it": tpl,
                    "template": tpl,
                    "set": overrides,
                    "asserts": [{"matchSnapshot": {}}],
                }
                for tpl in templates
            ],
        }
        (tests_dir / "render_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
        env = {k: v for k, v in os.environ.items() if not k.startswith("HELM_")}
        proc = subprocess.run(
            [str(binary), str(chart)],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if proc.returncode != 0:
            raise AssertionError(f"Helm rendering failed for {source_chart}:\n{proc.stdout}\n{proc.stderr}")

        snap_file = tests_dir / "__snapshot__" / "render_test.yaml.snap"
        raw_snaps = yaml.safe_load(snap_file.read_text(encoding="utf-8")) or {}
        for tpl in templates:
            tpl_snaps = raw_snaps.get(tpl, {})
            docs = []
            for _, doc_yaml in sorted(tpl_snaps.items()):
                parsed = yaml.safe_load(doc_yaml)
                if isinstance(parsed, dict) and parsed.get("kind"):
                    docs.append(parsed)
            results[tpl] = docs
    return results


def _pod_spec(doc: dict) -> dict:
    kind = doc["kind"]
    if kind == "Pod":
        return doc["spec"]
    if kind == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return doc["spec"]["template"]["spec"]


def _env_map(doc: dict) -> dict[str, str]:
    pod = _pod_spec(doc)
    envs: dict[str, str] = {}
    for container in (pod.get("initContainers") or []) + (pod.get("containers") or []):
        for item in container.get("env") or []:
            if "value" in item:
                envs[item["name"]] = str(item["value"])
    return envs


class PodDnsAndFqdnTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gated_docs = _render_templates(CHART_DIR, cls.enableable_templates(), ALL_GATED_OVERRIDES)
        cls.default_docs = _render_templates(CHART_DIR, cls.default_enabled_templates(), {})

    @staticmethod
    def default_enabled_templates() -> list[str]:
        return [
            "templates/agent-gateway.yaml",
            "templates/agent.yaml",
            "templates/cert-generator-job.yaml",
            "templates/checker-templates-kv-bootstrap-job.yaml",
            "templates/cnpg-client-ca-secret-job.yaml",
            "templates/core-migrations-job.yaml",
            "templates/core.yaml",
            "templates/datasvc.yaml",
            "templates/dgraph-schema-job.yaml",
            "templates/log-collector.yaml",
            "templates/nats-creds-generator.yaml",
            "templates/nats.yaml",
            "templates/rperf-checker.yaml",
            "templates/secret-generator-job.yaml",
            "templates/serviceradar-config.yaml",
            "templates/tools.yaml",
            "templates/trapd.yaml",
            "templates/web.yaml",
        ]

    @staticmethod
    def enableable_templates() -> list[str]:
        # All 36 pod-bearing templates + config templates that emit documents under ALL_GATED_OVERRIDES.
        return [
            "templates/agent-gateway.yaml",
            "templates/agent.yaml",
            "templates/archive-reader.yaml",
            "templates/bmp-collector.yaml",
            "templates/cert-generator-job.yaml",
            "templates/cert-regenerator-job.yaml",
            "templates/checker-templates-kv-bootstrap-job.yaml",
            "templates/cnpg-client-ca-job.yaml",
            "templates/cnpg-client-ca-secret-job.yaml",
            "templates/cnpg-extension-update-job.yaml",
            "templates/core-migrations-job.yaml",
            "templates/core.yaml",
            "templates/datasvc.yaml",
            "templates/dev/faker.yaml",
            "templates/dgraph-acl-bootstrap-job.yaml",
            "templates/dgraph-schema-job.yaml",
            "templates/flow-collector-bootstrap-job.yaml",
            "templates/flow-collector.yaml",
            "templates/gobgp.yaml",
            "templates/k8s-inventory.yaml",
            "templates/log-collector-tcp.yaml",
            "templates/log-collector.yaml",
            "templates/media-storage.yaml",
            "templates/nats-creds-generator.yaml",
            "templates/nats.yaml",
            "templates/nvr.yaml",
            "templates/rperf-checker.yaml",
            "templates/secret-generator-job.yaml",
            "templates/serviceradar-config.yaml",
            "templates/starrocks-analytics-config.yaml",
            "templates/starrocks-catalog-job.yaml",
            "templates/starrocks-catalog-reader-job.yaml",
            "templates/starrocks-storage-volume-job.yaml",
            "templates/tools.yaml",
            "templates/trapd.yaml",
            "templates/trivy-sidecar.yaml",
            "templates/web.yaml",
            "templates/webrtc-turn-server.yaml",
        ]

    def test_all_36_chart_workloads_render_fixed_pod_dns_config(self):
        missing = []
        workload_templates = set()

        for label, rendered in (("default", self.default_docs), ("gated", self.gated_docs)):
            for tpl, docs in rendered.items():
                for doc in docs:
                    if doc["kind"] not in POD_KINDS:
                        continue
                    workload_templates.add(tpl)
                    pod = _pod_spec(doc)
                    dns_cfg = (pod.get("dnsConfig") or {}).get("options")
                    if dns_cfg != EXPECTED_DNS_OPTIONS:
                        missing.append(f"{label}:{tpl}:{doc['kind']}/{doc['metadata']['name']} -> {dns_cfg}")

        self.assertGreaterEqual(
            len(workload_templates),
            36,
            f"Expected at least 36 pod-bearing templates in helm/serviceradar, saw {len(workload_templates)}: {sorted(workload_templates)}",
        )
        self.assertEqual(
            missing,
            [],
            "Workloads missing fixed serviceradar.podDnsConfig:\n  " + "\n  ".join(missing),
        )

    def test_dgraph_subchart_unpacked_and_pod_dns_config(self):
        dgraph_tgz = CHART_DIR / "charts" / "dgraph-24.1.4.tgz"
        dgraph_dir = CHART_DIR / "charts" / "dgraph"
        self.assertFalse(dgraph_tgz.exists(), "charts/dgraph-24.1.4.tgz must be replaced by unpacked charts/dgraph/")
        self.assertTrue((dgraph_dir / "Chart.yaml").is_file(), "charts/dgraph/Chart.yaml must exist")

        dgraph_templates = [
            "templates/alpha/statefulset.yaml",
            "templates/zero/statefulset.yaml",
            "templates/ratel/deployment.yaml",
            "templates/backups/cronjob-full.yaml",
            "templates/backups/cronjob-inc.yaml",
        ]
        rendered = _render_templates(
            dgraph_dir,
            dgraph_templates,
            {
                "image.tag": "v24.1.4",
                "ratel.enabled": True,
                "backups.full.enabled": True,
                "backups.incremental.enabled": True,
            },
        )
        missing = []
        count = 0
        for tpl, docs in rendered.items():
            for doc in docs:
                if doc["kind"] not in POD_KINDS:
                    continue
                count += 1
                pod = _pod_spec(doc)
                dns_cfg = (pod.get("dnsConfig") or {}).get("options")
                if dns_cfg != EXPECTED_DNS_OPTIONS:
                    missing.append(f"dgraph:{tpl}:{doc['kind']}/{doc['metadata']['name']} -> {dns_cfg}")
                if doc["kind"] == "CronJob":
                    cmd_blob = json.dumps(pod.get("containers") or [])
                    self.assertNotIn(
                        '.svc"',
                        cmd_blob,
                        f"dgraph {tpl} ALPHA_HOST still ends with 2-dot .svc",
                    )

        self.assertGreaterEqual(count, 5, f"Expected all 5 dgraph pod templates to render, got {count}")
        self.assertEqual(missing, [], "Dgraph workloads missing fixed dnsConfig:\n  " + "\n  ".join(missing))

    def test_intra_cluster_endpoints_use_4_dot_fqdns(self):
        cfg_doc = next(d for d in self.gated_docs["templates/serviceradar-config.yaml"] if d["kind"] == "ConfigMap")
        data = cfg_doc["data"]

        core_json = json.loads(data["core.json"])
        self.assertEqual(core_json["nats"]["url"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")
        self.assertEqual(core_json["logging"]["otel"]["endpoint"], f"serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")
        self.assertEqual(
            core_json["edge_onboarding"]["default_metadata"]["gateway"]["kv_address"],
            f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local:50057",
        )
        self.assertEqual(
            core_json["edge_onboarding"]["default_metadata"]["gateway"]["agent_address"],
            f"serviceradar-agent.{NAMESPACE}.svc.cluster.local:50051",
        )

        agent_json = json.loads(data["agent.json"])
        self.assertEqual(agent_json["gateway_addr"], f"serviceradar-agent-gateway.{NAMESPACE}.svc.cluster.local:50052")
        self.assertEqual(agent_json["kv_address"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local:50057")
        self.assertEqual(agent_json["logging"]["otel"]["endpoint"], f"serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")

        datasvc_json = json.loads(data["datasvc.json"])
        self.assertEqual(datasvc_json["nats_url"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")
        self.assertEqual(datasvc_json["logging"]["otel"]["endpoint"], f"serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")

        trapd_json = json.loads(data["trapd.json"])
        self.assertEqual(trapd_json["nats_url"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")
        self.assertEqual(trapd_json["otel"]["endpoint"], f"serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")

        self.assertEqual(
            json.loads(data["rperf-checker.json"])["address"],
            f"serviceradar-rperf-client.{NAMESPACE}.svc.cluster.local:50081",
        )
        self.assertEqual(
            json.loads(data["trapd-checker.json"])["address"],
            f"serviceradar-trapd.{NAMESPACE}.svc.cluster.local:50043",
        )
        self.assertEqual(
            json.loads(data["flowgger-checker.json"])["address"],
            f"serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:50044",
        )
        self.assertEqual(
            json.loads(data["faker.json"])["simulation"]["bgp"]["bmp_collector_address"],
            f"serviceradar-bmp-collector.{NAMESPACE}.svc.cluster.local:11019",
        )
        self.assertIn(f'url = "tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222"', data["otel.toml"])

        # Workload env vars
        core_dep = next(d for d in self.gated_docs["templates/core.yaml"] if d["kind"] == "Deployment")
        core_env = _env_map(core_dep)
        self.assertEqual(core_env["NATS_URL"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")
        self.assertEqual(core_env["DATASVC_HOST"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local")
        self.assertEqual(core_env["OTEL_EXPORTER_OTLP_ENDPOINT"], f"https://serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")
        self.assertEqual(core_env["SERVICERADAR_STARROCKS_FE_HOST"], "lab-fe-service.starrocks.svc.cluster.local")
        self.assertEqual(core_env["SERVICERADAR_STARROCKS_FE_HTTP"], "http://lab-fe-service.starrocks.svc.cluster.local:8030")

        agent_dep = next(d for d in self.gated_docs["templates/agent.yaml"] if d["kind"] == "Deployment")
        self.assertEqual(_env_map(agent_dep)["KV_ADDRESS"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local:50057")

        web_dep = next(d for d in self.gated_docs["templates/web.yaml"] if d["kind"] == "Deployment")
        web_env = _env_map(web_dep)
        self.assertEqual(web_env["NATS_URL"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")
        self.assertEqual(web_env["DATASVC_HOST"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local")
        self.assertEqual(web_env["DATASVC_ADDRESS"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local:50057")
        self.assertEqual(web_env["SERVICERADAR_GATEWAY_ADDR"], f"serviceradar-agent-gateway.{NAMESPACE}.svc.cluster.local:50052")
        self.assertEqual(web_env["OTEL_EXPORTER_OTLP_ENDPOINT"], f"https://serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")

        gw_dep = next(d for d in self.gated_docs["templates/agent-gateway.yaml"] if d["kind"] == "Deployment")
        gw_env = _env_map(gw_dep)
        self.assertEqual(gw_env["AGENT_GATEWAY_NATS_URL"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")
        self.assertEqual(gw_env["DATASVC_HOST"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local")
        self.assertEqual(gw_env["DATASVC_ADDRESS"], f"serviceradar-datasvc.{NAMESPACE}.svc.cluster.local:50057")
        self.assertEqual(gw_env["OTEL_EXPORTER_OTLP_ENDPOINT"], f"https://serviceradar-log-collector.{NAMESPACE}.svc.cluster.local:4317")
        # Ensure CLUSTER_CORE_DNS_QUERY did not double-append .svc.cluster.local
        self.assertEqual(gw_env["CLUSTER_CORE_DNS_QUERY"], f"serviceradar-core-elx-headless.{NAMESPACE}.svc.cluster.local")

        trapd_dep = next(d for d in self.gated_docs["templates/trapd.yaml"] if d["kind"] == "Deployment")
        self.assertEqual(_env_map(trapd_dep)["NATS_HOST"], f"serviceradar-nats.{NAMESPACE}.svc.cluster.local")

        trivy_dep = next(d for d in self.gated_docs["templates/trivy-sidecar.yaml"] if d["kind"] == "Deployment")
        self.assertEqual(_env_map(trivy_dep)["NATS_HOSTPORT"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")

        inv_dep = next(d for d in self.gated_docs["templates/k8s-inventory.yaml"] if d["kind"] == "Deployment")
        self.assertEqual(_env_map(inv_dep)["NATS_HOSTPORT"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")

        tools_dep = next(d for d in self.gated_docs["templates/tools.yaml"] if d["kind"] == "Deployment")
        self.assertEqual(_env_map(tools_dep)["NATS_URL"], f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222")

        # Collector ConfigMaps & StarRocks catalog Job
        fc_cm = next(d for d in self.gated_docs["templates/flow-collector.yaml"] if d["kind"] == "ConfigMap")
        self.assertEqual(
            json.loads(fc_cm["data"]["flow-collector.json"])["nats_url"],
            f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222",
        )
        bmp_cm = next(d for d in self.gated_docs["templates/bmp-collector.yaml"] if d["kind"] == "ConfigMap")
        self.assertEqual(
            json.loads(bmp_cm["data"]["config.json"])["nats_url"],
            f"nats://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222",
        )
        for lc_tpl in ("templates/log-collector.yaml", "templates/log-collector-tcp.yaml"):
            lc_cm = next(d for d in self.gated_docs[lc_tpl] if d["kind"] == "ConfigMap")
            for cm_key, cm_val in lc_cm["data"].items():
                self.assertNotIn("tls://serviceradar-nats:4222", cm_val, f"bare NATS URL in {lc_tpl}:{cm_key}")
                if cm_key in ("flowgger.toml", "otel.toml"):
                    self.assertIn(f"tls://serviceradar-nats.{NAMESPACE}.svc.cluster.local:4222", cm_val)

        gobgp_cm = next(d for d in self.gated_docs["templates/gobgp.yaml"] if d["kind"] == "ConfigMap")
        self.assertIn(f'address = "serviceradar-bmp-collector.{NAMESPACE}.svc.cluster.local"', gobgp_cm["data"]["gobgpd.toml"])

        sr_cat_job = next(d for d in self.gated_docs["templates/starrocks-catalog-job.yaml"] if d["kind"] == "Job")
        self.assertEqual(
            _env_map(sr_cat_job)["JDBC_URI"],
            f"jdbc:postgresql://cnpg-rw.{NAMESPACE}.svc.cluster.local:5432/serviceradar?ssl=true&sslmode=require",
        )

        # Hook Jobs must use 4-dot https://kubernetes.default.svc.cluster.local (zero 2-dot NXDOMAIN walk)
        for hook_tpl in (
            "templates/cert-generator-job.yaml",
            "templates/cert-regenerator-job.yaml",
            "templates/cnpg-client-ca-job.yaml",
            "templates/nats-creds-generator.yaml",
            "templates/secret-generator-job.yaml",
        ):
            job_doc = next(d for d in self.gated_docs[hook_tpl] if d["kind"] == "Job")
            blob = json.dumps(_pod_spec(job_doc))
            self.assertNotRegex(
                blob,
                r"https://kubernetes\.default\.svc(?!\.cluster\.local)",
                f"{hook_tpl} uses 2-dot kubernetes.default.svc instead of 4-dot FQDN",
            )
            self.assertIn("https://kubernetes.default.svc.cluster.local", blob)

        # values-demo.yaml check: no 0-dot or 2-dot intra-cluster URLs
        demo_values = yaml.safe_load((CHART_DIR / "values-demo.yaml").read_text(encoding="utf-8"))
        self.assertEqual(
            demo_values["analytics"]["starrocks"]["catalog"]["jdbcUri"],
            "jdbc:postgresql://cnpg-rw.demo.svc.cluster.local:5432/serviceradar?ssl=true&sslmode=require",
        )
        self.assertEqual(
            demo_values["core"]["extraEnv"]["EVENT_WRITER_NATS_URL"],
            "tls://serviceradar-nats.demo.svc.cluster.local:4222",
        )
        self.assertEqual(
            demo_values["faker"]["simulation"]["bgp"]["gobgpApiAddress"],
            "serviceradar-gobgp.demo.svc.cluster.local:50051",
        )
        self.assertEqual(
            demo_values["faker"]["simulation"]["bgp"]["bmpCollectorAddress"],
            "serviceradar-bmp-collector.demo.svc.cluster.local:11019",
        )
        self.assertIn(
            "--nats-server=nats://serviceradar-nats.demo.svc.cluster.local:4222",
            demo_values["bmpCollector"]["args"],
        )

        # Global anti-regression sweep across all rendered documents: no ExternalName aliases
        # or 2-dot .svc endpoints without .cluster.local.
        full_blob = json.dumps(self.gated_docs)
        self.assertIsNone(
            re.search(r"://(?:nats|kv|core):", full_blob),
            "Rendered manifests must never dial ExternalName aliases nats/kv/core",
        )
        self.assertIsNone(
            re.search(r"[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.svc(?![A-Za-z0-9.-])", full_blob),
            "Rendered manifests contain a 2-dot <svc>.<ns>.svc hostname without .cluster.local",
        )


if __name__ == "__main__":
    unittest.main()
