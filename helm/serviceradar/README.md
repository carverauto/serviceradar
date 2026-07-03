# ServiceRadar Helm Chart

This chart packages the ServiceRadar demo stack for Helm-based installs.

Official chart location (OCI/Harbor):
- Chart: `oci://registry.carverauto.dev/serviceradar/charts/serviceradar`
- ArgoCD repoURL (no `oci://` prefix): `registry.carverauto.dev/serviceradar/charts`

## Installation

### From Published OCI Chart (Recommended)

```bash
helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  --version 1.2.20 \
  -n serviceradar --create-namespace \
  --set global.imageTag="v1.2.20"
```

### From Repository Checkout (Development)

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  -n serviceradar --create-namespace
```

### Hosted Tenant Runtime Baseline

Dedicated hosted tenant clusters use [values-tenant.yaml](values-tenant.yaml)
as the chart baseline rendered by the ServiceRadar control plane. See
[TENANT_RUNTIME.md](TENANT_RUNTIME.md) for the render-validation command and
hosted exposure model.

Optional dev overrides to follow mutable tags on restart:
```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  -n serviceradar --create-namespace \
  --set global.imageTag="latest" \
  --set global.imagePullPolicy="Always"
```

## Architecture

The chart deploys the following components:

| Component | Description | Port |
|-----------|-------------|------|
| Core | Central API and processing service | 8090 (HTTP), 50052 (gRPC) |
| Web-NG | Phoenix LiveView dashboard | 4000 |
| Agent | In-cluster Go agent | 50051 (gRPC) |
| Datasvc | KV store service | - |
| NATS | JetStream messaging | 4222 |
| CNPG | App database cluster | 5432 |
| CNPG PgBouncer Pooler | Optional CNPG-managed connection pooler | 5432 |
| OTEL | Telemetry collector | - |

### Edge Agents

Edge agents (agents running outside the Kubernetes cluster) are Go binaries that communicate with Gateways via gRPC with mTLS. They are **not** deployed by this chart.

To deploy edge agents:
1. Use the onboarding API to generate agent configuration
2. Deploy the Go agent binary to target hosts
3. Agents connect to Gateways via gRPC on port 50052

**Security Model:**
- Edge agents communicate only via gRPC (no ERTS/Erlang distribution)
- Internal service-to-service traffic uses mTLS by default
- Default Kubernetes installs use deployment-managed certificates published into a Kubernetes Secret and mounted into workloads
- SPIFFE/SPIRE remains available as an explicit opt-in mode when operators want workload identities
- Isolation is enforced by deployment boundaries and database credentials

For detailed edge agent deployment, see the [Edge Agent Guide](../docs/docs/edge-agents.md).

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imageTag` | Docker image tag for all first-party components | `v1.2.54` |
| `image.digests.<service>` | Optional digest pin for a first-party component, overriding tags | `{}` |
| `ingress.enabled` | Enable ingress for web UI | `false` |
| `ingress.host` | Hostname for ingress | `""` |
| `ingress.tls.secretName` | TLS secret name | `""` |
| `gatewayApi.syslog.enabled` | Render a Gateway API UDPRoute for syslog ingestion through a Gateway listener | `false` |
| `gatewayApi.syslog.parentRefs` | Parent Gateway listener refs for the syslog UDPRoute when `gatewayApi.mode=attach` | `[]` |
| `networkPolicy.enabled` | Render Kubernetes/Calico network policies | `false` |
| `networkPolicy.podSelectorMatchAll` | Apply Kubernetes NetworkPolicy to all pods in the namespace | `false` |
| `networkPolicy.ingress.allowSameNamespace` | Allow ingress from pods in the release namespace when NetworkPolicy is enabled | `true` |
| `networkPolicy.ingress.allowedNamespaces` | Additional namespace names allowed to initiate ingress | `[]` |
| `networkPolicy.ingress.allowedCIDRs` | Additional ingress CIDR allow list | `[]` |
| `networkPolicy.ingress.allowedPorts` | Application ingress ports allowed from same-namespace / allowed namespace / allowed CIDR peers | ServiceRadar defaults excluding ERTS |
| `networkPolicy.ingress.erts.enabled` | Render a separate EPMD / Erlang distribution ingress rule scoped to cluster-member pods | `true` |
| `networkPolicy.ingress.agentGatewayExternal.allowedCIDRs` | External CIDR allow list for the agent-gateway LoadBalancer ports | `["0.0.0.0/0"]` |
| `networkPolicy.ingress.flowCollectorExternal.allowedCIDRs` | External CIDR allow list for enabled non-ClusterIP NetFlow/IPFIX/sFlow collector ports | `["0.0.0.0/0"]` |
| `networkPolicy.ingress.logCollectorExternal.allowedCIDRs` | External CIDR allow list for enabled non-ClusterIP syslog collector ports | `["0.0.0.0/0"]` |
| `networkPolicy.ingress.trapdExternal.allowedCIDRs` | External CIDR allow list for enabled non-ClusterIP SNMP trap collector ports | `["0.0.0.0/0"]` |
| `networkPolicy.ingress.bmpCollectorExternal.allowedCIDRs` | External CIDR allow list for enabled non-ClusterIP BMP collector ports | `["0.0.0.0/0"]` |
| `networkPolicy.egress.allowDNS` | Allow DNS to kube-system (53/TCP+UDP) | `true` |
| `networkPolicy.egress.allowKubeAPIServer` | Allow egress to the kube-apiserver endpoints (via Helm lookup) | `true` |
| `networkPolicy.egress.allowDefaultNamespace` | Allow egress to the `default` namespace (Kubernetes API) | `true` |
| `networkPolicy.egress.allowSameNamespace` | Allow egress to pods in the release namespace | `true` |
| `networkPolicy.egress.allowedCIDRs` | Additional egress CIDR allow list | `[]` |
| `networkPolicy.calicoLogDenied.enabled` | Render Calico policy to log denied egress | `false` |
| `networkPolicy.calicoLogDenied.selector` | Calico selector for matching pods | `app.kubernetes.io/part-of == 'serviceradar'` |
| `networkPolicy.calicoLogDenied.order` | Calico policy order (lower is higher priority) | `1000` |
| `cnpg.localDevAccess.enabled` | Render a CNPG primary ingress NetworkPolicy for local developer workstation access | `false` |
| `cnpg.localDevAccess.policyName` | Name for the local developer CNPG ingress NetworkPolicy | `cnpg-allow-local-dev-postgres` |
| `cnpg.localDevAccess.allowedCIDRs` | CIDRs allowed to connect directly to the CNPG primary on TCP/5432 | `[]` |
| `podDisruptionBudgets.enabled` | Render PDBs for core, web-ng, datasvc, and agent-gateway | `true` |
| `podDisruptionBudgets.minAvailable` | Minimum available pods for ServiceRadar PDBs | `1` |
| `global.storage.encryptedStorageClassName` | StorageClass used by durable database/object-store PVCs when no service-specific class is set | `encrypted` |
| `global.storage.allowInsecureStorage` | Allow durable PVCs to inherit the cluster default or use a known non-encrypted class. Lab/demo only. | `false` |
| `cnpg.storageClass` | StorageClass for CNPG database volumes. Defaults to `global.storage.encryptedStorageClassName` when empty. | `""` |
| `nats.persistence.storageClassName` | StorageClass for NATS JetStream file-store volumes. Defaults to `global.storage.encryptedStorageClassName` when empty. | `""` |
| `datasvc.data.storageClassName` | StorageClass for optional datasvc local object-store volumes. Defaults to `global.storage.encryptedStorageClassName` when enabled and empty. | `""` |
| `webNg.checkOrigin` | Enable Phoenix/LiveView origin checks for browser and WebSocket requests. Disable only for local reverse-proxy debugging. | `"true"` |
| `cnpg.pooler.enabled` | Deploy a CNPG-managed PgBouncer pooler | `false` |
| `cnpg.pooler.instances` | PgBouncer pooler pod count | `3` |
| `cnpg.pooler.ha.podAntiAffinity.type` | Pooler pod spreading mode, `preferred` or `required` | `preferred` |
| `cnpg.pooler.monitoring.podMonitor.enabled` | Create a Prometheus Operator PodMonitor for PgBouncer metrics | `false` |
| `cnpg.pooler.route.core` | Route core runtime database traffic through the pooler when enabled | `true` |
| `cnpg.pooler.route.webNg` | Route web-ng runtime database traffic through the pooler when enabled | `true` |
| `observability.enabled` | Render the ServiceRadar Prometheus/Grafana observability bundle | `false` |
| `observability.prometheus.serviceMonitors.enabled` | Create Prometheus Operator ServiceMonitors for scrapeable ServiceRadar services | `true` |
| `observability.prometheus.serviceMonitors.targets.webNg.enabled` | Scrape web-ng `/metrics` through the `serviceradar-web-ng` service | `true` |
| `observability.prometheus.serviceMonitors.targets.core.enabled` | Scrape core-elx `/metrics` through the `serviceradar-core` service | `true` |
| `observability.prometheus.serviceMonitors.targets.agentGateway.enabled` | Scrape agent-gateway `/metrics` through the internal metrics service | `true` |
| `observability.prometheus.rules.enabled` | Create ServiceRadar PrometheusRule groups for scrape, database, and PgBouncer health | `true` |
| `observability.prometheus.rules.labels` | Extra labels for Prometheus rule discovery, for example `release: kube-prom` | `{}` |
| `observability.grafana.dashboards.enabled` | Create Grafana dashboard ConfigMaps for the ServiceRadar dashboard folder | `true` |
| `observability.grafana.dashboards.labels` | Grafana sidecar discovery labels for dashboard ConfigMaps | `grafana_dashboard: "1"` |
| `secrets.autoGenerate` | Auto-generate secrets | `true` |
| `spire.enabled` | Enable SPIRE identity plane | `false` |
| `agent.resources.limits.cpu` | Agent CPU limit | `500m` |
| `agent.checkersStorage.enabled` | Persist agent checker config under `/var/lib/serviceradar/checkers` | `true` |
| `agent.cacheStorage.enabled` | Persist agent runtime cache under `/var/lib/serviceradar/cache` | `true` |
| `agent.runtimeStorage.enabled` | Persist managed agent release runtime under `/var/lib/serviceradar/agent` | `true` |
| `webNg.gatewayAddress` | External gateway address for edge agents (host:port). Set this explicitly when the agent gateway is exposed on a different host than the web ingress. Otherwise it defaults to `ingress.host:50052` when set, or the in-cluster service. | `""` |

