# ServiceRadar Helm Chart

This chart packages the ServiceRadar demo stack for Helm-based installs.

Official chart location (OCI/Harbor):
- Chart: `oci://registry.carverauto.dev/serviceradar/charts/serviceradar`
- ArgoCD repoURL (no `oci://` prefix): `registry.carverauto.dev/serviceradar/charts`

## Installation

### From Published OCI Chart (Recommended)

```bash
helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  --version <chart-version> \
  -n serviceradar --create-namespace \
  -f my-values.yaml
```

`my-values.yaml` holds only your site overrides. The chart version is the
release version without the leading `v` (release `vX.Y.Z` is chart `X.Y.Z`).
The chart and the first-party images under `registry.carverauto.dev/serviceradar`
pull anonymously, so no registry login is needed. Every first-party image tag
except `serviceradar-cnpg` (pinned by digest) defaults to the chart appVersion, so `--version` alone selects matching images.
Leave `global.imageTag` unset; if you do set it, it must be `v<chart-version>`,
or the core migrations `expectedVersion` and the templates drift from the
images. To upgrade, rerun the same command with the new `--version`.

### From Repository Checkout (Development)

Use a local chart path only when developing or testing chart changes:

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

`latest` is not tied to the checkout's chart version, so the migrations
`expectedVersion` and templates can drift from the images. Never use it for an
operator install.

### Hosted Tenant Runtime Baseline

Dedicated hosted tenant clusters use [values-tenant.yaml](values-tenant.yaml)
as the chart baseline rendered by the ServiceRadar control plane. See
[TENANT_RUNTIME.md](TENANT_RUNTIME.md) for the render-validation command and
hosted exposure model.

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
| Dgraph | Topology graph (Zero + Alpha). Disable with `dgraph.enabled=false` and set `dgraph.external.host` to reuse an existing cluster. | 9080 (gRPC), 8080 (HTTP) |
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
- For legacy SPIRE installations, follow [Migrating off SPIRE](../../docs/docs/migrating-off-spire.md) before upgrading
- Isolation is enforced by deployment boundaries and database credentials

