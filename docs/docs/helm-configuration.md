---
sidebar_position: 8
title: Helm Deployment and Configuration
---

This guide shows how to deploy ServiceRadar via the bundled Helm chart and tune sweep performance safely using chart values. For sweep behavior and concepts, see [Network Sweeps](./network-sweeps.md).

Install/upgrade
- Namespace: create once: `kubectl create ns serviceradar` (or change `namespace` in chart values).
- Deploy from the official OCI chart (recommended):
  - `helm upgrade --install serviceradar oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version 1.2.20 -n serviceradar --create-namespace -f my-values.yaml`
- Deploy from a repo checkout (development):
  - `helm upgrade --install serviceradar ./helm/serviceradar -n serviceradar -f my-values.yaml`
- Quick overrides without a file: add `--set` flags (examples below).

OCI chart quick start
- Inspect chart metadata and defaults:
  - `helm show chart oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version 1.2.20`
  - `helm show values oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version 1.2.20 > values.yaml`
- Pin images to a release tag (recommended):
  - `--set global.imageTag="v1.2.20"`
- Track mutable images (staging/dev):
  - `--set global.imageTag="latest" --set global.imagePullPolicy="Always"`
  - If you omit `global.imageTag`, the chart defaults to `latest`.

HA profile and demo overlay
- `values.yaml` stays conservative by default. Most stateful or queue-backed services start at `1` replica unless you opt into a larger topology.
- [values-demo.yaml](/home/mfreeman/src/serviceradar/helm/serviceradar/values-demo.yaml) is the validated HA overlay used by the Kubernetes `demo` environment.
- The current demo profile runs these at `3` replicas:
  - `core`
  - `webNg`
  - `agentGateway`
  - `dbEventWriter`
  - `datasvc`
  - `zen`
  - `logCollector`
  - `logCollector.tcpCollector`
  - `trapd`
  - `flowCollector`
  - `bmpCollector`
- Demo also disables PVC-backed local state for the services above where shared NATS/JetStream state is the real source of truth.

JetStream sizing values
- The shared `events` stream is created and reconciled by multiple services. The important knobs are:
  - `logCollector.streamReplicas`
  - `logCollector.streamMaxBytes`
  - `zen.streamReplicas`
  - `trapd.streamReplicas`
  - `flowCollector.streamReplicas`
  - `flowCollector.config.stream_max_bytes`
- Datasvc owns the KV/object streams and now reconciles both replica count and reserved capacity:
  - `datasvc.jetstreamReplicas`
  - `datasvc.bucketMaxBytes`
  - `datasvc.objectMaxBytes`
  - `datasvc.objectStoreBytes`
- Demo intentionally shrinks those reserved capacities compared to the generic chart defaults so `events` can run at `3` replicas without exhausting the JetStream account's file-store budget.
- `bmpCollector` is scaled to `3` pods in demo, but its dedicated `ARANCINI_CAUSAL` stream still uses `bmpCollector.config.streamReplicas=1` for now. That is an explicit sizing choice, not a pod-level HA limitation.

Key values: `sweep`
- networks: list of CIDRs/IPs to scan.
- ports: list of TCP ports to probe.
- modes: list of scanning modes (`icmp`, `tcp`).
- interval: sweep interval (e.g., `5m`).
- concurrency: global sweep concurrency.
- timeout: per-target timeout (Go duration).

TCP (SYN) settings: `sweep.tcp`
- rateLimit: global SYN pps limit (default 20000).
- rateLimitBurst: burst size (default 20000).
- maxBatch: packets per sendmmsg batch (default 32).
- concurrency: SYN scanner concurrency (default 256).
- timeout: per-connection timeout (default `3s`).
- routeDiscoveryHost: source IP discovery target (default `8.8.8.8:80`).
- ringBlockSize: TPACKET_V3 block size (bytes, default 0 = internal default).
- ringBlockCount: number of blocks (default 0 = internal default).
- interface: network interface name (default empty = auto-detect).
- suppressRSTReply: bool to suppress RST replies (default false).
- globalRingMemoryMB: global ring memory cap (MB, default 0 = internal default).
- ringReaders: number of AF_PACKET ring readers (default 0 = auto).
- ringPollTimeoutMs: poll timeout per reader (ms, default 0 = auto).

