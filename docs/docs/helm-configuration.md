---
sidebar_position: 8
title: Helm Deployment and Configuration
---

This guide shows how to deploy ServiceRadar via the bundled Helm chart. For sweep behavior, tuning, and concepts, see [Network Sweeps](./network-sweeps.md) and [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md).

:::note Chart version
`<chart-version>` below is a placeholder. Look up the current release before
deploying:

```bash
helm show chart oci://registry.carverauto.dev/serviceradar/charts/serviceradar | grep '^version'
```

This page deliberately does not name a specific version: a hardcoded example
goes stale silently, and readers reasonably copy it as fact.
:::

Install/upgrade
- Namespace: create once: `kubectl create ns serviceradar` (or change `namespace` in chart values).
- Deploy from the official OCI chart (recommended):
  - `helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <chart-version> -n serviceradar --create-namespace -f my-values.yaml`
- Deploy from a repo checkout (development):
  - `helm upgrade --install serviceradar ./helm/serviceradar -n serviceradar -f my-values.yaml`
- Quick overrides without a file: add `--set` flags (examples below).

OCI chart quick start
- Inspect chart metadata and defaults:
  - `helm show chart oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <chart-version>`
  - `helm show values oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <chart-version> > values.yaml`
- Image tags follow the chart by default:
  - If you leave `global.imageTag` empty (the default), every first-party
    ServiceRadar image uses the chart's `appVersion`. The chart and the
    application it deploys are released together, so this is normally what you
    want and needs no configuration.
- Pin images explicitly (immutable rollouts):
  - `--set global.imageTag="sha-<gitsha>"`, or pin per-service digests with
    `image.digests.*`.
- Track mutable images (staging/dev):
  - `--set global.imageTag="latest" --set global.imagePullPolicy="Always"`

HA profile overlay
- `values.yaml` stays conservative by default. Most stateful or queue-backed services start at `1` replica unless you opt into a larger topology.
- `helm/serviceradar/values-ha.yaml` ships as a purpose-named HA overlay. Apply it with `-f values-ha.yaml` as the starting point for a multi-replica deployment. (`values-demo.yaml` is a broader demo overlay that also raises replica counts.)
- The HA overlay runs these at `3` replicas:
  - `core`
  - `webNg`
  - `agentGateway`
  - `datasvc`
  - `logCollector`
  - `logCollector.tcpCollector`
  - `trapd`
- **flowCollector** stays at **`replicaCount: 1`** (IPFIX/NetFlow template state is process-local) with **Recreate** and a **1 GiB RWO data PVC** so rehome/ownership/readiness markers survive pod replacement. Stream HA is `config.stream_replicas` (JetStream), not pod count.
- `bmpCollector` is not scaled by the HA overlay unless another values file sets it.
- The profile disables PVC-backed local state for the multi-replica services above where shared NATS/JetStream state is the real source of truth (flow-collector is the deliberate exception).

Optional public endpoint inventory
- `k8sInventory.enabled` (default `false`) deploys a cluster-plane collector that
  maps LoadBalancer / Gateway API public addresses to Services, routes, and
  backend pods. Helm creates the ServiceAccount, read-only ClusterRole, and
  Deployment together—do not create the SA by hand for normal installs.
- Full IR workflow, Argo CD vs manual install notes, and RBAC details:
  [Kubernetes Public Endpoint Inventory](./k8s-public-endpoint-inventory.md).
- Demo values (`values-demo.yaml`) enable it with `clusterId: demo` once the
  `serviceradar-k8s-inventory` image is available for that release tag.

JetStream sizing values
- The shared `events` stream is created and reconciled by multiple services. The important knobs are:
  - `logCollector.streamReplicas`
  - `logCollector.streamMaxBytes`
  - `trapd.streamReplicas`
- Dedicated **`flows`** stream (owned by flow-collector; isolated from logs/OTEL on `events`):
  - `flowCollector.config.stream_name` (default `flows`)
  - `flowCollector.config.stream_replicas`
  - `flowCollector.config.stream_max_bytes` (default 10 GiB)
  - `flowCollector.config.stream_max_age_secs` (default 6h)
  - EventWriter consumers use concrete `flows.raw.<name>` leaves only; do not put
    ownership wildcards such as `flows.raw.>` / `flows.>` / `*.>` in collector
    subjects (collector validation rejects them). Host-slice subjects are not
    EventWriter flow consumers; attribution joining is out of scope for this chart.