For detailed edge agent deployment, see the [Edge Agent Guide](../docs/docs/edge-agents.md).

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imageTag` | Override image tag for first-party components (not `serviceradar-cnpg`). Empty uses `v<appVersion>` from the chart; if set, it must equal `v<chart-version>` | `""` |
| `image.digests.<service>` | Optional digest pin for a first-party component, overriding tags | `{}` |
| `ingress.enabled` | Enable ingress for web UI | `false` |
| `ingress.host` | Hostname for ingress | `""` |
| `ingress.tls.secretName` | TLS secret name | `""` |
| `gatewayApi.syslog.enabled` | Render a Gateway API UDPRoute for syslog ingestion through a Gateway listener | `false` |
| `gatewayApi.syslog.parentRefs` | Parent Gateway listener refs for the syslog UDPRoute when `gatewayApi.mode=attach` | `[]` |
| `gatewayApi.agentGateway.enabled` | Render Gateway API TCPRoute resources for edge-agent gRPC and artifact traffic so the agent gateway can share the Gateway data-plane Service | `false` |
| `gatewayApi.agentGateway.envoyGatewayNamespace` | Envoy Gateway data-plane namespace admitted by the Gateway-mode agent-gateway NetworkPolicy | `envoy-gateway-system` |
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
| `remoteAccess.desktop.rdp.webRTC.networkPolicy.enabled` | Render an additive core-only ICE egress policy; requires chart-wide NetworkPolicy and RDP | `false` |
| `remoteAccess.desktop.rdp.webRTC.networkPolicy.allowedCIDRs` | Explicit ICE destination IPv4/IPv6 CIDRs; DNS names and catch-all CIDRs are rejected | `[]` |
| `remoteAccess.desktop.rdp.webRTC.networkPolicy.allowedUDPPorts` | Explicit ICE UDP destination ports in `1..65535` | `[]` |
| `remoteAccess.desktop.rdp.webRTC.networkPolicy.allowedTCPPorts` | Explicit ICE TCP destination ports in `1..65535` | `[]` |
| `remoteAccess.desktop.rdp.webRTC.networkPolicy.*` | Alias of `webrtc.networkPolicy.*`; set only one of the two | |
| `webrtc.networkPolicy.enabled` | Render an additive core-only ICE egress policy (`serviceradar-webrtc-egress`); requires chart-wide NetworkPolicy | `false` |
| `webrtc.networkPolicy.allowedCIDRs` | Explicit ICE destination IPv4/IPv6 CIDRs; DNS names and catch-all CIDRs are rejected | `[]` |
| `webrtc.networkPolicy.allowedUDPPorts` | Explicit ICE UDP destination ports in `1..65535` | `[]` |
| `webrtc.networkPolicy.allowedTCPPorts` | Explicit ICE TCP destination ports in `1..65535` | `[]` |
| `webrtc.iceCredentials.backend` | WebRTC ICE credential backend: `none` (STUN only) or `static_secret` (per-viewer TURN REST credentials). See [WebRTC TURN Relay](../../docs/docs/webrtc-turn-relay.md) | `none` |
| `webrtc.iceCredentials.ttlSeconds` | Minted TURN credential lifetime, `60..3600` | `600` |
| `webrtc.iceCredentials.staticSecret.existingSecretName` / `.secretKey` | Operator-created Secret (and key) holding the TURN REST shared secret, mounted into web-ng, core-elx and the TURN server | `""` / `shared-secret` |
| `webrtc.iceCredentials.turnUrls` / `.peerTurnUrls` | Extra TURN URLs for browsers / for core-elx (servers outside this chart). URLs only. Peer URLs must be `turn:` with transport omitted or `transport=udp` | `[]` |
| `webrtc.turnServer.enabled` | Deploy the chart-managed TURN relay (eturnal); requires `backend: static_secret` and `externalHostname` | `false` |
| `webrtc.turnServer.exposure` | `gateway` (routes on `externalPorts`) or `service` (LoadBalancer only; other service types fail rendering). See [WebRTC TURN Relay](../../docs/docs/webrtc-turn-relay.md) | `gateway` |
| `webrtc.turnServer.tls.enabled` | Serve TURNS on 5349 with a certificate for `externalHostname` | `false` |
| `webrtc.turnServer.relayPortRange.min` / `.max` | In-cluster relay ports (never published), at most 1000 | `49160` / `49359` |
| `cnpg.localDevAccess.enabled` | Render a CNPG primary ingress NetworkPolicy for local developer workstation access | `false` |
| `cnpg.localDevAccess.policyName` | Name for the local developer CNPG ingress NetworkPolicy | `cnpg-allow-local-dev-postgres` |
| `cnpg.localDevAccess.allowedCIDRs` | CIDRs allowed to connect directly to the CNPG primary on TCP/5432 | `[]` |
| `podDisruptionBudgets.enabled` | Render PDBs for core, web-ng, datasvc, and agent-gateway | `true` |
| `podDisruptionBudgets.minAvailable` | Minimum available pods for ServiceRadar PDBs | `1` |
| `global.storage.encryptedStorageClassName` | StorageClass used by durable database/object-store PVCs when no service-specific class is set | `encrypted` |
| `global.storage.allowInsecureStorage` | Allow durable PVCs to inherit the cluster default or use a known non-encrypted class. Lab/demo only. | `false` |
| `cnpg.storageClass` | StorageClass for CNPG database volumes. Defaults to `global.storage.encryptedStorageClassName` when empty. | `""` |
| `cnpg.backup.enabled` | Render CNPG native Barman object-store backup and scheduled base-backup resources | `false` |
| `cnpg.backup.barmanObjectStore.destinationPath` | Object-store destination path for CNPG WAL archives and base backups | `""` |
| `cnpg.backup.barmanObjectStore.s3Credentials.secretName` | Kubernetes Secret containing object-store access keys referenced by CNPG | `""` |
| `cnpg.backup.scheduledBackup.schedule` | Six-field CNPG ScheduledBackup cron expression | `"0 0 0 * * *"` |
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
| `serviceAccounts.<component>` | Neutral workload account override | `""` |
| `trustDomain` | Neutral workload trust domain | `""` |
| `cnpg.clusterName`, `cnpg.instances`, `cnpg.storageClass`, `cnpg.storageSize` | Neutral cluster overrides; null retains built-in defaults | `null` |
| `cnpg.namespace` | Cluster namespace; blank retains the release namespace | `null` |
| `webNg.adminEmail` | Bootstrap admin email | `root@localhost` |
| `webNg.adminPasswordForceSync` | Enable bootstrap secret rotation handling; see [Bootstrap Admin Access](../../docs/docs/auth-configuration.md#bootstrap-admin-access-self-hosted). | `false` |
| `webNg.auth.forceLocalLogin` | Break-glass switch that permits local password login regardless of SSO enforcement. Leave false for normal installs; use the per-user Local password login toggle instead. | `false` |
| `webNg.auth.disableSso` | Hide the SSO button on the sign-in page | `false` |
| `webNg.cameraRelay.webRTC.enabled` | Enable WebRTC playback for camera relay viewers (LiveView and dashboard camera API); viewers otherwise use the websocket transports | `false` |
| `webNg.cameraRelay.webRTC.iceServers` | Public STUN/TURN endpoints for camera relay viewers; each entry may contain only `urls` (credentials are rejected). Rendered only when WebRTC is enabled | `[]` |
| `webNg.clientIp.trustXForwardedFor` | Honor `x-forwarded-for` for client IP extraction (audit logs, rate limiting). Enable only when web-ng sits behind a trusted proxy, e.g. the shared envoy Gateway API. | `false` |
| `webNg.clientIp.trustedProxyCidrs` | CIDRs of trusted direct peers (envoy/gateway pod or service ranges) allowed to set `x-forwarded-for`. List only the proxy's own range: every CIDR here is an address web-ng will never report as a client, so RFC1918 wholesale makes LAN clients unreportable. Ignored when `trustXForwardedFor` is false. | `[]` |
| `agent.resources.limits.cpu` | Agent CPU limit | `500m` |
| `agent.checkersStorage.enabled` | Persist agent checker config under `/var/lib/serviceradar/checkers` | `true` |
| `agent.cacheStorage.enabled` | Persist agent runtime cache under `/var/lib/serviceradar/cache` | `true` |
| `agent.runtimeStorage.enabled` | Persist managed agent release runtime under `/var/lib/serviceradar/agent` | `true` |
| `webNg.gatewayAddress` | External gateway address for edge agents (`host:port`). Set this explicitly when the agent gateway is exposed on a different host than the web endpoint. Otherwise the chart derives port `50052` from `webNg.host`, `ingress.host`, or `gatewayApi.host` (in that order), then falls back to the in-cluster service name. | `""` |

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
| web-ng | `ServiceMonitor/serviceradar-web-ng` | Scrapes `/metrics` on the internal metrics port. Auth and the public-port fallback are in [Prometheus Metrics Scraping and Authentication](../../docs/docs/helm-configuration.md#prometheus-metrics-scraping-and-authentication). |
| core-elx | `ServiceMonitor/serviceradar-core` | Scrapes `/metrics` on the core service port `9090`. |
| agent-gateway | `ServiceMonitor/serviceradar-agent-gateway` | Scrapes `/metrics` through the internal `serviceradar-agent-gateway-metrics` ClusterIP service. |
| CNPG | CNPG-managed `PodMonitor` | Enabled through the CNPG cluster monitoring flag. |
| PgBouncer | `cnpg.pooler.monitoring.podMonitor.enabled` | Scrapes CloudNativePG Pooler metrics on port `metrics`. |
| flow-collector | Optional `ServiceMonitor` | Rendered only when `flowCollector.service.ports.metrics.enabled=true`. Disabled in demo until the metrics listener is enabled. |
| NATS | Not scraped by default | NATS exposes JSON monitoring on 8222; add a NATS Prometheus exporter before scraping it as Prometheus metrics. |
| log-collector, trapd, BMP collector, datasvc, agent | Not scraped by default | No confirmed Prometheus metrics endpoint is exposed by the chart today. Add exporters before enabling scrape targets. |

### HA And JetStream Sizing

The base chart defaults the core control plane, shared ingest workers, datasvc,
and NATS to three replicas. The `demo` overlay
(`helm/serviceradar/values-demo.yaml` in the ServiceRadar repository; it is not
shipped in the published chart) repeats that validated topology and adds
demo-specific external ingest settings. Its effective replica layout is:

- `core.replicas=3`
- `webNg.replicas=3`
- `agentGateway.replicas=3`
- `datasvc.replicaCount=3`
- `logCollector.replicaCount=3`
- `logCollector.tcpCollector.replicaCount=3`
- `trapd.replicaCount=3`
- `flowCollector.replicaCount=1` (single pod + Recreate + RWO marker PVC; JetStream HA is `config.stream_replicas=3`)
- `bmpCollector.replicaCount=3` (demo only; `values-ha.yaml` does not enable or scale BMP)

Setting `core.replicas=0` renders zero replicas for an operator-requested drain.
If the key is absent from the merged values, the template falls back to one;
omitting an override still uses the chart default shown above. Desired zero does
not prove that running owners have retired. Persistent-spool controller conversion
remains unimplemented; its required guard and retirement checks are specified in
the [conversion protocol](../../openspec/changes/add-persistent-camera-spool/conversion-protocol.md).

The control-plane and ingest workers above rely on shared JetStream durable consumers or shared streams. The important knobs are:

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `nats.jetstream.profile` | JetStream sizing profile (`small`, `medium`, `large`, `tenant-2g`) supplying `max_file_store` and every stream size below; the chart fails at render time when the reservations exceed 85% of `max_file_store` or `max_file_store` exceeds 94% of `nats.persistence.size`. See [JetStream sizing values](../../docs/docs/helm-configuration.md) and `docs/nats-jetstream-profile-runbook.md` | `small` |
| `datasvc.jetstreamReplicas` | Replica count for KV/object streams owned by datasvc | `3` |
| `datasvc.bucketMaxBytes` | Max bytes for `KV_serviceradar-datasvc` | unset (`nats.jetstream.profile` supplies it; 1 GiB in `small`) |
| `datasvc.objectMaxBytes` | Max bytes for a single object upload | `536870912` |
| `datasvc.objectStoreBytes` | Max bytes exposed to datasvc object-store config | unset (profile supplies it; 4 GiB in `small`) |
| `bumblebeeCatalogRefresh.enabled` | Runs the daily Bumblebee exposure-catalog refresh on core (first run at boot); off means agents never receive a scannable catalog | `true` |
| `objectStoreRetention.enabled` | Enables scheduled cleanup for ServiceRadar-owned object-store namespaces | `true` |
| `objectStoreRetention.dryRun` | Logs retention decisions without deleting eligible objects | `false` |
| `objectStoreRetention.agentReleaseKeepLatest` | Imported agent releases to retain when not protected by rollout state | `1` |
| `objectStoreRetention.nativeAddonOrphanGraceSeconds` | Grace period before deleting unreferenced native add-on objects | `604800` |
| `webNg.nativeAddonImport.autoSyncEnabled` | Import newly published first-party add-on releases automatically (staged, not approved); required for `track_latest_approved` profiles to see newer packages | `true` |
| `webNg.nativeAddonImport.syncIntervalSeconds` | Seconds between add-on catalog syncs | `3600` |
| `webNg.nativeAddonImport.autoApproveAddonIds` | Add-on ids whose imports are approved automatically; approval is the security boundary, so this is empty by default | `[]` |
| `webNg.firstPartyPluginImport.autoApproveWithinGrant` | Approve a verified first-party Wasm plugin package automatically (audited) when it requests nothing beyond its plugin's latest approved grant; first versions, widened grants and non-first-party packages stay staged | `true` |
| `core.wasmPluginAutomaticRollouts` | Roll Wasm plugin owners that track the latest approved version (manual assignments and target policies) forward to a newly approved stable version through a health-gated rollout; `false` leaves them until an operator starts one | `true` |
| `logCollector.rfc3164Timezone` | Assumed IANA time zone for RFC3164 messages without a zone, shared by UDP and TCP collectors | `UTC` |
| `logCollector.streamReplicas` | Replica count for the shared `events` stream | `3` |
| `logCollector.streamMaxBytes` | Max bytes for the shared `events` stream | unset (profile supplies it; 2 GiB in `small`) |
| `logCollector.tcpCollector.streamReplicas` | Replica count for TCP syslog writers on `events` | `3` |
| `trapd.streamReplicas` | Replica count for SNMP trap writers on `events` | `3` |
| `bmpCollector.config.streamReplicas` | Replica count for the dedicated `ARANCINI_CAUSAL` stream | `1` |
| `bmpCollector.config.streamMaxBytes` | Max bytes for the dedicated BMP stream | unset (profile supplies it; 2 GiB in `small`) |

Dedicated **`flows`** stream (flow-collector owns ensure/reconcile; not the shared `events` bus):

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `flowCollector.config.stream_name` | JetStream stream name for raw flows | `flows` |
| `flowCollector.config.stream_replicas` | JetStream replica count for the dedicated `flows` stream | `3` |
| `flowCollector.config.stream_max_bytes` | Max bytes for the dedicated `flows` stream | unset (profile supplies it; 8 GiB in `small`) |
| `flowCollector.config.stream_max_age_secs` | Max age for the dedicated `flows` stream | `21600` (6h) |

In `demo`, the shared `events` path runs at `3` replicas with smaller reserved caps so JetStream placement fits within the account budget. Datasvc keeps the KV stream small while leaving object-store headroom for one retained agent release plus a replacement import before retention runs. `bmpCollector` runs with `3` pods in demo, but its dedicated stream is still intentionally left at `1` replica until that stream budget is sized separately.

### Rolling Back Across the Flows Cutover

A plain `helm rollback` is unsafe when the target revision still configures the
flow collector with `stream_name: events`: Helm restores the old image before
that image can detach subjects from the dedicated `flows` stream. From a source
checkout, use the guarded helper so the current image transfers ownership back
before Helm starts the old image:

```bash
scripts/prepare-flow-collector-rollback.sh \
  --release serviceradar \
  --namespace <namespace> \
  --revision <legacy-revision>