### Storage Encryption

Remote-access recordings currently persist as CNPG rows. The planned object-store path uses the NATS/datasvc durable storage path. Production installs therefore fail closed by default to an encrypted storage class:

```yaml
global:
  storage:
    encryptedStorageClassName: encrypted
    allowInsecureStorage: false
```

Set `cnpg.storageClass`, `nats.persistence.storageClassName`, or `datasvc.data.storageClassName` when a cluster uses service-specific encrypted classes. Local/demo clusters without encrypted CSI support must opt in explicitly:

```yaml
global:
  storage:
    allowInsecureStorage: true
```

Do not use the insecure override for production remote-access deployments.

### ServiceRadar Observability Bundle

The `observability` values tree provisions Prometheus Operator resources and Grafana dashboards for Kubernetes installs. It intentionally renders scrape targets only for endpoints that are known to expose Prometheus format. At the moment this includes web-ng `/metrics`, core-elx `/metrics`, agent-gateway `/metrics`, CNPG PodMonitor metrics, and the CNPG PgBouncer Pooler PodMonitor when the pooler is enabled.

The bundled Grafana dashboards are stored under `helm/serviceradar/dashboards/` and are published as ConfigMaps with configurable sidecar labels. kube-prometheus-stack defaults work with:

```yaml
observability:
  enabled: true
  prometheus:
    rules:
      labels:
        release: kube-prom
  grafana:
    dashboards:
      labels:
        grafana_dashboard: "1"
```