- Datasvc owns the KV/object streams and now reconciles both replica count and reserved capacity:
  - `datasvc.jetstreamReplicas`
  - `datasvc.bucketMaxBytes` (default 4 GiB)
  - `datasvc.objectMaxBytes`
  - `datasvc.objectStoreBytes` (default 10 GiB)
- The example HA profile intentionally shrinks those reserved capacities compared to the generic chart defaults so `events` can run at `3` replicas without exhausting the JetStream account's file-store budget.
- Agent release object cleanup is enabled by default through `objectStoreRetention`; it keeps the most recently imported release plus any releases still referenced by active rollout state.
- `bmpCollector` is scaled to `3` pods in the example profile, but its dedicated causal-overlay stream still uses `bmpCollector.config.streamReplicas=1`. That is an explicit sizing choice, not a pod-level HA limitation.

Key values: workload identity (`spire`)
- `spire.enabled` defaults to `false`. The chart still issues runtime mTLS
  certificates without SPIRE (see [TLS Security](./tls-security.md)).
- Set `spire.enabled=true` to provision SPIFFE/SPIRE workload identities, and
  set `spire.trustDomain` to your environment's trust domain.

Key values: `sweep`

The chart exposes the full sweep configuration tree (`sweep.networks`,
`sweep.ports`, `sweep.modes`, `sweep.tcp.*`, `sweep.icmp.*`, and related tuning
knobs). Rather than duplicate that reference here, see:

- [Network Sweeps](./network-sweeps.md) — sweep concepts, modes, and behavior.
- [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md) — the
  per-knob reference for `sweep.tcp` SYN-scan tuning and conntrack mitigation.

Inspect the current defaults for your chart version with
`helm show values oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <chart-version>`.

Key values: edge gateway address
- `webNg.gatewayAddress`: Optional external gateway address for edge agents (`host:port`).
  - If unset, the chart derives it from `ingress.host` (port 50052).
  - If neither is set, it falls back to the in-cluster service name.

Key values: in-cluster agent storage
- `agent.checkersStorage`: PVC-backed checker config at `/var/lib/serviceradar/checkers`.
- `agent.cacheStorage`: PVC-backed agent cache at `/var/lib/serviceradar/cache`.
- `agent.runtimeStorage`: PVC-backed managed release runtime at `/var/lib/serviceradar/agent`.

Keep these enabled in production. The agent writes mutable config caches and
managed release payloads under `/var/lib/serviceradar`; without PVC-backed
storage those writes count against pod ephemeral storage and can trigger
evictions under disk pressure.

Example:

```yaml
agent:
  checkersStorage:
    enabled: true
    storageClassName: fast-rwo
  cacheStorage:
    enabled: true
    storageClassName: fast-rwo
    size: 1Gi
  runtimeStorage:
    enabled: true
    storageClassName: fast-rwo
    size: 5Gi
```

## Kubernetes NetworkPolicy (Recommended)

ServiceRadar stores and distributes network credentials (for example SNMP communities and API tokens) as part of discovery, polling, and inventory sync configuration. Even though the UI does not display secrets back to users, a compromised privileged account could still try to abuse configuration to trigger unexpected outbound traffic (for example by adding attacker-controlled targets and new discovery/polling profiles).

Enable an egress NetworkPolicy to reduce blast radius and make exfiltration harder. The bundled Helm chart can install a restrictive egress policy that:

- allows DNS (optional)
- allows in-namespace communication (optional)
- allows Kubernetes API server access (optional; auto-detects API endpoints via `lookup`)
- allows explicit destination CIDRs you provide (recommended)

Important notes:

- NetworkPolicy enforcement depends on your CNI (Calico, Cilium, etc). If your cluster does not enforce NetworkPolicy, enabling these values will not change runtime behavior.
- This policy applies to pods selected by `networkPolicy.podSelector` (or all pods in the namespace when `podSelectorMatchAll: true`).
- Edge hosts running `serviceradar-agent` outside Kubernetes need their own egress controls (host firewall/VPC/NACL). This policy only governs Kubernetes workloads.
- External telemetry collectors have dedicated pod-scoped ingress policies. Use them for syslog, NetFlow, sFlow, SNMP traps, and BMP so opening a collector port does not also expose unrelated workloads. See [Kubernetes External Ingestion](./kubernetes-ingestion.md).
- Plugins and integrations that call public services need explicit egress. For AlienVault OTX, allow `otx.alienvault.com` with an FQDN-aware policy. Its CDN addresses rotate, so a static `allowedCIDRs` entry requires ongoing DNS resolution and CIDR maintenance.

Example:

