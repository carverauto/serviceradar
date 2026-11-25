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
pull anonymously, so no registry login is needed. Release packaging fills
`image.digests` from the verified image promotion receipt, so published chart
packages select exact first-party image contents. CNPG preserves its version tag
alongside its digest. The source chart keeps an empty digest map for development.
Older packages retain their original tag defaults.

A release chart is uploaded to the disposable build project and promoted only
after checking its protected image dependencies. Its `files/artifact-bundle.json`
records those dependency references for supported-release inventory. Packaging
uses a temporary copy and does not modify the release checkout.

To deliberately replace a component image, set its `image.digests.<service>` to
the desired digest. Changing its tag alone does not override a packaged digest;
clear that specific digest explicitly when a development tag override is intended.
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
| `image.digests.<service>` | Component digest, overriding tags; populated in release packages | `{}` in source chart |
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
| `networkPolicy.ingress.allowedPorts` | Application ingress ports allowed from same-namespace / allowed namespace / allowed CIDR peers. When the log collector's TCP listener is enabled, the chart also admits its port (`logCollector.tcpCollector.service.ports.syslog.targetPort`), so it need not be listed here | ServiceRadar defaults excluding ERTS |
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
| `nvr.enabled` | Render the `serviceradar-nvr` StatefulSet (runtime and health probes only; recording pools are not enrolled). Requires `nvr.storage.storageClassName` and one distinct `nvr.storage.storageIds` UUID per ordinal. See [NVR runtime and replicated storage](../../docs/nvr-runtime.md) | `false` |
| `nvr.ingest.enabled` | With `nvr.enabled`, mount the private mTLS ingest listener on each NVR replica (`nvr.ingest.port`, default `8443`) and the matching client credentials on `serviceradar-core`, and add a network-policy rule letting `serviceradar-core` reach that port. Requires distinct pre-provisioned Secrets: `nvr.ingest.configSecretName` (`config.json`), `tokenSecretName` (`ingest-token`), `tlsSecretName` (`tls.crt`, `tls.key`, `ca.crt`) and the same three under `nvr.ingest.client`; server and client TLS Secrets must differ. `nvr.ingest.client.cameraRecordingEnabled` additionally permits explicit one-shot capture and enables policy-driven [continuous recording](../../docs/nvr-ingest.md#continuous-recording) for cameras with `mode == :continuous`. See [Private NVR recording input](../../docs/nvr-ingest.md) | `false` |
| `nvr.read.enabled` | With `nvr.enabled`, mount the private mTLS playback read listener on each NVR replica (`nvr.read.port`, default `8444`, distinct from `8095` and `nvr.ingest.port`; `nvr.read.playbackReadSlots`, default `8`, 1 through 64) and the matching client credentials on `serviceradar-web-ng`, and add a network-policy rule letting only `serviceradar-web-ng` reach that port. Requires distinct pre-provisioned Secrets: `nvr.read.configSecretName` (`config.json`), `tokenSecretName` (`read-token`), `tlsSecretName` (`tls.crt`, `tls.key`, `ca.crt`) and the same three under `nvr.read.client`; server and client TLS Secrets must differ, read token Secrets must differ from ingest token Secrets, and `nvr.read.client.tlsSecretName` must differ from ingest TLS Secrets. See [Playback read listener](../../docs/nvr-ingest.md#playback-read-listener) | `false` |
| `nvr.archive.enabled` | With `nvr.ingest.enabled`, let Core ask an NVR replica to upload a sealed block to an S3-compatible bucket through Longshore and verify it by readback. Applies `nvr.archive.seccompProfile` (`RuntimeDefault` or `Localhost` with a relative `localhostProfile`; `Localhost` adds the node selector `serviceradar.io/media-storage-node-prepared: "true"`) and lets the NVR pods reach `nvr.archive.providerEgress.cidrs` (required, explicit CIDRs) on `providerEgress.port` (default `443`). No bucket credential is mounted: Core sends it with each request. See [Archive upload](../../docs/nvr-runtime.md#archive-upload) | `false` |
| `nvr.maxDurationMs` | Longest NVR recording session and ingest request, including its seal (`SERVICERADAR_NVR_MAX_DURATION_MS`, at most 300000). The default is the ceiling so a 270-second Core capture fits; the service's own default without the chart is 30000. See [Private NVR recording input](../../docs/nvr-ingest.md#bounded-relay-coordinator) | `300000` |
| `nvr.maxBlockFragments` | Fragments (about 2 s each) per local NVR block before rotation (`SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS`, 8 through 256; the chart refuses other values). Blocks also rotate at 16 MiB. 150 keeps one 270-second Core capture in one block, about 320 blocks per camera per day for a low-bitrate stream; blocks are not reclaimed yet. Lowering it affects new blocks only. See [NVR runtime and replicated storage](../../docs/nvr-runtime.md) | `150` |
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
| `nats.jetstream.profile` | JetStream sizing profile (`compact`, `small`, `medium`, `large`, `tenant-2g`) supplying `max_file_store` and every stream size below; the chart fails at render time when the reservations exceed 85% of `max_file_store` or `max_file_store` exceeds 94% of `nats.persistence.size`. See [JetStream sizing values](../../docs/docs/helm-configuration.md) and `docs/nats-jetstream-profile-runbook.md` | `small` |
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
- For runtime certificate and NATS signing key provisioning on install and upgrade, see the [in-chart certificate generator](../../docs/docs/tls-security.md#in-chart-certificate-generator).
- The chart does not generate image pull secrets. Published images pull anonymously, so none is required; set `image.registryPullSecret=""` to drop the default `registry-carverauto-dev-cred` reference, or create that secret (or override the name) when pulling through an authenticated mirror. Keep a real secret name there if you enable `argocdImageUpdater.pullSecretReader`, whose Role needs one.
- The in-cluster agent writes mutable checker config, cache files, and managed release payloads under `/var/lib/serviceradar`; keep the default PVC-backed `agent.*Storage` settings enabled in Kubernetes production environments.

### CNPG telemetry retention

Installs that keep telemetry in CNPG set retention under `core.observabilityRetention`. `DataRetentionWorker` reconciles the Timescale policies on its nightly run. When StarRocks is enabled it remains the telemetry store, and `analytics.starrocks.retentionDays` is unchanged by these keys.

`defaultDays` is optional. Leave it unset and each dataset keeps its own window. Set it to cap raw CNPG telemetry at that many days. A per-dataset value may be shorter. The ceiling takes effect on the next `DataRetentionWorker` run. Migrations install the per-dataset values until that run. Capacity forecasts stay on `capacityForecastsDays`. Hourly rollups never go below 7 days, because their refresh window is 5 days. Chunk intervals must stay smaller than the applied retention. Continuous-aggregate refresh windows stay strictly inside the source retention.

Raw `timeseries_metrics` is the largest CNPG telemetry table, and it is only small once compressed. `timeseriesMetricsChunkIntervalHours` sets the size of new chunks and `timeseriesMetricsCompressAfterHours` sets how long a closed chunk waits before the hourly compression job takes it. The worker also turns compression on when the table has none. A database bootstrapped from a schema baseline older than the one that carries TimescaleDB compression settings and policy jobs starts that way; a new install already has compression and the worker leaves it unchanged. The job then compresses the existing backlog one chunk at a time. Each chunk needs free space for its compressed copy and the sort's temporary files, so on a nearly full volume grow the PVC before that run.

Flow records (NetFlow, sFlow, IPFIX, and process attribution) are stored only in StarRocks. Migration `20261019160000` dropped `platform.ocsf_network_activity`, so `ocsfNetworkActivityDays` and `ocsfNetworkActivityChunkIntervalHours` no longer govern a live CNPG hypertable and `defaultDays` does not apply to them. They remain for the older migration that still reads them.

The migration-only tables (`adhocScanResultsDays`, `serviceStatusDays`, `endpointInventoryHistoryDays`) and rollup aggregates (`spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`) are reconciled retention-only: their chunk intervals and compression stay as migrations installed them. Before a shorter retention applies, the worker clamps the refresh `start_offset` of `endpoint_inventory_package_counts_hourly`, `endpoint_inventory_cpe_counts_hourly`, `services_availability_5m`, and `otel_metrics_hourly_stats` strictly inside it, and floors each aggregate's own retention at that clamped window. `endpointInventoryHistoryDays` and `tracesStatsDays` are not capped by `defaultDays`. `tracesStatsDays` is the explicit value, or 14 days when omitted, floored at the clamped refresh window. The worker sets `traces_stats_5m` to that target whatever window is installed. A later run leaves an installed value that already equals it, including 14 days and shorter.

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
| `core.observabilityRetention.timeseriesMetricsChunkIntervalHours` | Chunk interval for new raw `timeseries_metrics` chunks | `4` |
| `core.observabilityRetention.timeseriesMetricsCompressAfterHours` | Hours a closed raw `timeseries_metrics` chunk stays uncompressed | `2` |
| `core.observabilityRetention.capacityForecastsDays` | Capacity forecast retention. Not capped by `defaultDays` | `395` |
| `core.observabilityRetention.hourlyRollupDays` | Hourly rollup retention. Floored at 7 days | `395` |
| `core.observabilityRetention.adhocScanResultsDays` | Ad-hoc scan result retention | `30` |
| `core.observabilityRetention.serviceStatusDays` | `service_status` and `events` retention | `14` |
| `core.observabilityRetention.endpointInventoryHistoryDays` | Endpoint inventory scan/package history retention. Not capped by `defaultDays` | `395` |
| `core.observabilityRetention.spansRedDays` | `spans_red_1h` aggregate retention | `90` |
| `core.observabilityRetention.otelMetricsHourlyStatsDays` | `otel_metrics_hourly_stats` aggregate retention | `90` |
| `core.observabilityRetention.tracesStatsDays` | `traces_stats_5m` aggregate retention. Not capped by `defaultDays`. Omit for the 14-day migration window | unset |
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

### Durable edge-record pipeline

The durable edge-record pipeline is always on and has no chart values. The
chart fails to render when any `edgeRecords` key is set; delete the block from
your values before upgrading (see "Upgrading from the static registry" in
`docs/docs/data-pipeline.md`).

- **Core** derives its contract registry from the release's contract catalog
  and signs each registry epoch with its edge issuer key. It issues a standing
  grant for a catalog contract when the contract is in the signed active
  epoch, the core node's release catalog holds its exact bundle, and the
  agent's partition has a row. It leases sweeps to every agent whose partition
  resolves and whose Hello advertises sweep lease plan checks. There is no
  leasing switch.
- **The gateway** installs the signed epochs from core's trust document,
  verifies each signature, and admits a record only against the exact epoch it
  names. It always runs the edge-record publisher, so it always connects to
  NATS, and its NATS identity may always publish the primary, audit and
  security-quarantine edge-record routes, in the broker's static users and in
  core's authorization callout grants alike.
- **The agent** always runs its edge-record sender and spool. Each producer
  emits edge records exactly while it holds core's grant for its contract and
  holds its data otherwise; the gateway refuses durable data on the status
  RPCs. Core sends the spool byte budget in the
  agent config. The bundled agent's config names only the spool directory,
  `<agent.runtimeStorage.basePath>/edge-records`, so the spool stays on the
  agent runtime volume. Keep `agent.runtimeStorage.enabled` on: with it off,
  the spool sits on an `emptyDir` and unsent records are lost when the pod is
  replaced.

**Issuer key.** Core stores its issuer key in CNPG, encrypted with the cloak
key. The first boot that finds no stored key imports the `edge-issuer-seed` of
the secrets Secret, which the secret generator creates once and preserves on
upgrade. For this release core mounts that seed and sets
`SERVICERADAR_EDGE_ISSUER_KEY_FILE` whenever the chart's secret generator
manages the Secret, so an installation that signed with the file key keeps it.
From then on the stored key wins, and changing the Secret value does not rotate
it. A mounted seed that is not a private, well-formed seed stops core from
storing a key; core never generates a replacement for it. With
`secrets.autoGenerate=false` the chart does not mount the seed and core
generates its own key. The release after this one removes the mount and the
Secret key.

Flow-attribution windows and OTLP relay frames use the same spool while the
agent holds a current `serviceradar.netprobe.flow_attribution` version 1 or
`serviceradar.otlp.relay` version 1 grant. Results of sweep groups the agent
runs from its own config, without a lease, move to edge records only when the
agent also holds a `serviceradar.sweep.unleased_results` version 1 grant; each
results response and its metric batch then take the edge path together, and
otherwise the agent holds both. Full traces from agent-scheduled MTR checks
travel as edge records only when the agent also holds a
`serviceradar.mtr.scheduled_trace` version 1 grant; the metrics grant does not
carry them. The gateway rejects records for any contract the signed epoch they
name does not carry.

Leased sweeps use complete terminal ICMP/TCP host windows. Partial-mode and MTR
windows are not supported by this projection yet. A stale-fence record that
carries a valid delivery grant is published on the audit route; see
`docs/edge-record-quarantine-runbook.md`. The sender persists terminal
resolutions and reclaims a fully drained segment when durable dispositions
cover every retained sequence. Permanently rejected records are copied into a
bounded local quarantine in the lane directory before that reclaim; the
policy, including eviction when the quarantine is full, is the interim local
quarantine in `openspec/changes/unify-sweep-results-proto/design.md`.
Retryable and unspecified dispositions, and unresolved records, stay on the
segment. Partial-tail compaction is not implemented. Reaching the spool budget
stops further appends. Quarantine occupancy, permanent rejections and
quarantine drops are counted on the agent's `/metrics` endpoint beside the
unresolved-byte and age gauges. An interrupted run remains incomplete and is
not rescanned once a record from that run has been admitted. A first append
the spool refuses for admission writes nothing and leaves the slot runnable,
so the executor can try the slot again. Any other first-append failure keeps
the slot consumed.

**Upgrade order.** Upgrade core and every agent-gateway replica first, confirm
each replica is ready on the new version, and only then upgrade the agents.
The agent compresses each sweep or sysmon metrics payload as one Zstandard
level 1 frame by default, and older core releases refuse compressed records at
ingest; agents and gateways do not negotiate a codec yet. Do not downgrade an
agent that has reclaimed its spool: reclamation turns `lane.seg` into a
symlink to a data directory, and older agent binaries refuse to open that
layout, which stops backlog delivery. Rolling back across the release that
made the pipeline always on is unsupported.

A successful deployment is proved by fresh scheduled executions, committed
edge-record ledger entries and normal host results from the same execution
after the rollout, followed by a check that the agent's spool stays within its
budget. Pod readiness alone does not prove this path.

### Camera semantic search worker

`mediaWorker` deploys `serviceradar-media-worker`, which embeds keyframes of
recorded camera blocks with SigLIP and answers the query embeddings behind
camera semantic search. It is off by default and runs outside the BEAM
cluster: jobs and results travel on NATS JetStream, recording bytes come
through short-lived read grants from web-ng, and it has no CNPG or StarRocks
access.

**Current limits.**

- The worker decodes H.264 single-slice IDR keyframes (Constrained Baseline,
  Main and High profile, 8-bit 4:2:0, progressive; see
  `rust/media-worker/README.md`). HEVC, multi-slice pictures and a few other
  stream variants are not decoded: each such keyframe is recorded as
  undecodable with its reason (`unsupported_codec` and so on, counted in
  `serviceradar_media_worker_keyframes_undecodable_total`) and is not indexed.
- Whole-scene indexing is the default when `mediaWorker.models.detectorPath` is
  unset: the chart mounts only the three SigLIP files into the model directory,
  so unconfigured detector files on the PVC stay invisible. Setting
  `mediaWorker.models.detectorPath` (and optional `detectorConfigPath` /
  `detectorSha256`) mounts the `yolox-s` detector weights and config via
  `subPath` so object detection runs alongside SigLIP.
- Local (not yet archived) recordings cannot be read yet, because the NVR has
  no analysis-read listener.

| Value | Purpose | Default |
| --- | --- | --- |
| `mediaWorker.backend` | `candle` runs SigLIP from the weights in `models.existingClaim`. `stub` emits deterministic fake embeddings for pipeline tests only; it is used only when set explicitly and requires `executionProvider: cpu_explicit` | `candle` |
| `mediaWorker.models.existingClaim` | PVC holding the SigLIP `config.json`, `model.safetensors` and `tokenizer.json` (and optionally `yolox-s` `detector.safetensors` + `detector_config.json`) at its root. Only those three SigLIP files are mounted, read-only and one by one, into `models.mountPath`, which is passed as `MEDIA_WORKER_MODEL_DIR`, unless `models.detectorPath` is set (which additionally mounts `detectorPath` and `detectorConfigPath` via `subPath`); restart the worker after replacing them. Nothing is downloaded or bundled. Running `replicas > 1` across multiple nodes requires a multi-node read access mode (`ReadOnlyMany` or `ReadWriteMany`); a `ReadWriteOnce` volume cannot attach to two nodes at once even when mounted read-only | `""` |
| `mediaWorker.models.detectorPath`, `detectorConfigPath`, `detectorSha256` | Optional `yolox-s` detector weights and config paths inside `models.mountPath` (default `detectorConfigPath`: `<mountPath>/detector_config.json`). When `detectorPath` is set without `detectorSha256`, both files are mounted for `MEDIA_WORKER_MODEL_DIR` auto-discovery; when `detectorSha256` is set, both `SERVICERADAR_MEDIA_WORKER_DETECTOR_PATH` and `SERVICERADAR_MEDIA_WORKER_DETECTOR_SHA256` are emitted and verified at startup. Paths containing `yolov8`, `rtdetr`, or `..` are refused | `""`, `""`, `""` |
| `mediaWorker.executionProvider` | `cuda` or `cpu_explicit` (`tensorrt` is refused because the worker does not support it). The worker refuses to start rather than fall back to CPU. `cuda` needs a GPU node, its runtime class and the CUDA image (below); the chart refuses `cuda` on the release's CPU image and refuses `backend: stub` under any provider other than `cpu_explicit` | `cuda` |
| `mediaWorker.dtype` | Weight precision (`MEDIA_WORKER_DTYPE`): `auto` (f16 on CUDA, f32 on CPU), `f32` or `f16`. The worker loads the SigLIP weights in the configured dtype (see `rust/media-worker/README.md`). Under `cpu_explicit`, the chart refuses `f16` as a performance policy (half precision on CPU is slower than `f32` with no benefit); use `auto` or `f32` | `auto` |
| `mediaWorker.cudaCache.sizeLimit`, `existingClaim` | Under a GPU provider, a writable compiled-kernel cache (about 350 MB) is mounted at `/var/cache/serviceradar-media-worker/cuda` and passed as `CUDA_CACHE_PATH`, since the root filesystem is read-only and `/tmp` is small: an `emptyDir` of `sizeLimit`, or `existingClaim` to keep it across restarts. When running `replicas > 1` across multiple nodes, a shared persistent `existingClaim` must support `ReadWriteMany` (a `ReadWriteOnce` volume cannot attach to two nodes at once), or leave `existingClaim` empty to use the default per-pod `emptyDir` cache. The image's other CUDA settings (`LD_LIBRARY_PATH`, `CUDA_CACHE_MAXSIZE`, `NVIDIA_DRIVER_CAPABILITIES`) are left as built | `1Gi`, `""` |
| `mediaWorker.device` | Candle device. Empty derives `cuda` for `cuda` and `cpu` for `cpu_explicit`. `cuda` accepts `cuda` or `auto`; `cpu_explicit` accepts only `cpu` | `""` |
| `mediaWorker.runtimeClassName`, `gpuResourceName`, `gpuCount` | GPU scheduling. `cuda` needs a runtime class and requests `gpuCount` (at least 1) of `gpuResourceName`; `cpu_explicit` requests no GPU | `""`, `nvidia.com/gpu`, `1` |
| `mediaWorker.replicas` | Worker pods; `0` is honoured. A single-replica GPU worker (`replicas <= 1`) uses the `Recreate` strategy because a pool without a spare GPU cannot schedule a rolling update's surge pod. Multi-replica GPU workers (`replicas > 1`) use `RollingUpdate` with `maxSurge: 0` and `maxUnavailable: 1` to roll one GPU pod at a time without surging, and default to spreading pods across `kubernetes.io/hostname` (`maxSkew: 1`, `ScheduleAnyway`). A `cpu_explicit` worker uses `RollingUpdate`. Placing multiple replicas on separate GPU nodes requires multi-node read access (`ReadOnlyMany` or `ReadWriteMany`) for `models.existingClaim` and either `ReadWriteMany` for `cudaCache.existingClaim` or the default per-pod `emptyDir` cache | `1` |
| `mediaWorker.nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`, `resources` | Placement and size (`topologySpreadConstraints` overrides the default hostname spread and global `topologySpread`) | |
| `mediaWorker.image.repository`, `tag`, `digest` | Empty selects the release's CPU build (`serviceradar-media-worker` at the release tag, or `image.digests.mediaWorker`), which runs only `cpu_explicit`. The GPU build is the separate repository `<image.registry>/serviceradar-media-worker-cuda` (arm64), published only under `sha-<commit>` tags by a manually dispatched workflow and never under a release tag: set `repository` to it and `tag` to the tag that workflow produced, or `digest`. The image must include the worker's dedicated NATS inbox support (`SERVICERADAR_MEDIA_WORKER_NATS_INBOX_PREFIX`, added with this chart change): an older build ignores it, uses the account-wide `_INBOX`, and the broker denies its JetStream replies and pull deliveries. Any repository other than the release's needs its own `tag` or `digest` and never inherits `image.digests.mediaWorker`, which the published chart sets to the CPU build | `""` |
| `mediaWorker.auth.existingSecret`, `tokenKey`, `deploymentRef`, `generation` | The worker's read-grant credential. When using this release's web-ng, both workloads must use the same Secret, key, deployment reference and generation | `""`, `media-worker-token`, `""`, `"1"` |
| `mediaWorker.networkPolicy.allowNvrRead`, `nvrReadPort` | Network preparation for local-recording reads: opens the worker's egress to the NVR pods and their ingress from it on `nvrReadPort`. The NVR analysis-read listener does not exist yet, so these reads still fail. When `nvr.enabled` and `allowNvrRead` are true, `nvrReadPort` must target a dedicated analysis-read port distinct from web-ng's enabled playback read port (`nvr.read.port`, default `8444`) and core's enabled ingest port (`nvr.ingest.port`, default `8443`); the chart refuses a collision | `false`, `8444` |

The model identity is not configurable. Core stamps its compiled identity
(embedder `siglip-b16-384` `2026.1`, detector `yolox-s` `2026.1`, 768
dimensions) on every job and search request and has no setting for it, so the
chart pins the worker to the same values and refuses
`mediaWorker.models.embedderModelId`, `embedderModelVersion`,
`detectorModelId`, `detectorModelVersion` and `embeddingDim` while the worker
is enabled. At startup
the worker verifies that the loaded SigLIP checkpoint emits the pinned 768
dimensions and refuses a mismatched checkpoint.
`media_worker_model_identity_test.py` fails when core and the chart drift.
The chart sets `SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED` to match
`mediaWorker.enabled` and reserves it in `core.extraEnv` and
`core.extraEnvValueFrom`. Core relays visual-index jobs and subscribes to
`CAMERA_MEDIA_RESULTS` only when both
`SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED=true` and
`SERVICERADAR_CAMERA_RECORDING_ENABLED=true` (emitted when `nvr.enabled`,
`nvr.ingest.enabled`, and `nvr.ingest.client.cameraRecordingEnabled` are all
true).

The chart refuses to render, instead of producing a pod that crash-loops, when:

- `mediaWorker.enabled` or any of the `mediaWorker.networkPolicy` flags
  (`enabled`, `operatorManaged`, `allowNvrRead`) is not a YAML boolean (a
  `--set-string` value is truthy in templates whatever it says, so it is
  refused and every template reads the same value);
- `mediaWorker.replicas` or `gpuCount` is not a whole number >= 0 (a fraction
  is refused rather than truncated);
- `mediaWorker.executionProvider` is not `cuda` or `cpu_explicit` (including
  `tensorrt`, which the worker does not support), or `mediaWorker.backend` is
  `stub` with any execution provider other than `cpu_explicit`;
- the `candle` backend has no `models.existingClaim`;
- a GPU provider has no `runtimeClassName` or `gpuCount` below 1, or `device`
  contradicts the provider;
- `cpu_explicit` has a GPU entry anywhere in `resources`: `gpuResourceName`,
  any `nvidia.com/` resource (which covers MIG slices) or any name containing
  `gpu`;
- the control plane is this release's web-ng and anything about it is wrong.
  The URL is compared after lower-casing the scheme and host, dropping a DNS
  root dot and supplying the scheme's default port; a root dot on anything but
  a full `.svc.cluster.local` name is refused, since the resolver would not
  find it. A host naming
  `serviceradar-web-ng` or `serviceradar-web-ng-headless` (optionally followed
  by the release namespace, `.svc` and `.cluster.local`) is this release's
  web-ng, and then web-ng must be enabled, the URL must be
  `http://serviceradar-web-ng-headless...:<webNg.controlPlaneRuntime.port>`
  with no path, query or fragment (the ClusterIP Service does not expose that
  port, and the listener serves plain HTTP), `webNg.controlPlaneRuntime.mediaWorker`
  must be enabled, its deployment reference and generation must equal
  `mediaWorker.auth`'s, and both must reference the same token Secret and key.
  Two Secrets holding identical bytes are deliberately not supported: a
  rotation would update one and leave the other behind. Any other host is
  treated as a remote control plane and left to the operator;
- a GPU provider uses the release's CPU image (the configured
  `image.registry` copy or the published
  `registry.carverauto.dev/serviceradar/serviceradar-media-worker`), or a
  non-release repository has neither a tag nor a digest;
- `mediaWorker.networkPolicy.enabled` is false without
  `mediaWorker.networkPolicy.operatorManaged: true`;
- `mediaWorker.networkPolicy.allowNvrRead` is true while `nvr.enabled` is true
  and `mediaWorker.networkPolicy.nvrReadPort` equals an enabled `nvr.read.port`
  (default `8444`, reserved for web-ng playback reads) or `nvr.ingest.port`
  (default `8443`, reserved for core ingest);
- an enabled web-ng control-plane listener's `webNg.controlPlaneRuntime.port`
  collides with another web-ng listener (the
  public listener 4000, the metrics port, or Erlang distribution 4369 and
  9100), or `SERVICERADAR_CONTROL_PLANE_RUNTIME_PORT`, `PORT` or
  `SERVICERADAR_METRICS_PORT` is set through `webNg.extraEnv` or
  `extraEnvValueFrom` (every web-ng listener port has one source, the one the
  collision check reads);
- the worker's streams do not fit JetStream (below).

The retired identity keys (`models.embedderModelId`, `embedderModelVersion`,
`detectorModelId`, `detectorModelVersion`, `embeddingDim`) are refused while
`mediaWorker.enabled` is true (installs with
the worker disabled are unaffected, including `helm upgrade --reuse-values`
from an earlier chart). When upgrading with the worker enabled from an earlier
chart, `helm upgrade --reuse-values` carries their old defaults forward and is
refused: upgrade with the new chart's defaults and reapply your own overrides,
without those keys (for example
`helm upgrade ... --reset-values -f my-values.yaml`). If your existing overrides
also set `mediaWorker.models.embedderPath`, `embedderSha256`, `textPath`, or
`textSha256`, verify them before upgrading: because the chart now projects only
`config.json`, `model.safetensors`, and `tokenizer.json` from the root of
`models.existingClaim` into `models.mountPath` (instead of mounting the whole
PVC), any `embedderPath` or `textPath` pointing to another filename or
subdirectory on the PVC is no longer visible in the container and fails startup
digest verification. Update those overrides to point at the projected files
under `models.mountPath` with matching `embedderSha256` / `textSha256` digests,
or remove them.

**JetStream.** The worker creates `CAMERA_MEDIA_JOBS` (512 MiB) and
`CAMERA_MEDIA_RESULTS` (2 GiB), one replica each, at sizes the chart cannot
change. While it is enabled the chart counts both in the JetStream storage
budget, so a profile without room fails the render (raise the profile or
`nats.jetstream.maxFileStore`, see `docs/nats-jetstream-profile-runbook.md`).
A profile whose `max_file_store` is below 2 GiB, such as `tenant-2g`, cannot
hold the results stream at all and is refused even with
`nats.jetstream.allowOvercommit`.

The chart counts the two streams only while the worker is enabled, but the
streams themselves outlive it: disabling the worker leaves both in JetStream,
still reserving up to 512 MiB and 2 GiB of file storage (one replica each)
although the budget no longer counts them. Before shrinking JetStream or giving
that room to another stream, either delete them from a NATS tools pod:

```bash
nats stream rm CAMERA_MEDIA_JOBS -f
nats stream rm CAMERA_MEDIA_RESULTS -f
```

or keep about 2.5 GiB of budget headroom for them. `nats stream ls` shows
whether they still exist. A re-enabled worker creates them again.

**NATS identity.** Enabling the worker makes the runtime certificate generator
issue `media-worker.pem` (`CN=serviceradar-media-worker`). An existing runtime
Secret missing either file of the pair, or holding a worker certificate from a
previous root, triggers reissue of the runtime leaves under the current root
on upgrade. The worker mounts only `root.pem` and
its own pair and connects with mutual TLS; the broker maps the certificate to a
static user that may:

- publish `media.results.visual_index.v1` and
  `telemetry.media_worker.metrics.v1`;
- get or create the `CAMERA_MEDIA_JOBS` and `CAMERA_MEDIA_RESULTS` streams, and
  get, create and pull its two durable job consumers and acknowledge their
  deliveries;
- subscribe to `media.rpc.visual_text_embed.v1.>` and to its own inbox prefix,
  `_INBOX.media-worker.>` (`SERVICERADAR_MEDIA_WORKER_NATS_INBOX_PREFIX`), but
  not to the account-wide `_INBOX.>`, which carries other services' JetStream
  deliveries;
- publish to `_INBOX.>`. This is still account-wide: the worker answers each
  embedding request on web-ng's reply subject, and web-ng draws every reply
  subject from its one connection-wide `_INBOX.` prefix. Narrowing it needs a
  dedicated reply prefix for those requests in web-ng (follow-up).

Follow-ups: a dedicated web-ng reply prefix for embedding requests (to narrow
the worker's `_INBOX.>` publish), HEVC and multi-slice keyframe decoding, the
NVR analysis-read listener, and a subject detector enabled by an explicit chart
setting.

Core may publish `media.jobs.visual_index.v1` and
`media.jobs.visual_index.backfill.v1` regardless of `mediaWorker.enabled`. With
the worker on, web-ng and core (for `VisualCaptionWorker`) may publish
`media.rpc.visual_text_embed.v1.>`. With it
off, the worker identity is refused everything and neither web-ng nor core gets
the text-embed RPC grant. The first upgrade to a chart
that includes this static user rolls the chart-managed NATS pods even with the
worker disabled, because their configuration now includes the deny-all entry.

**Network isolation.** The worker is isolated at its source. Its own
NetworkPolicy (`serviceradar-media-worker`) denies all egress except DNS, NATS,
web-ng's private control-plane port, the OTLP collector, the NVR read port when
`allowNvrRead` is set, and HTTPS to public object storage
(`mediaWorker.networkPolicy.s3EgressCidrs` minus `s3ExceptCidrs`). It is
rendered whenever the worker is enabled, regardless of the top-level
`networkPolicy.enabled`. Every chart policy that selects broadly and grants
egress leaves the worker out: `serviceradar-egress` (whatever base selector is
configured, including `podSelectorMatchAll`) and the Calico
`networkPolicy.calicoLogDenied` policy. Since policies only add permissions,
the worker's own policy is then the only chart policy that governs its egress.
The chart does not touch database ingress for this.

The guarantee, exactly: on a cluster whose CNI enforces egress NetworkPolicy,
no policy rendered by this chart that selects the media worker allows it to
open a connection to PostgreSQL, the pooler or any destination outside that
allowlist. The chart does not constrain policies an operator adds, and offers
no isolation on a CNI that does not enforce egress policy, or when
`mediaWorker.networkPolicy.enabled` is false with
`mediaWorker.networkPolicy.operatorManaged: true`, which states that the
operator supplies and owns the worker's isolation.
`media_worker_egress_isolation_test.py` checks this over the default, demo,
tenant and HA values.

With `mediaWorker.networkPolicy.enabled: false` and `operatorManaged: true`,
the chart also stops rendering the matching ingress
exception on web-ng (`serviceradar-media-worker-control-ingress`), which lets
the worker reach web-ng's private control-plane port
(`webNg.controlPlaneRuntime.port`, 4001 by default) when
`networkPolicy.enabled` restricts web-ng's ingress; that port is not in the
namespace-wide ingress allowlist. The operator's policies must then also admit
the worker to web-ng on that port, or every recording read grant times out.

**Enabling it.** Create these in the release namespace first; Helm creates
neither:

1. The weights PVC named by `mediaWorker.models.existingClaim`, with the SigLIP
   files above at its root. If you run `mediaWorker.replicas > 1` across
   multiple nodes, provision `models.existingClaim` with `ReadOnlyMany` or
   `ReadWriteMany` (not `ReadWriteOnce`, which cannot attach to two nodes even
   for a read-only mount), and for `mediaWorker.cudaCache.existingClaim` either
   use `ReadWriteMany` or leave it unset to keep the default per-pod `emptyDir`
   cache.
2. The token Secret named by both `mediaWorker.auth.existingSecret` and
   `webNg.controlPlaneRuntime.mediaWorker.existingSecret`. Generate the token on
   stdin so it never appears in a process argument or the terminal:

   ```bash
   openssl rand -hex 32 | tr -d '\n' | kubectl -n <namespace> create secret generic \
     serviceradar-media-worker-auth --from-file=media-worker-token=/dev/stdin
   ```

Then set `mediaWorker.enabled` and `webNg.controlPlaneRuntime.mediaWorker.enabled`
together, ensure camera recording is enabled on core so it relays jobs and
subscribes to `CAMERA_MEDIA_RESULTS` (`nvr.enabled`, `nvr.ingest.enabled`, and
`nvr.ingest.client.cameraRecordingEnabled` all true, which emits
`SERVICERADAR_CAMERA_RECORDING_ENABLED=true`), select the CUDA image for `cuda`,
and, since the published CUDA image is arm64-only, place the
worker on arm64 GPU nodes (`mediaWorker.nodeSelector` with
`kubernetes.io/arch: arm64`, or equivalent affinity, as `values-demo.yaml`
does; a site-built amd64 image needs no such selector). Make sure the
JetStream budget has room for the worker's streams. The worker reports ready only after loading the model and warming up,
which on a first CUDA start takes about ten seconds plus the model load;
`/readyz` answers 503 until then while `/healthz` (liveness) stays healthy, so
the pod simply stays unready meanwhile.

If you switch an existing `serviceradar-media-worker` Deployment from
`RollingUpdate` (`executionProvider: cpu_explicit`, or a Deployment created by
an earlier chart) to a GPU provider (`Recreate`) using Server-Side Apply
(Helm 4 default or Argo CD `ServerSideApply=true`), the API server rejects the
update while its defaulted `spec.strategy.rollingUpdate` fields remain set.
Run this one-time merge patch first (or delete the Deployment before applying):

```bash
kubectl -n <namespace> patch deployment serviceradar-media-worker --type=merge -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```

**Rotating the read-grant token.** Both workloads read it from their
environment, so a new token reaches a pod only when it restarts, and a worker
holding a different token than web-ng gets no grants. Update the Secret, then
advance `mediaWorker.auth.generation` and
`webNg.controlPlaneRuntime.mediaWorker.generation` together in one upgrade,
which rolls both Deployments, and expect grants to succeed once both rollouts
finish.

The worker's certificate is one of the chart's NATS client identities
(`serviceradar.natsChartIdentities`) while the worker is enabled, so the
generator requires it and core adopts it from the chart's certificate inventory
on first sight, as it does the chart's other clients; with
`nats.certificateAuthorization.enabled` no manual adoption step is needed,
provided every previously recorded infrastructure certificate already has a
stored subject. If an existing infrastructure certificate on an upgraded
deployment lacks a stored subject, core pauses all first adoptions (including
`media-worker.pem`) and the worker cannot connect until you backfill each
missing subject using the
[original-PEM adoption procedure](../../docs/managed-component-certificates.md).
Its static NATS user supplies the
permissions once it is admitted.

**Hosted tenants.** A hosted tenant's chart is rendered by the control plane,
so each setting above needs a control-plane counterpart before the worker can
run there:

- the runtime certificate Secret, which the control plane writes, must include
  `media-worker.pem` and `media-worker-key.pem` with the exact subject
  `CN=serviceradar-media-worker,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US`,
  and list `media-worker.pem` in `certs.inventoryCertificates` so core adopts
  it (first adoption still requires every previously recorded infrastructure
  certificate to have a stored subject; if any lacks one, backfill it with the
  [original-PEM procedure](../../docs/managed-component-certificates.md) first).
  When disabling `mediaWorker.enabled` later, the hosted control plane must
  remove `media-worker.pem` from `certs.inventoryCertificates` in the same
  upgrade, even if it retains the certificate in the Secret, or template
  rendering fails because `media-worker.pem` is only an allowed inventory name
  while the worker is enabled;
- `mediaWorker.enabled` together with `webNg.controlPlaneRuntime.mediaWorker.enabled`,
  plus `nvr.enabled`, `nvr.ingest.enabled`, and
  `nvr.ingest.client.cameraRecordingEnabled` (so core receives
  `SERVICERADAR_CAMERA_RECORDING_ENABLED=true` and relays visual-index jobs);
- `mediaWorker.backend` and `device`;
- the weights PVC: provisioning it with the SigLIP files (with `ReadOnlyMany`
  or `ReadWriteMany` when running multiple replicas across nodes) and setting
  `models.existingClaim` (and `models.mountPath` if changed);
- image selection and pulling: `mediaWorker.image.repository`, `tag`, `digest`
  and `pullPolicy` (for GPU, the CUDA repository and the `sha-<commit>` tag its
  publish workflow produced);
- `mediaWorker.dtype` and `cudaCache.sizeLimit` or `cudaCache.existingClaim`
  (`ReadWriteMany` when shared across multiple nodes, or unset for the per-pod
  `emptyDir` cache);
- GPU placement and size: `executionProvider`, `runtimeClassName`,
  `gpuResourceName`, `gpuCount`, `nodeSelector`, `tolerations`, `affinity` and
  `resources`;
- `replicas`, `port` and the two `concurrency` settings;
- the optional artifact pins `models.embedderPath`, `embedderSha256`,
  `textPath` and `textSha256` (because only `config.json`, `model.safetensors`
  and `tokenizer.json` are projected into `models.mountPath`, any configured
  `embedderPath` or `textPath` must point to one of those mounted paths with a
  matching digest, or be removed when migrating from a whole-PVC mount);
- the endpoints: `controlPlaneUrl` (empty selects the tenant's own web-ng; a
  hosted deployment that serves read grants elsewhere sets it to that remote
  endpoint, which must also be reachable under the worker's network policy),
  `webNg.controlPlaneRuntime.port`, `natsUrl` and `otelEndpoint`;
- the read-grant identity: the token Secret, created in the tenant namespace,
  and its name and key in `mediaWorker.auth` and
  `webNg.controlPlaneRuntime.mediaWorker`, with the same `deploymentRef`
  (the installed deployment's identity) and `generation` in both;
- network access: `mediaWorker.networkPolicy.enabled` (and `operatorManaged`
  if the platform supplies the worker's policy, together with web-ng ingress
  from the worker on `webNg.controlPlaneRuntime.port`), `allowNvrRead`,
  `nvrReadPort`, `s3EgressCidrs` and `s3ExceptCidrs`;
- a JetStream sizing profile with room for the worker's streams (not
  `tenant-2g`).

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

A syslog record is stored under the sender's timestamp, with the receive time
as its observed timestamp. When the sender's clock looks wrong, the record is
stored under the receive time instead: an RFC3164 timestamp more than one hour
from the receive time in either direction (this also applies to delayed RFC3164
messages), or a zoned timestamp (RFC5424 and other formats with a zone) more
than 24 hours ahead of it or more than 30 days behind it. The comparison uses
whole seconds. The parsed timestamp is retained as
`_syslog_original_timestamp` in log attributes, with
`_syslog_timestamp_fallback=true`. EventWriter and the collector's normalized
output apply the same limits. Existing stored rows are not rewritten.

### Unified syslog collector

`logCollector` runs UDP syslog, optional TCP syslog, and OTLP in one Deployment.
`logCollector.tcpCollector.enabled` controls the TCP listener; `listen`, `format`
and `framing` configure its `[[inputs]]` entry in the shared Flowgger config.

For a custom TCP listen port, set the same numeric port in
`logCollector.tcpCollector.service.ports.syslog.targetPort`. Both internal
Service names then route to that listener. Set any enabled external TCP
Service's `targetPort` to the same port as well.

Both syslog transports publish through the same output to `logs.syslog` on
`events`. A different `tcpCollector.subject` fails rendering.

Use `logCollector.replicaCount` and `logCollector.resources` for the unified
workload. The legacy TCP-specific replica count, resources and stream replicas
are ignored. The `serviceradar-log-collector-tcp` Service remains an alias that
selects only pods labeled as TCP listeners, preserving the previous DNS name.
Its separate Deployment and ConfigMap are removed. Keep existing clients on
that alias during the image rollout; the primary Service can temporarily have
endpoints from the previous UDP-only image.

Enable the shared external Service with `logCollector.externalService.enabled`
and choose protocols with `ports.syslog.enabled` and `ports.syslogTcp.enabled`.
Legacy `tcpCollector.externalService.enabled` enables TCP on that shared Service
and retains its port settings. When only the legacy external Service is enabled,
its Service type, annotations and traffic policy are retained; when both are
enabled, the primary external Service settings take precedence. A pinned address
from either block is used, but conflicting addresses fail rendering. The chart
renders one external NetworkPolicy against the unified collector pods.