Initial scrape inventory:

| Component | Prometheus coverage | Notes |
|-----------|---------------------|-------|
| web-ng | `ServiceMonitor/serviceradar-web-ng` | Scrapes `/metrics` on the existing HTTP service. |
| core-elx | `ServiceMonitor/serviceradar-core` | Scrapes `/metrics` on the core service port `9090`. |
| agent-gateway | `ServiceMonitor/serviceradar-agent-gateway` | Scrapes `/metrics` through the internal `serviceradar-agent-gateway-metrics` ClusterIP service. |
| CNPG | CNPG-managed `PodMonitor` | Enabled through the CNPG cluster monitoring flag. |
| PgBouncer | `cnpg.pooler.monitoring.podMonitor.enabled` | Scrapes CloudNativePG Pooler metrics on port `metrics`. |
| flow-collector | Optional `ServiceMonitor` | Rendered only when `flowCollector.service.ports.metrics.enabled=true`. Disabled in demo until the metrics listener is enabled. |
| NATS | Not scraped by default | NATS exposes JSON monitoring on 8222; add a NATS Prometheus exporter before scraping it as Prometheus metrics. |
| log-collector, trapd, BMP collector, datasvc, agent | Not scraped by default | No confirmed Prometheus metrics endpoint is exposed by the chart today. Add exporters before enabling scrape targets. |