Key values: edge gateway address
- `webNg.gatewayAddress`: Optional external gateway address for edge agents (`host:port`).
  - If unset, the chart derives it from `ingress.host` (port 50052).
  - If neither is set, it falls back to the in-cluster service name.

ICMP settings: `sweep.icmp`
- highPerf: enable raw-socket ICMP where permitted (default true).
- rateLimit: global ICMP pps limit (default 5000).
- settings.rateLimit: per-batch ICMP rate (default 1000).
- settings.timeout: per-ICMP timeout (default `5s`).
- settings.maxBatch: batch size (default 64).

Recommended safe defaults
- SYN scanning is fast; start conservative: `sweep.tcp.rateLimit: 20000` and `rateLimitBurst: 20000`.
- Increase carefully if you control the upstream firewall/router and apply NOTRACK/conntrack tuning (see [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md)).

Example values.yaml
```
sweep:
  networks: ["10.0.0.0/24", "10.0.1.0/24"]
  ports: [22, 80, 443]
  modes: ["icmp", "tcp"]
  interval: 5m
  concurrency: 150
  timeout: 8s
  tcp:
    rateLimit: 15000
    rateLimitBurst: 20000
    maxBatch: 64
    concurrency: 512
    timeout: 2s
    routeDiscoveryHost: 10.0.0.1:80
    ringBlockSize: 2097152
    ringBlockCount: 16
    interface: "eth0"
    suppressRSTReply: false
    globalRingMemoryMB: 64
    ringReaders: 4
    ringPollTimeoutMs: 100
  icmp:
    highPerf: true
    rateLimit: 3000
    settings:
      rateLimit: 1000
      timeout: 3s
      maxBatch: 32
```

Command-line overrides (examples)
- Set SYN rate and burst: `--set sweep.tcp.rateLimit=12000 --set sweep.tcp.rateLimitBurst=18000`
- Limit networks and ports: `--set sweep.networks='{10.1.0.0/24}' --set sweep.ports='{22,443}'`
- Disable high-perf ICMP: `--set sweep.icmp.highPerf=false`

Operational notes
- Defaults aim to avoid overwhelming upstream connection tracking by capping SYN to ~20k pps.
- For keeping scans fast with tuned routers, apply NOTRACK/conntrack tuning in parallel. See: [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md).

See also
- [Network Sweeps](./network-sweeps.md) for sweep behavior and troubleshooting
- [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md) for upstream router guidance

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

Example:

```yaml
networkPolicy:
  enabled: true
  podSelectorMatchAll: true
  egress:
    allowDNS: true
    allowKubeAPIServer: true
    allowDefaultNamespace: true
    allowSameNamespace: true
    allowedCIDRs:
      - "10.0.0.0/8"
      - "192.168.0.0/16"
```

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
      dbEventWriter: false
    parameters:
      max_client_conn: "2000"
      default_pool_size: "40"
      reserve_pool_size: "10"
```

Operational notes:

- Transaction pooling requires clients to avoid named prepared statements. The
  chart sets `DATABASE_PREPARE=unnamed` for `core` and `web-ng` when those
  workloads are routed through the pooler.
- PgBouncer is deployed as an HA access layer by default with three Pooler pods
  and preferred pod anti-affinity. Set `cnpg.pooler.ha.podAntiAffinity.type=required`
  only when the cluster has enough nodes to satisfy strict placement.
- Enable `cnpg.pooler.monitoring.podMonitor.enabled=true` when Prometheus
  Operator is installed. The scraper targets the CNPG PgBouncer exporter on port
  `metrics` and exposes the `cnpg_pgbouncer_` metric family.
- Keep migrations and bootstrap direct to `cnpg-rw`; PgBouncer transaction
  pooling is not appropriate for DDL, extension setup, or migration locks.
- Keep `db-event-writer` direct unless you have validated the Go database client
  and ingest workload against the pooler configuration.

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
