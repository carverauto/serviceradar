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
| `global.imageTag` | Docker image tag for all components | `latest` |
| `ingress.enabled` | Enable ingress for web UI | `false` |
| `ingress.host` | Hostname for ingress | `""` |
| `ingress.tls.secretName` | TLS secret name | `""` |
| `networkPolicy.enabled` | Render Kubernetes/Calico network policies | `false` |
| `networkPolicy.podSelectorMatchAll` | Apply Kubernetes NetworkPolicy to all pods in the namespace | `false` |
| `networkPolicy.egress.allowDNS` | Allow DNS to kube-system (53/TCP+UDP) | `true` |
| `networkPolicy.egress.allowKubeAPIServer` | Allow egress to the kube-apiserver endpoints (via Helm lookup) | `true` |
| `networkPolicy.egress.allowDefaultNamespace` | Allow egress to the `default` namespace (Kubernetes API) | `true` |
| `networkPolicy.egress.allowSameNamespace` | Allow egress to pods in the release namespace | `true` |
| `networkPolicy.egress.allowedCIDRs` | Additional egress CIDR allow list | `[]` |
| `networkPolicy.calicoLogDenied.enabled` | Render Calico policy to log denied egress | `false` |
| `networkPolicy.calicoLogDenied.selector` | Calico selector for matching pods | `app.kubernetes.io/part-of == 'serviceradar'` |
| `networkPolicy.calicoLogDenied.order` | Calico policy order (lower is higher priority) | `1000` |
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
| `webNg.gatewayAddress` | External gateway address for edge agents (host:port). Set this explicitly when the agent gateway is exposed on a different host than the web ingress. Otherwise it defaults to `ingress.host:50052` when set, or the in-cluster service. | `""` |

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
| log-collector, trapd, BMP collector, db-event-writer, datasvc, zen, agent | Not scraped by default | No confirmed Prometheus metrics endpoint is exposed by the chart today. Add exporters before enabling scrape targets. |

### HA And JetStream Sizing

The published chart defaults stay conservative and mostly single-replica so first installs fit smaller clusters. The `demo` overlay in [values-demo.yaml](/home/mfreeman/src/serviceradar/helm/serviceradar/values-demo.yaml) enables the HA profile that has been validated in Kubernetes:

- `core.replicas=3`
- `webNg.replicas=3`
- `agentGateway.replicas=3`
- `dbEventWriter.replicaCount=3`
- `datasvc.replicaCount=3`
- `zen.replicaCount=3`
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
| `datasvc.objectMaxBytes` | Max bytes for `OBJ_serviceradar-objects` metadata stream | `536870912` |
| `datasvc.objectStoreBytes` | Max bytes exposed to datasvc object-store config | `2147483648` |
| `zen.streamReplicas` | Replica count for zen's shared `events` stream reconciliation | `1` |
| `logCollector.streamReplicas` | Replica count for the shared `events` stream | `1` |
| `logCollector.streamMaxBytes` | Max bytes for the shared `events` stream | `2147483648` |
| `logCollector.tcpCollector.streamReplicas` | Replica count for TCP syslog writers on `events` | `1` |
| `trapd.streamReplicas` | Replica count for SNMP trap writers on `events` | `1` |
| `flowCollector.streamReplicas` | Replica count for flow writers on `events` | `1` |
| `flowCollector.config.stream_max_bytes` | Max bytes for flow subjects on `events` | `10737418240` |
| `bmpCollector.config.streamReplicas` | Replica count for the dedicated `ARANCINI_CAUSAL` stream | `1` |
| `bmpCollector.config.streamMaxBytes` | Max bytes for the dedicated BMP stream | `10737418240` |

In `demo`, the shared `events` path runs at `3` replicas with smaller reserved caps so JetStream placement fits within the account budget. Datasvc KV/object streams are also reduced from the generic defaults because demo stores very little real data. `bmpCollector` runs with `3` pods in demo, but its dedicated stream is still intentionally left at `1` replica until that stream budget is sized separately.

### Notes

- Ingress is disabled by default; set `ingress.enabled=true` and provide `ingress.host` (plus TLS settings if needed).
- A pre-install hook auto-generates `serviceradar-secrets` (JWT/API key, admin password + bcrypt hash) unless you disable it with `--set secrets.autoGenerate=false`. If you disable it, create the secret yourself at `secrets.existingSecretName` (default `serviceradar-secrets`).
- That shared secret also owns the default edge onboarding signing key and Erlang cluster cookie. Leave `secrets.edgeOnboardingKey` and `webNg.clusterCookie` empty to auto-generate unique install-scoped values; set them explicitly only when you need deterministic secret material or are rotating to a planned replacement.
- If `secrets.autoGenerate=false`, your pre-created secret must also include `edge-onboarding-key`, `cluster-cookie`, `web-ng-secret-key-base`, and the other runtime keys expected by the chart.
- A pre-install hook also generates the runtime certificate bundle and publishes it to `certs.runtimeSecretName` (default `serviceradar-runtime-certs`).
- The chart does not generate image pull secrets; create `registry-carverauto-dev-cred` (or override `image.registryPullSecret`).
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
- ERTS distribution ports (4369, 9100-9155) should NOT be exposed to edge networks
- Edge agents do not need database or internal API access