### HA And JetStream Sizing

The published chart defaults stay conservative and mostly single-replica so first installs fit smaller clusters. The `demo` overlay in [values-demo.yaml](/home/mfreeman/src/serviceradar/helm/serviceradar/values-demo.yaml) enables the HA profile that has been validated in Kubernetes:

- `core.replicas=3`
- `webNg.replicas=3`
- `agentGateway.replicas=3`
- `datasvc.replicaCount=3`
- `logCollector.replicaCount=3`
- `logCollector.tcpCollector.replicaCount=3`
- `trapd.replicaCount=3`
- `flowCollector.replicaCount=3`
- `bmpCollector.replicaCount=3`

The control-plane and ingest workers above rely on shared JetStream durable consumers or shared streams. The important knobs are:

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `datasvc.jetstreamReplicas` | Replica count for KV/object streams owned by datasvc | `1` |
| `datasvc.bucketMaxBytes` | Max bytes for `KV_serviceradar-datasvc` | `5368709120` |
| `datasvc.objectMaxBytes` | Max bytes for a single object upload | `536870912` |
| `datasvc.objectStoreBytes` | Max bytes exposed to datasvc object-store config | `17179869184` |
| `objectStoreRetention.enabled` | Enables scheduled cleanup for ServiceRadar-owned object-store namespaces | `true` |
| `objectStoreRetention.dryRun` | Logs retention decisions without deleting eligible objects | `false` |
| `objectStoreRetention.agentReleaseKeepLatest` | Imported agent releases to retain when not protected by rollout state | `1` |
| `objectStoreRetention.nativeAddonOrphanGraceSeconds` | Grace period before deleting unreferenced native add-on objects | `604800` |
| `logCollector.streamReplicas` | Replica count for the shared `events` stream | `1` |
| `logCollector.streamMaxBytes` | Max bytes for the shared `events` stream | `2147483648` |
| `logCollector.tcpCollector.streamReplicas` | Replica count for TCP syslog writers on `events` | `1` |
| `trapd.streamReplicas` | Replica count for SNMP trap writers on `events` | `1` |
| `flowCollector.streamReplicas` | Replica count for flow writers on `events` | `1` |
| `flowCollector.config.stream_max_bytes` | Max bytes for flow subjects on `events` | `10737418240` |
| `bmpCollector.config.streamReplicas` | Replica count for the dedicated `ARANCINI_CAUSAL` stream | `1` |
| `bmpCollector.config.streamMaxBytes` | Max bytes for the dedicated BMP stream | `10737418240` |

In `demo`, the shared `events` path runs at `3` replicas with smaller reserved caps so JetStream placement fits within the account budget. Datasvc keeps the KV stream small while leaving object-store headroom for one retained agent release plus a replacement import before retention runs. `bmpCollector` runs with `3` pods in demo, but its dedicated stream is still intentionally left at `1` replica until that stream budget is sized separately.