```yaml
networkPolicy:
  enabled: true
  podSelectorMatchAll: true
  ingress:
    allowSameNamespace: true
    allowedCIDRs:
      - "10.0.0.0/8"
      - "192.168.0.0/16"
    flowCollectorExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
    logCollectorExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
    trapdExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
    bmpCollectorExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
  egress:
    allowDNS: true
    allowKubeAPIServer: true
    allowDefaultNamespace: true
    allowSameNamespace: true
    allowedCIDRs:
      - "10.0.0.0/8"
      - "192.168.0.0/16"
```

## Gateway API Syslog

When `gatewayApi.enabled=true`, the chart can attach syslog to a shared Gateway API UDP listener. This is the preferred way to receive syslog in clusters that already have a shared Envoy Gateway because it avoids allocating another collector address.

Example:

```yaml
gatewayApi:
  enabled: true
  mode: attach
  syslog:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: serviceradar-shared-gateway
        namespace: serviceradar-system
        sectionName: syslog-udp
```

The parent Gateway must expose a UDP listener named by `sectionName`, and the ServiceRadar namespace must be allowed by that listener. If NetworkPolicy is enabled, allow ingress from the Gateway data-plane namespace because traffic reaches the log collector from Envoy pods.

Optional (Calico): log and deny unmatched egress

If you run Calico, you can enable a Calico `NetworkPolicy` that logs denied egress before denying it:

```yaml
networkPolicy:
  calicoLogDenied:
    enabled: true
    selector: "app.kubernetes.io/part-of == 'serviceradar'"
    order: 1000
```

## CNPG PgBouncer Pooler

Kubernetes installs can enable a CNPG-managed PgBouncer pooler through the Helm
chart. This deploys a `postgresql.cnpg.io/v1` `Pooler` resource and routes
PgBouncer-safe runtime database clients through the generated pooler service.
Schema migrations, bootstrap jobs, and other DDL/admin paths continue to use the
direct CNPG RW service.

Example:

```yaml
cnpg:
  pooler:
    enabled: true
    instances: 3
    poolMode: transaction
    ha:
      podAntiAffinity:
        enabled: true
        type: preferred
    monitoring:
      podMonitor:
        enabled: true
    route:
      core: true
      webNg: true
    parameters:
      ignore_startup_parameters: "search_path"
      max_client_conn: "2000"
      default_pool_size: "40"
      reserve_pool_size: "10"
```

Operational notes:

- Transaction pooling requires clients to avoid named prepared statements. The
  chart sets `DATABASE_PREPARE=unnamed` for `core` and `web-ng` when those
  workloads are routed through the pooler.
- CNPG PgBouncer presents the PostgreSQL server certificate. When `verify-full`
  is enabled, the chart connects to the pooler service but sets
  `CNPG_TLS_SERVER_NAME` to the direct CNPG RW service name for routed Elixir
  workloads so hostname verification remains strict.
- Ecto sends `search_path` as a PostgreSQL startup parameter. The pooler defaults
  include `ignore_startup_parameters=search_path`; keep the database role
  search path configured server-side for routed workloads.
- PgBouncer is deployed as an HA access layer by default with three Pooler pods
  and preferred pod anti-affinity. Set `cnpg.pooler.ha.podAntiAffinity.type=required`
  only when the cluster has enough nodes to satisfy strict placement.
- Enable `cnpg.pooler.monitoring.podMonitor.enabled=true` when Prometheus
  Operator is installed. The scraper targets the CNPG PgBouncer exporter on port
  `metrics` and exposes the `cnpg_pgbouncer_` metric family.
- Keep migrations and bootstrap direct to `cnpg-rw`; PgBouncer transaction
  pooling is not appropriate for DDL, extension setup, or migration locks.

## Deployment Provisioning

ServiceRadar does not provision per-customer workloads from inside the Helm chart.
Each deployment is self-contained. In managed environments, a separate control
plane provisions namespaces, CNPG accounts, and NATS accounts, then installs the
chart for that deployment.

## Mapper Discovery Settings

Mapper discovery is embedded in `serviceradar-agent` and configured via Settings → Networks → Discovery. Discovery jobs, seeds, and credentials are stored in CNPG and delivered to agents through the GetConfig pipeline.

If you need to bootstrap discovery configuration in an automated fashion, use the admin API or seed the CNPG data directly, then trigger an agent config refresh.

## Device Enrichment Rule Overrides

Core always ships with built-in enrichment rules. You can mount filesystem overrides that load from `/var/lib/serviceradar/rules/device-enrichment`.

