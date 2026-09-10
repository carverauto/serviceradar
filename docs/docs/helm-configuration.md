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
- MCP (`/mcp`) is off by default. Enable with `--set webNg.mcpEnabled="true"`
  (the chart must template `SERVICERADAR_MCP_*` from that key; `extraEnv` cannot
  shadow it). Demo overlay `values-demo.yaml` already turns it on. Client setup
  (Codex, Claude Code, Grok) is in [MCP Integration](./mcp-integration.md).

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

## Public web and edge-agent endpoints

ServiceRadar publishes two independent paths during agent onboarding:

| Path | Helm values | Used for |
| --- | --- | --- |
| Public web/API | `webNg.host`, `webNg.publicUrl` | Browser access, Phoenix URL generation, the generated `--core-url`, and the API origin signed into onboarding tokens |
| Agent gateway | `webNg.gatewayAddress`, `agentGateway.publicHostname` | The `gateway_addr` and default TLS server name placed in the downloaded bundle, plus the public artifact endpoint |

### Canonical public web origin

- Set `webNg.host` to the public web DNS name and `webNg.publicUrl` to its bare
  HTTPS origin. Do this even when `gatewayApi.host` or `ingress.host` has the
  same value; keeping the application origin explicit prevents an exposure
  change from altering newly issued onboarding tokens.
- Set `webNg.publicUrl` to the bare, externally reachable HTTPS origin, with no
  path, query, fragment, or credentials (for example,
  `https://serviceradar.example.com`). A trailing root slash is canonicalized
  away. Only the standard HTTPS port 443 is supported.
