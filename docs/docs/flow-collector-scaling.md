---
title: Flow Collector — Scaling Guide
---

# Flow Collector — Scaling Guide

Practical guidance for sizing the ServiceRadar flow collector, the knobs you can turn, what to watch in production, and when you've outgrown the default architecture. For protocol details (NetFlow v5/v9/IPFIX, sFlow), see the [NetFlow Ingest Guide](./netflow.md).

## Deployment Model

The flow collector runs as a **Kubernetes `DaemonSet`** behind a `Service` of `type: LoadBalancer` with `externalTrafficPolicy: Local`:

```
Exporters
    │ UDP (NetFlow 2055, IPFIX 4739, sFlow 6343)
    ▼
┌────────────────────────────────┐
│ Cloud L4 LB / MetalLB          │   src_ip preserved
└────────┬───────────────────────┘
         │
   ┌─────┼─────┬─────┐
   ▼     ▼     ▼     ▼
  pod   pod   pod   pod         ← one per node (DaemonSet)
   \    \    /    /
    NATS JetStream
    ├─ events stream  (parsed flow records → EventWriter)
    └─ flow_templates KV bucket  (shared template state across pods)
```

Three things make this work:

1. **`externalTrafficPolicy: Local`** preserves the exporter's source IP through the LB into the pod. The parser uses `(source_ip, source_id)` to scope NetFlow v9 templates per RFC 3954 and `(source_ip, observation_domain_id)` for IPFIX per RFC 7011 — without source-IP preservation this collapses, so this flag is non-negotiable.
2. **DaemonSet** ensures one pod per node, which gives the LB a healthy backend on every potential target node and matches kube-proxy's expectations under `Local`.
3. **Shared `TemplateStore`** (NATS JetStream KV bucket) lets a flow record routed to a fresh pod read templates other pods have already learned, avoiding `pending_flows` queueing or data loss during pod restarts and rolling upgrades. See `netflow_parser`'s [TemplateStore docs](https://docs.rs/netflow_parser/latest/netflow_parser/template_store/index.html) for the read-through / write-through protocol.

## Configuration Knobs

All knobs live under `flowCollector.config` in `values.yaml` (Helm) or directly in `flow-collector.json` (kustomize).

| Setting | Default | What it does | When to change |
|---|---|---|---|
| `template_store.kv_bucket` | `flow_templates` | NATS KV bucket name | Multi-tenant clusters where you want isolated buckets per tenant |
| `template_store.kv_history` | `1` | Revisions retained per key | Bump to 5–10 if you want template change history for audit |
| `template_store.kv_ttl_secs` | `0` (forever) | Auto-expire stale entries | Set to `86400` (24h) if exporters churn frequently and you don't want orphan entries |
| `listeners[].max_templates` | `2000` | Per-source LRU cache size | Increase if a single exporter announces >2000 templates (rare) |
| `channel_size` | `10000` | Backpressure buffer to publisher | Raise if `flow_collector_flows_dropped_total` rises under burst |
| `batch_size` | `100` | NATS publish batch | Mostly fine; raise for higher throughput at the cost of per-message latency |
| `publish_timeout_ms` | `5000` | NATS ack timeout | Lower if you want fast-fail on NATS hiccups |

**Disabling the template store**: omit the `template_store` block. Each pod uses only its in-process LRU. Acceptable for single-replica deployments. **Not** recommended for multi-pod deployments — even with stable 5-tuple LB hashing, any pod restart (rolling upgrade, eviction, OOM) lands flows on a cold pod with no template state, queueing them in `pending_flows` until the exporter re-announces (typically every 60s, per RFC 3954). Templates from that exporter are effectively unparseable for that window.

## Sizing Rules of Thumb

These are starting points. Every NetFlow deployment is different — exporter rates, packet sizes, and active-flow counts vary widely. **Benchmark on your hardware** to refine the actual ceilings.

### Small (≤100 routers, ≤50K flows/sec)

