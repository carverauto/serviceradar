---
sidebar_position: 8
title: Helm Deployment and Configuration
---

This guide shows how to deploy ServiceRadar via the bundled Helm chart and tune sweep performance safely using chart values. For an overview of sweep configuration fields, see [Network Sweep](./configuration.md#network-sweep) in Configuration Basics.

Install/upgrade
- Namespace: create once: `kubectl create ns serviceradar` (or change `namespace` in chart values).
- Deploy from repo checkout:
  - `helm upgrade --install serviceradar ./helm/serviceradar -n serviceradar -f my-values.yaml`
- Quick overrides without a file: add `--set` flags (examples below).

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
- [Configuration Basics → Network Sweep](./configuration.md#network-sweep) for file-based config reference
- [SYN Scanner Tuning and Conntrack Mitigation](./syn-scanner-tuning.md) for upstream router guidance

## Mapper Service Settings

The Helm chart ships a `serviceradar-config` ConfigMap that includes `mapper.json`. Update it before installing or as part of an overlay so Mapper discovers the right networks:

- Copy `helm/serviceradar/files/serviceradar-config.yaml` into your deployment repo, edit the `mapper.json` block, and commit the changes alongside your values file. The ConfigMap is rendered with `tpl`, so you can inject Helm template expressions if you prefer.
- Adjust **`workers`**, **`max_active_jobs`**, and timeout values to match your cluster’s SNMP budget.
- Fill in **`default_credentials`** and **`credentials[]`** with SNMP v2c/v3 settings per CIDR. Use the same ordering rules described in the [Discovery guide](./discovery.md#configuring-mapperjson).
- Customize **`stream_config`** so emitted device, interface, and topology records use the stream names and tags you expect.
- Define **`scheduled_jobs[]`** for recurring discovery. Each job needs `seeds`, discovery `type`, `interval`, and optional overrides such as `concurrency` or `timeout`.
- List UniFi controllers under **`unifi_apis[]`** when you want mapper to correlate topology from controller APIs.

Deploy the overrides by pointing Helm at your edited file:

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  -n serviceradar \
  -f my-values.yaml
```

If you already deployed without the changes, patch the `serviceradar-config` ConfigMap and restart the `serviceradar-mapper` Deployment so it reloads the updated JSON.