Enable override mounting in values:

```yaml
core:
  deviceEnrichment:
    rulesDir: /var/lib/serviceradar/rules/device-enrichment
    filesystemOverrides:
      enabled: true
      existingConfigMap: serviceradar-device-enrichment-rules
      # Optional alternatives:
      # existingSecret: serviceradar-device-enrichment-rules
      # existingClaim: serviceradar-device-enrichment-rules
```

ConfigMap example:

```bash
kubectl create configmap serviceradar-device-enrichment-rules \
  -n serviceradar \
  --from-file=ubiquiti-overrides.yaml=./ubiquiti-overrides.yaml
```

Apply/verify:

```bash
helm upgrade --install serviceradar ./helm/serviceradar -n serviceradar -f my-values.yaml
kubectl logs deploy/serviceradar-core -n serviceradar | rg "Device enrichment rules loaded"
```

Rollback to built-ins:

```yaml
core:
  deviceEnrichment:
    filesystemOverrides:
      enabled: false
```

UI management:

- Open **Settings → Network → Device Enrichment**.
- Use the typed rule editor to create/update/delete rules.
- For writable UI-managed rules in Kubernetes, back the mount with a PVC (`existingClaim`) rather than ConfigMap/Secret.

## Outbound Mail (SMTP)

Outbound mail carries identity messages (confirmation, password reset) and the
`email` notification transport. Both go through one mail path, so configuring it
here configures both. See [Notifications](./notifications.md) for the channel
side.

Configure it with the `core.mailer` block:

```yaml
core:
  mailer:
    # "smtp", "local", "sendgrid", ... Leave empty to infer SMTP from `relay`.
    adapter: ""
    relay: "smtp.example.com"
    port: 587
    # HELO/EHLO name this deployment announces; empty lets the relay decide.
    hostname: ""
    auth: "if_available"     # always | never | if_available
    tls: "if_available"      # STARTTLS
    ssl: false               # implicit TLS (port 465)
    from:
      name: "ServiceRadar"
      email: "noreply@example.com"
    # Relay credentials come from an existing Secret, never from values.
    existingSecret: "serviceradar-smtp"
    usernameKey: "smtp-username"
    passwordKey: "smtp-password"
```

Create the credential Secret separately:

```bash
kubectl create secret generic serviceradar-smtp \
  -n serviceradar \
  --from-literal=smtp-username='serviceradar' \
  --from-literal=smtp-password='...'
```

The password is deliberately not a chart value. A password in `values.yaml` is a
password in the rendered manifest, in `helm get values`, and in whatever GitOps
repository holds the file.

The block renders into these container environment variables on
`serviceradar-core`:

| Variable | From | Meaning |
| --- | --- | --- |
| `SERVICERADAR_MAILER_ADAPTER` | `core.mailer.adapter` | `smtp`, `local`, `test`, or an API adapter name |
| `SMTP_RELAY_HOST` | `core.mailer.relay` | Relay hostname. Setting it alone selects the SMTP adapter |
| `SMTP_RELAY_PORT` | `core.mailer.port` | Default 587 |
| `SMTP_RELAY_HOSTNAME` | `core.mailer.hostname` | HELO/EHLO name |
| `SMTP_RELAY_AUTH` | `core.mailer.auth` | `always`, `never`, `if_available` |
| `SMTP_RELAY_TLS` | `core.mailer.tls` | STARTTLS mode |
| `SMTP_RELAY_SSL` | `core.mailer.ssl` | `true` for implicit TLS |
| `SMTP_RELAY_USERNAME` / `SMTP_RELAY_PASSWORD` | `core.mailer.existingSecret` | Relay credentials, by Secret reference |
| `SERVICERADAR_MAIL_FROM_NAME` / `SERVICERADAR_MAIL_FROM_EMAIL` | `core.mailer.from` | Default `From:` |

With none of this set, the mailer resolves to a non-delivering test adapter that
reports every send as successful. That is why an email notification channel
refuses to validate until a relay is configured here (or in Settings > Mail)
rather than looking healthy and paging nobody. An unrecognised
`SERVICERADAR_MAILER_ADAPTER` value fails the pod's boot with the accepted list,
which is a deployment that does not start rather than one that starts and mails
nowhere.

Also relevant for notifications: set
`SERVICERADAR_NOTIFICATION_ACTION_BASE_URL` (via `core.extraEnv`) to the
externally reachable base URL of the web UI, so acknowledge / snooze / resolve
links inside notifications resolve to a real address.