- 1–2 nodes, DaemonSet
- Single NATS instance (1 replica) is fine
- TemplateStore optional — gives you graceful pod-restart behavior; not load-bearing
- Single Prometheus scrape target

### Medium (100–1,000 routers, ~50K–500K flows/sec)

- 3–5 nodes, DaemonSet
- NATS in 3-replica cluster mode (fault tolerance + KV replication)
- TemplateStore strongly recommended — rolling upgrades will hit empty pods otherwise
- Tune `channel_size` to ~50,000 if you see drops under burst
- This is the deployment shape that fits most ServiceRadar production customers

### Large (1,000–10,000 routers, ~500K–5M flows/sec)

- 5–10 nodes, ideally dedicated to flow ingest (taint other workloads off them)
- NATS cluster sized for the publish rate — partition the `events` stream subjects if a single stream becomes a bottleneck
- TemplateStore required
- Watch the per-pod parser CPU; this is where the `Mutex<AutoScopedParser>` becomes a real factor
- MetalLB BGP mode (not L2) for LB throughput beyond a single leader-node NIC. BGP mode requires upstream-router cooperation (your TOR / spine has to peer with MetalLB) — that's the practical gating factor, not the MetalLB config itself

### Very large (>10K routers)

You've outgrown a single deployment — see "When to Outgrow" below.

## Metrics to Monitor

The flow collector exposes Prometheus metrics on `metrics_addr` (default `0.0.0.0:50046`, path `/metrics`). The interesting counters and what their non-zero rates mean:

| Metric | Healthy | Trouble signal |
|---|---|---|
| `flow_collector_packets_received_total` | Steadily increasing per pod | Big imbalance across pods → LB hashing skew or hot exporter |
| `flow_collector_flows_converted_total` | Tracks packets minus parse errors | Diverges from `packets_received` → degenerate records or template misses |
| `flow_collector_flows_dropped_total` | 0 | Non-zero rate → publisher backpressure (raise `channel_size` or scale NATS) |
| `flow_collector_parse_errors_total` | 0 | Non-zero rate → malformed exporter output (per-protocol log will say which) |
| `flow_collector_sources` | Stable | Approaching the netflow_parser `max_sources` cap (10,000 default in the library) → eviction churn imminent. The flow collector does not yet expose this as a config knob; if you need to raise it, file an issue or fork the dep |
| `flow_collector_template_store_restored_total` | Brief spike on pod restart, near-zero steady-state | Continuous non-zero rate → exporters frequently land on cold pods (LB hashing instability) |
| `flow_collector_template_store_codec_errors_total` | 0 always | Non-zero **ever** → corrupted KV entries (drain bucket; possible netflow_parser version mismatch across pods) |
| `flow_collector_template_store_backend_errors_total` | 0 | Sustained non-zero rate → NATS unhealthy (the parser keeps working, falls back to local-only) |

Alerting suggestions:

- **`template_store_codec_errors_total > 0`**, ever: page on first occurrence. This is corruption, not degradation.
- **`template_store_backend_errors_total` rate > 1/min for >5 min**: NATS is sick.
- **`flows_dropped_total` rate > 0.1% of received**: backpressure — investigate the publish path.
- **`sources` near `max_sources`**: raise the limit or shard the deployment.

## When to Outgrow

Symptoms that mean a single DaemonSet has hit its limit:

- **Per-pod CPU sustained >80%** even after adding nodes — single-threaded parser mutex contention, not a node-count problem.
- **Single NATS publish stream >1M msgs/sec** for extended periods — needs subject sharding.
- **`sources` per pod consistently >10K** — too many distinct exporters per pod even after spreading.
- **MetalLB L2 leader-node NIC saturated** — switch to BGP mode or dedicated cloud LB.

When you hit those, the next move is **sharding by exporter pool** rather than scaling the single deployment further:

- Group exporters by geography, AS number, customer tier, or whatever operationally-meaningful axis you have.
- Each shard gets its own flow-collector deployment, its own LB endpoint, its own NATS subject prefix, its own `template_store.kv_bucket`.
- The downstream EventWriter and storage layer are unchanged — they consume from a wildcard NATS subject either way.

True carrier-scale (50K+ exporters, tens of M flows/sec aggregate) is out of scope for this design. At that point you're in dedicated-collector / kernel-bypass territory and the architecture decision is upstream of this guide.

## Upgrading from a Pre-DaemonSet Install

If your cluster is currently running the older `Deployment`-based flow
collector, the new manifests don't replace the old objects in-place —
they create a `DaemonSet` of the same name (different kind, so they
coexist) and the previous `Deployment` + its `PersistentVolumeClaim`
become orphaned, still consuming resources and (worse) competing for
the Service selector.

Before applying the new manifests:

```bash
# Capture the namespace
NS=<your-flow-collector-namespace>

# Drop the old objects
kubectl -n $NS delete deployment serviceradar-flow-collector --ignore-not-found
kubectl -n $NS delete pvc serviceradar-flow-collector-data --ignore-not-found

# Then apply the new manifests
kubectl apply -k k8s/demo/base/
# or
helm upgrade --install serviceradar ./helm/serviceradar -n $NS
```

The Helm `NOTES.txt` repeats these commands after a successful upgrade
so they're easy to copy-paste at install time.

If you forget and apply on top, both the old Deployment pods and the
new DaemonSet pods will respond to the Service — kill the Deployment
first (`kubectl delete deployment ...`), then traffic redistributes
cleanly.

## Rolling Upgrade Behavior

Under `externalTrafficPolicy: Local`, the cloud LB's health-check
targets only nodes that have a Ready pod for the Service. During a
DaemonSet rolling upgrade with `maxUnavailable: 1`, one node has zero
collector pods for a brief window — its LB health check fails and the
LB stops sending traffic to it during that window. Flows from
exporters whose 5-tuple hashes there are temporarily routed to other
nodes (which read templates through from NATS KV — this is exactly
what the template store buys you).

Practical implications:

- **Always run with `template_store` enabled in multi-pod deployments**;
  rolling upgrades are otherwise lossy.
- **`maxUnavailable: 1` is a deliberate floor** — increasing it makes
  more nodes briefly LB-unreachable simultaneously and risks dropping
  flows whose hashes all land on the unavailable subset. Stay at 1
  unless you know what you're doing.
- **Drain a node** (`kubectl drain --ignore-daemonsets`) only removes
  non-DaemonSet pods. If you need to remove a node from the LB
  rotation, also `kubectl cordon` it and delete its DaemonSet pod
  manually.

## Deploy Verification Checklist

Before declaring a new deployment healthy:

```bash
# 1) DaemonSet has a pod on every node
kubectl get ds serviceradar-flow-collector
# DESIRED == CURRENT == READY == nodes

# 2) Service got a LoadBalancer IP
kubectl get svc serviceradar-flow-collector
# EXTERNAL-IP not <pending>

# 3) Source IP preserved end-to-end
POD=$(kubectl get pod -l app=serviceradar-flow-collector \
  -o jsonpath='{.items[0].metadata.name}')
kubectl debug $POD -it --image=nicolaka/netshoot \
  -- tcpdump -nn -i any port 2055
# Send a NetFlow packet from a known IP, confirm tcpdump shows that IP
# (not the LB or a node IP)

# 4) Cross-pod template sharing works
kubectl exec serviceradar-nats-0 -- nats kv ls flow_templates
# Should show entries with sanitized scope keys, e.g.
#   v9_10_0_0_42_2055_0.v9d.256

# 5) Prometheus scrape returns the new metrics
kubectl port-forward $POD 50046:50046
curl -s http://localhost:50046/metrics | grep template_store
```

If any of these fail, fix before proceeding to load testing.