```

For GitOps, pause reconciliation and use `--prepare-only --target-config` with
the target revision's rendered `flow-collector.json`; this mode does not require
Helm release history. Select the old revision immediately after preparation
succeeds. See the
[NetFlow ingest guide](../../docs/docs/netflow.md#downgrading-across-the-stream-ownership-cutover)
for the failure mode and recovery instructions.

### Notes

- Ingress is disabled by default; set `ingress.enabled=true` and provide `ingress.host` (plus TLS settings if needed).
- A pre-install hook auto-generates `serviceradar-secrets` (JWT/API key, admin password + bcrypt hash) unless you disable it with `--set secrets.autoGenerate=false`. If you disable it, create the secret yourself at `secrets.existingSecretName` (default `serviceradar-secrets`).
- That shared secret also owns the default edge onboarding signing key and Erlang cluster cookie. Leave `secrets.edgeOnboardingKey` and `webNg.clusterCookie` empty to auto-generate unique install-scoped values; set them explicitly only when you need deterministic secret material or are rotating to a planned replacement.
- If `secrets.autoGenerate=false`, your pre-created secret must also include `edge-onboarding-key`, `cluster-cookie`, `web-ng-secret-key-base`, and the other runtime keys expected by the chart.
- A pre-install hook also generates the runtime certificate bundle and publishes it to `certs.runtimeSecretName` (default `serviceradar-runtime-certs`).
- The chart does not generate image pull secrets. Published images pull anonymously, so none is required; set `image.registryPullSecret=""` to drop the default `registry-carverauto-dev-cred` reference, or create that secret (or override the name) when pulling through an authenticated mirror. Keep a real secret name there if you enable `argocdImageUpdater.pullSecretReader`, whose Role needs one.
- The in-cluster agent writes mutable checker config, cache files, and managed release payloads under `/var/lib/serviceradar`; keep the default PVC-backed `agent.*Storage` settings enabled in Kubernetes production environments.

### CNPG telemetry retention

Installs that keep telemetry in CNPG set retention under `core.observabilityRetention`. `DataRetentionWorker` reconciles the Timescale policies on its nightly run. When StarRocks is enabled it remains the telemetry store, and `analytics.starrocks.retentionDays` is unchanged by these keys.

`defaultDays` is optional. Leave it unset and each dataset keeps its own window. Set it to cap raw CNPG telemetry at that many days. A per-dataset value may be shorter. The ceiling takes effect on the next `DataRetentionWorker` run. Migrations install the per-dataset values until that run. Capacity forecasts stay on `capacityForecastsDays`. Hourly rollups never go below 7 days, because their refresh window is 5 days. Chunk intervals must stay smaller than the applied retention. Continuous-aggregate refresh windows stay strictly inside the source retention.

Flow records (NetFlow, sFlow, IPFIX, and process attribution) are stored only in StarRocks. Migration `20261019160000` dropped `platform.ocsf_network_activity`, so `ocsfNetworkActivityDays` and `ocsfNetworkActivityChunkIntervalHours` no longer govern a live CNPG hypertable and `defaultDays` does not apply to them. They remain for the older migration that still reads them.

The migration-only tables (`adhocScanResultsDays`, `serviceStatusDays`, `endpointInventoryHistoryDays`) and rollup aggregates (`spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`) are reconciled retention-only: their chunk intervals and compression stay as migrations installed them. Before a shorter retention applies, the worker clamps the refresh `start_offset` of `endpoint_inventory_package_counts_hourly`, `endpoint_inventory_cpe_counts_hourly`, `services_availability_5m`, and `otel_metrics_hourly_stats` strictly inside it, and floors each aggregate's own retention at that clamped window. `endpointInventoryHistoryDays` and `tracesStatsDays` are not capped by `defaultDays`. `tracesStatsDays` is the explicit value, or 14 days when omitted, floored at the clamped refresh window. While the cold tier is enabled the fence widens `traces_stats_5m`, and the worker does not write a shorter target first, including when no retention policy is installed. An unset `tracesStatsDays` leaves a widened window in place after the cold tier is disabled. A target shorter than the fence window is not written while the cold tier is on. A target at or above that window is written whether or not the tier is on. A later run leaves an installed value that already equals `tracesStatsDays`, including 14 days and shorter.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `core.observabilityRetention.defaultDays` | Optional ceiling, in days, for raw CNPG telemetry. Omit it to leave each dataset on its own window | unset |
| `core.observabilityRetention.traceSummaryDays` | Trace summary row retention | `3` |
| `core.observabilityRetention.otelTracesDays` | Raw span retention | `3` |
| `core.observabilityRetention.logsDays` | Log retention | `30` |
| `core.observabilityRetention.otelMetricsDays` | OTel metrics retention | `30` |
| `core.observabilityRetention.otelMetricPointsDays` | OTel metric point retention | `30` |
| `core.observabilityRetention.ocsfEventsDays` | OCSF event retention | `14` |
| `core.observabilityRetention.ocsfNetworkActivityDays` | Read only by an older migration. The CNPG network activity table no longer exists | `90` |
| `core.observabilityRetention.rawMetricsDays` | Raw host metric retention (`cpu`, `memory`, `disk`, `process`) | `7` |
| `core.observabilityRetention.timeseriesMetricsDays` | Raw `timeseries_metrics` retention | `7` |
| `core.observabilityRetention.capacityForecastsDays` | Capacity forecast retention. Not capped by `defaultDays` | `395` |
| `core.observabilityRetention.hourlyRollupDays` | Hourly rollup retention. Floored at 7 days | `395` |
| `core.observabilityRetention.adhocScanResultsDays` | Ad-hoc scan result retention | `30` |
| `core.observabilityRetention.serviceStatusDays` | `service_status` and `events` retention | `14` |
| `core.observabilityRetention.endpointInventoryHistoryDays` | Endpoint inventory scan/package history retention. Not capped by `defaultDays` | `395` |
| `core.observabilityRetention.spansRedDays` | `spans_red_1h` aggregate retention | `90` |
| `core.observabilityRetention.otelMetricsHourlyStatsDays` | `otel_metrics_hourly_stats` aggregate retention | `90` |
| `core.observabilityRetention.tracesStatsDays` | `traces_stats_5m` aggregate retention. Not capped by `defaultDays`. Omit to keep the 14-day migration window and leave a cold-tier-widened window unchanged. A target shorter than the fence window is not written while the cold tier is on. A target at or above that window is written whether or not the tier is on. A later run leaves an installed value that already equals it | unset |
| `core.observabilityRetention.otelTracesChunkIntervalHours` | Chunk interval for new trace chunks | `6` |
| `core.observabilityRetention.logsChunkIntervalHours` | Chunk interval for new log chunks | `24` |
| `core.observabilityRetention.otelMetricsChunkIntervalHours` | Chunk interval for new OTel metric chunks | `24` |
| `core.observabilityRetention.otelMetricPointsChunkIntervalHours` | Chunk interval for new OTel metric point chunks | `6` |
| `core.observabilityRetention.ocsfEventsChunkIntervalHours` | Chunk interval for new OCSF event chunks | `6` |
| `core.observabilityRetention.ocsfNetworkActivityChunkIntervalHours` | Read only by an older migration. The CNPG network activity table no longer exists | `24` |
| `core.observabilityRetention.rawMetricsChunkIntervalHours` | Chunk interval for new raw host-metric chunks | `24` |
| `core.observabilityRetention.capacityForecastsChunkIntervalHours` | Chunk interval for new capacity forecast chunks | `24` |

### MTR Automation Rollout

Automated MTR is **on by default** on core-elx:

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

`enabled` is not a master switch. It is the value the three stage flags fall
back to when they are unset, and each stage's own flag is what starts its
worker. Because this chart renders all four, the block above is what a fresh
install runs and narrowing the rollout means setting the stage flags:

1. Baseline only (no trigger capture, no consensus):
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
2. Baseline plus trigger capture (no consensus):
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
3. Everything off:
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

### Durable sweep canary

`edgeRecords.enabled` enables the gateway's durable bulk publisher and runtime
trust refresh from core. Supply `edgeRecords.contractRegistry` with the
installation's registry document: core and gateway receive the same JSON.
The sweep entry must be the active `serviceradar.sweep.observation` version 1
contract on the durable bulk route. Its bundle digest and registry snapshot
digest identify the reviewed installation contract; do not use test-fixture
identities in a deployment.

The current registry is installation-static and unsigned. For the canary,
derive its bundle fingerprint from the reviewed schema and cost/projection
sources, recording the file list and commit alongside the deployment values.
Hash the canonical registry body before adding `registry_snapshot_sha256`.
Keep that exact document on core and every gateway throughout the run.

The secret generator creates an `edge-issuer-seed` once and preserves it on
upgrade. Only core mounts this Ed25519 seed. If `secrets.autoGenerate=false`,
the operator must supply the key in the configured existing Secret as a
base64-encoded 32-byte seed (the Secret's data encoding wraps that text).

`edgeRecords.agentSweepEnabled` also enables the bundled agent's sweep producer.
It requires `agent.runtimeStorage.enabled=true`; the spool lives under that
volume's base path and `edgeRecords.maxSpoolBytes` bounds it. Core's agent-scoped
sweep lease settings select which agent receives signed slots. Enable leasing
only for the canary, and use an enabled static-target group without a target
query. Other agents continue using the legacy results path.

Use complete terminal ICMP/TCP host windows for this first canary. Partial-mode
and MTR windows are not supported by this projection yet. Keep the issuer key
and agent network scope fixed while records remain in the spool: historical
key/scope trust and audit publication are later milestones. The sweep sender
persists terminal resolutions. It reclaims a fully drained segment only when
durable accepted dispositions cover every retained sequence and match each
record's event identity. Unresolved and rejected records stay on disk, and
partial-tail compaction is not implemented. Reaching the configured byte bound
still stops further appends. Monitor the spool until the farm01 restart drill:
a segment that is not fully accepted is retained.
An interrupted run remains incomplete and is not rescanned once the agent has
durably claimed its first append attempt, even if that first append fails.

Upgrade core and the gateways before the agent. The agent's sweep producer
compresses each record payload as one Zstandard level 1 frame by default, and
keeps `NONE` when compression saves nothing or exceeds the permitted expansion
ratio. Core releases older than this
change refuse compressed sweep records at ingest, and agents and gateways do
not negotiate a codec yet. Upgrade core and every agent-gateway replica first,
confirm each replica is ready on the new version, and only then upgrade the
canary agent. To roll back, downgrade the agent first. Records it has already
spooled stay compressed, so a core or gateway rollback must wait until the
agent has delivered them. Broad mixed-version rollout is not certified until
codec negotiation exists.

This wiring prepares the current-epoch sweep path. A successful deployment is
proved by fresh scheduled executions, committed edge-record ledger entries and
normal sweep host results from the same execution after the rollout, followed
by a check that the agent's spool stays within its bound. Pod readiness alone
does not prove this path. The full reconnect, audit-publication and fault-drill
milestones remain tracked in `unify-sweep-results-proto`.

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

### RFC3164 sender time zones

Set `logCollector.rfc3164Timezone` to an IANA zone such as `America/New_York`
when syslog senders omit their time zone. Docker Compose uses the equivalent
`input.rfc3164_timezone` setting in `docker/compose/flowgger.docker.toml`.
Both default to UTC. Messages with an explicit zone retain that zone.

EventWriter uses receive time when an RFC3164 timestamp differs from it by more
than one hour in either direction. This also applies to delayed RFC3164 messages.
The parsed timestamp is retained as `_syslog_original_timestamp` in log
attributes, with `_syslog_timestamp_fallback=true`. RFC5424 timestamps and
RFC3164 timestamps within one hour are unchanged. Existing stored rows are not
rewritten.
