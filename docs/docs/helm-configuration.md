---
sidebar_position: 8
title: Helm Deployment and Configuration
---

This guide shows how to deploy ServiceRadar via the bundled Helm chart and tune sweep performance safely using chart values. For sweep behavior and concepts, see [Network Sweeps](./network-sweeps.md).

Install/upgrade
- Namespace: create once: `kubectl create ns serviceradar` (or change `namespace` in chart values).
- Deploy from the official OCI chart (recommended):
  - `helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.75 -n serviceradar --create-namespace -f my-values.yaml`
- Deploy from a repo checkout (development):
  - `helm upgrade --install serviceradar ./helm/serviceradar -n serviceradar -f my-values.yaml`
- Quick overrides without a file: add `--set` flags (examples below).

OCI chart quick start
- Inspect chart metadata and defaults:
  - `helm show chart oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.75`
  - `helm show values oci://ghcr.io/carverauto/charts/serviceradar --version 1.0.75 > values.yaml`
- Pin images to a release tag (recommended):
  - `--set global.imageTag="v1.0.75"`
- Track mutable images (staging/dev):
  - `--set global.imageTag="latest" --set global.imagePullPolicy="Always"`
  - If you omit `global.imageTag`, the chart defaults to `latest`.

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

## Deployment Provisioning

ServiceRadar does not provision per-customer workloads from inside the Helm chart.
Each deployment is self-contained. In managed environments, a separate control
plane provisions namespaces, CNPG accounts, and NATS accounts, then installs the
chart for that deployment.

## Mapper Discovery Settings

Mapper discovery is embedded in `serviceradar-agent` and configured via Settings → Networks → Discovery. Discovery jobs, seeds, and credentials are stored in CNPG and delivered to agents through the GetConfig pipeline.

If you need to bootstrap discovery configuration in an automated fashion, use the admin API or seed the CNPG data directly, then trigger an agent config refresh.