- This is the canonical origin embedded in edge onboarding tokens and generated
  [enrollment commands](./edge-agent-onboarding.md#3-enroll-the-host). It also
  drives Phoenix external URL generation. Never use an in-cluster Service name here.
- When `webNg.publicUrl` is empty, the chart falls back through `webNg.host`,
  `ingress.host`, and `gatewayApi.host`. Set `webNg.publicUrl` explicitly in
  production so changing the exposure implementation does not change issued
  tokens.

```yaml
webNg:
  host: serviceradar.example.com
  publicUrl: https://serviceradar.example.com
```

### Edge gateway address

- Set `webNg.gatewayAddress` to the externally reachable agent-gateway
  `host:port`, normally TCP `50052`. It is not an HTTP URL and it need not use
  the web hostname.
- Set `agentGateway.publicHostname` to the same DNS name, without a port. The
  chart uses this hostname for the public artifact URL on
  `agentGateway.service.artifactPort` (default `50053`). The bundle's TLS server
  name defaults to the host in `webNg.gatewayAddress`; ensure the certificate
  presented by the gateway is issued or reissued with that name.
- If `webNg.gatewayAddress` is unset, the chart derives `<web-host>:50052` from
  the public web host. That fallback is correct only when the same L4 address
  actually exposes the agent-gateway port. It does not make an HTTP-only
  Gateway listen on `50052`.

Choose one exposure pattern:

1. **Dedicated agent-gateway LoadBalancer.** Give the Service a dedicated DNS
   name, expose `50052` and `50053`, and point `webNg.gatewayAddress` at it.
   This is the pattern used by the bundled `values-demo.yaml` overlay.

   ```yaml
   webNg:
     host: serviceradar.example.com
     publicUrl: https://serviceradar.example.com
     gatewayAddress: agent-gateway.example.com:50052

   agentGateway:
     publicHostname: agent-gateway.example.com
     service:
       type: LoadBalancer
       annotations:
         external-dns.alpha.kubernetes.io/hostname: agent-gateway.example.com.
   ```

2. **Shared Gateway API data plane.** Route the agent-gateway ports through the
   same Envoy data-plane Service as the web endpoint. The parent Gateway must
   have TCP listeners for `50052` and `50053`; an `HTTPRoute` on `443` cannot
   carry this traffic. In `managed` mode the chart creates the listeners. In
   `attach` mode, enable `gatewayApi.agentGateway` and supply `parentRefs` for
   existing listener section names.

   ```yaml
   webNg:
     host: serviceradar.example.com
     publicUrl: https://serviceradar.example.com
     gatewayAddress: agent-gateway.example.com:50052

   agentGateway:
     publicHostname: agent-gateway.example.com
     service:
       type: ClusterIP

   # The existing Gateway must already define TCP listeners named
   # agent-grpc (50052) and agent-artifacts (50053).
   gatewayApi:
     enabled: true
     mode: attach
     host: serviceradar.example.com
     # Web HTTPS route. The existing Gateway listener must allow routes from
     # the ServiceRadar release namespace.
     parentRefs:
       - group: gateway.networking.k8s.io
         kind: Gateway
         name: serviceradar-shared-gateway
         namespace: serviceradar-system
         sectionName: https-web
     agentGateway:
       enabled: true
       grpc:
         parentRefs:
           - group: gateway.networking.k8s.io
             kind: Gateway
             name: serviceradar-shared-gateway
             namespace: serviceradar-system
             sectionName: agent-grpc
       artifacts:
         enabled: true
         parentRefs:
           - group: gateway.networking.k8s.io
             kind: Gateway
             name: serviceradar-shared-gateway
             namespace: serviceradar-system
             sectionName: agent-artifacts
   ```

   Every referenced listener must allow routes from the ServiceRadar release
   namespace. A cross-namespace `parentRef` to a Gateway is authorized by that
   listener's `allowedRoutes`; a `ReferenceGrant` is needed only if a route also
   refers to a backend in a different namespace.

For a shared public IP, both DNS names can resolve to that IP. Using a dedicated
gateway DNS name remains useful because the bundle and certificate identity do
not then depend on the web hostname. Confirm the chosen address accepts both
ports before issuing onboarding packages.

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
- Control-plane notification webhooks (Discord, Slack, Teams, generic HTTPS) egress from the `web-ng` pods. Kubernetes NetworkPolicy cannot match FQDNs, so add the current CDN CIDR for each destination to `networkPolicy.egress.allowedCIDRs`. Discord incoming webhooks currently land on Cloudflare `162.159.128.0/18` (resolved 2026-08-13); if a Discord test send times out with `timeout contacting discord.com`, re-resolve `discord.com:443` and update that CIDR. The demo overlay (`values-demo.yaml`) already includes this range.

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

## CNPG WAL and Checkpoint Tuning

PostgreSQL forces a checkpoint every `max_wal_size / (2 + checkpoint_completion_target)`.
At PostgreSQL's stock `max_wal_size=1GB` that is 353 MB of WAL, which on a busy
ServiceRadar deployment meant a checkpoint roughly every 14 seconds -- and under heavy
ingest every 10 seconds, with every database backend blocked on `LWLock:WALWrite`. The
chart therefore sizes the WAL budget instead of inheriting the defaults.

`pg_wal` shares the CNPG data volume (the chart declares no separate `walStorage`), so
three parameters derive from `cnpg.storageSize` and are bounded relative to it:

| `cnpg.storageSize` | `max_wal_size` | `min_wal_size` | `max_slot_wal_keep_size` |
|---|---|---|---|
| 10Gi | 1GB | 256MB | 5GB |
| 20Gi | 1GB | 256MB | 10GB |
| 30Gi | 2GB | 256MB | 10GB |
| 50Gi | 3GB | 384MB | 15GB |
| 100Gi (default) | 7GB | 896MB | 30GB |
| 200Gi | 8GB | 1024MB | 60GB |
| 1Ti | 8GB | 1024MB | 307GB |

`max_wal_size` is 7% of the volume clamped to `[1GB, 8GB]`; `min_wal_size` is an eighth
of that clamped to `[256MB, 1024MB]`; `max_slot_wal_keep_size` stays at its established
~30% policy, floored at 10GB but never more than half the volume.

The 1GB floor on `max_wal_size` is deliberate: an install of roughly 28Gi or less keeps
PostgreSQL's own default and spends no extra WAL disk. Such deployments get no checkpoint
relief -- you cannot spend disk you do not have -- and should raise `cnpg.maxWalSize`
explicitly if their volume can afford it.

Because these derive from `cnpg.storageSize`, **that value must track the real
provisioned volume.** A `storageSize` that has drifted below the actual disk under-sizes
three parameters rather than one.

### Overrides

Each has an escape hatch, and setting the PostgreSQL parameter directly always wins:

```yaml
cnpg:
  maxWalSize: ""            # e.g. "16GB"
  minWalSize: ""            # e.g. "2048MB"
  maxSlotWalKeepSize: ""    # e.g. "250GB"
  postgresqlParameters:
    max_wal_size: "16GB"    # takes precedence over cnpg.maxWalSize
```

Use PostgreSQL units (`GB`, `MB`), not Kubernetes resource units (`Gi`, `Mi`).

The same keys exist under `spire.postgres.*`, which hosts the application database when
`spire.postgres.enabled` is true.

### Cost and rollout

Worst-case `pg_wal` use is roughly `2 x max_wal_size` plus the slot cap. On the 100Gi
default that moves from about 32GB to about 44GB of the volume, so check free space on
the data volume before upgrading an install already near its high-water mark.

All of these parameters, plus `checkpoint_timeout`, `checkpoint_completion_target`,
`wal_compression` and `log_parameter_max_length`, apply by SIGHUP reload. Changing them
does **not** restart any CNPG pod and does not trigger a switchover.

Note that this budget does not bound WAL end-to-end: when `cnpg.backup.enabled` is true,
WAL awaiting archival is held by neither `max_wal_size` nor `max_slot_wal_keep_size`, so
a failing object-store archive can still fill the volume.

After a rollout, confirm convergence with `pg_stat_checkpointer`: `num_timed` should rise
and `num_requested` should fall toward zero. `num_requested` dominating means checkpoints
are still being forced by WAL volume rather than by the timer.

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

After the application is ready, use the supported
[provisioning API](./ansible-provisioning-api.md) or
[Terraform provider](./terraform-provider.md) for its bounded application resources.
Follow [Declarative environments](./declarative-environments.md) for the ordered
installation, identity bootstrap, configuration, and recovery workflow.

## Mapper Discovery Settings

Mapper discovery is embedded in `serviceradar-agent` and configured via Settings → Networks → Discovery. Discovery jobs, seeds, and credentials are stored in CNPG and delivered to agents through the GetConfig pipeline.

Configure discovery through Settings or its supported admin API, then trigger an agent config refresh. Do not seed CNPG directly. The current Terraform provider does not manage mapper discovery resources.

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

## Outbound Mail

Configure SMTP in the Web UI: **Settings -> Mail**. That is the operator
path. See [Outbound Mail](./outbound-mail.md) for Local vs Test vs SMTP and
the field-by-field setup.

The `core.mailer` block below is a **fallback** for automation. An enabled
Settings -> Mail row overrides it. Do not put a mailbox password in values;
the UI stores credentials encrypted.

```yaml
# Fallback only. Prefer Settings -> Mail.
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

Also relevant for notifications: set `webNg.publicUrl` to the externally
reachable HTTPS origin of the web UI. Recent charts copy that value to
`SERVICERADAR_NOTIFICATION_ACTION_BASE_URL` on `web-ng` and `core` so
acknowledge / snooze / resolve links inside notifications resolve to a real
address. See the [Notifications Quickstart](./notification-quickstart.md).