### Notes

- Ingress is disabled by default; set `ingress.enabled=true` and provide `ingress.host` (plus TLS settings if needed).
- A pre-install hook auto-generates `serviceradar-secrets` (JWT/API key, admin password + bcrypt hash) unless you disable it with `--set secrets.autoGenerate=false`. If you disable it, create the secret yourself at `secrets.existingSecretName` (default `serviceradar-secrets`).
- That shared secret also owns the default edge onboarding signing key and Erlang cluster cookie. Leave `secrets.edgeOnboardingKey` and `webNg.clusterCookie` empty to auto-generate unique install-scoped values; set them explicitly only when you need deterministic secret material or are rotating to a planned replacement.
- If `secrets.autoGenerate=false`, your pre-created secret must also include `edge-onboarding-key`, `cluster-cookie`, `web-ng-secret-key-base`, and the other runtime keys expected by the chart.
- A pre-install hook also generates the runtime certificate bundle and publishes it to `certs.runtimeSecretName` (default `serviceradar-runtime-certs`).
- The chart does not generate image pull secrets; create `registry-carverauto-dev-cred` (or override `image.registryPullSecret`).
- The in-cluster agent writes mutable checker config, cache files, and managed release payloads under `/var/lib/serviceradar`; keep the default PVC-backed `agent.*Storage` settings enabled in Kubernetes production environments.
- SPIFFE/SPIRE is optional. Enable it with `--set spire.enabled=true` (and `--set spire.postgres.enabled=true` if you also want the in-chart SPIRE database resources).
- When SPIRE mode is enabled, the SPIRE server now stays internal by default (`spire.server.serviceType=ClusterIP`), the SPIRE health port is not published unless you explicitly set `spire.server.exposeHealthPort=true`, and kubelet verification stays enabled unless you explicitly set `spire.agent.skipKubeletVerification=true`.
- The SPIRE controller manager sidecar can be disabled with `--set spire.controllerManager.enabled=false` if you do not need webhook-managed entries.

### MTR Automation Rollout

Use `core.mtrAutomation` to stage automated MTR behavior on core-elx:

```yaml
core:
  mtrAutomation:
    enabled: false
    baselineEnabled: false
    triggerEnabled: false
    consensusEnabled: false
    baselineTickMs: 60000
    consensusCohortRetentionMs: 300000
```

Recommended staged enablement:
1. Baseline only:
```yaml
core:
  mtrAutomation:
    enabled: true
    baselineEnabled: true
    triggerEnabled: false
    consensusEnabled: false
    baselineTickMs: 60000
    consensusCohortRetentionMs: 300000
```
2. Trigger capture:
```yaml
core:
  mtrAutomation:
    enabled: true
    baselineEnabled: true
    triggerEnabled: true
    consensusEnabled: false
    baselineTickMs: 60000
    consensusCohortRetentionMs: 300000
```
3. Full consensus:
```yaml
core:
  mtrAutomation:
    enabled: true
    baselineEnabled: true
    triggerEnabled: true
    consensusEnabled: true
    baselineTickMs: 60000
    consensusCohortRetentionMs: 300000
```

## Network Requirements

### In-Cluster

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Ingress | Web-NG | 4000 | TCP | User interface |
| Web-NG | Core | 8090 | TCP | API calls |
| Gateway | Core | 50052 | gRPC | Status reporting |
| Agent | Gateway | 50052 | gRPC | Service check results |

### Edge (External Agents)

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Edge Agent | Gateway | 50052 | gRPC+mTLS | Service check results |

**Firewall Requirements:**
- Only port 50052 (gRPC) needs to be accessible from edge networks
- ERTS distribution ports (4369, 9100-9155) are not part of the ordinary ingress allowlist. When `networkPolicy.enabled=true`, they are allowed only from pods matching `networkPolicy.ingress.erts.podSelector` in the release namespace. Rotate `cluster-cookie` when changing cluster membership trust boundaries.
- Edge agents do not need database or internal API access
