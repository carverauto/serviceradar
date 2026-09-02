# Flow Collector Scaling

How the ServiceRadar flow collector handles NetFlow / IPFIX / sFlow ingest at
volume, what the shared template store buys you, and how to tell when you have
outgrown the current shape.

## Deployment Model

The flow collector runs as a single-replica Kubernetes `Deployment` behind a
`Service` of `type: LoadBalancer`:

```
        exporters (routers / switches)
                    |
                    v
        Service: LoadBalancer (UDP 2055 / 4739 / 6343)
                    |
                    v
        flow-collector pod  (replicas: 1)
                    |
                    v
              NATS JetStream
```

### Capacity model

The events->flows cutover no longer runs in the pod. A `pre-install,pre-upgrade`
Helm hook Job (`serviceradar-flow-collector-bootstrap`) is the single writer of
stream ownership: it runs `--bootstrap-stream` to completion, including any
pending cutover, before any collector pod starts. Because that write is
settled ahead of time, every pod derives its subject list from config alone,
so concurrent stream ensures converge instead of racing -- which is what makes
the pods stateless and lets the Deployment run `strategy: RollingUpdate` with
more than one replica.

Exporters distribute across replicas by whatever the Service's load-balancing
mode gives you -- typically an ECMP hash at the network layer plus
`ClientIP` session affinity at the Service layer. That distribution is uneven
by construction: a handful of high-volume exporters can land on the same pod
while others sit mostly idle. Size `replicaCount` for headroom against that
imbalance, not for an exact per-pod exporter or source count.

Each pod is still limited to **one** Tokio worker under the default `0.5`
CPU `resources.limits.cpu` quota (measured: `nproc` reports 8 inside the
container, but the cgroup quota caps the runtime to a single worker thread),
so per-pod parse throughput is single-threaded regardless of node size.
Raising the CPU limit (more work per pod) and raising `replicaCount` (more
pods) are two different levers -- use the CPU limit to buy per-pod headroom
against a single busy exporter, and `replicaCount` to buy aggregate capacity
and spread across the uneven exporter distribution above.

### What the template store changes

Template state is the other thing that historically pinned traffic to one pod.
NetFlow v9 and IPFIX send templates separately from data records; a pod with no
template for an exporter cannot decode that exporter's flows until the exporter
re-announces (typically every 60s, per RFC 3954). The shared template store
removes that constraint by persisting learned templates in a NATS JetStream KV
bucket, so any pod can decode any exporter's flows.

Today that buys **graceful restarts**: after a rollout, OOM kill, or eviction,
the new pod restores templates from KV instead of dropping flows into
`pending_flows` until the next announcement. It is also the load-bearing
prerequisite for multi-pod ingest once the ownership blocker above is resolved.

Note that the parser scopes templates per `(source_ip, source_id)` for NetFlow
v9 (RFC 3954) and `(source_ip, observation_domain_id)` for IPFIX (RFC 7011). A
future multi-pod deployment must preserve the exporter's source IP into the pod
(for example `externalTrafficPolicy: Local` on MetalLB L2), or that scoping
collapses.

## Configuration

All knobs live under `flowCollector.config` in `values.yaml` (Helm) or directly
in `flow-collector.json`.

| Setting | Default | What it does | When to change |
|---|---|---|---|
| `template_store.kv_bucket` | `flow_templates` | NATS KV bucket name | Multi-tenant clusters where you want isolated buckets per tenant |
| `template_store.kv_history` | `1` | Revisions retained per key (1-64) | Bump to 5-10 if you want template change history for audit |
| `template_store.kv_ttl_secs` | `0` (forever) | Auto-expire stale entries | Set to `86400` (24h) if exporters churn frequently and you do not want orphan entries |
| `template_store.nats_url` | inherits `nats_url` | Override NATS endpoint for template state only | Split-fault-domain setups where template state lives on a different cluster |
| `listeners[].max_templates` | `2000` | Per-source LRU cache size | Increase if a single exporter announces >2000 templates (rare) |
| `listeners[].max_sources` | library default `10000` | Distinct exporters tracked per listener; evicts (LRU) past the cap | Raise when `flow_collector_sources` approaches it |
| `channel_size` | `10000` | Backpressure buffer to publisher | Raise if `flow_collector_flows_dropped_total` rises under burst |
| `batch_size` | `100` | NATS publish batch | Mostly fine; raise for higher throughput at the cost of per-message latency |
| `publish_timeout_ms` | `5000` | NATS ack timeout | Lower if you want fast-fail on NATS hiccups |

**Disabling the template store**: omit the `template_store` block. The pod then
uses only its in-process LRU, and every restart starts cold. The collector
works fine this way; you just lose restart grace.

The platform NATS credentials need permission to create-or-update KV buckets.
Alternatively pre-create the bucket out of band:

```bash
nats kv add flow_templates --history=1
```

For HA, pre-create it with the replication you want (`--replicas=3`); the
collector's bootstrap defaults to 1 replica and will not downgrade an existing
bucket's replication.

## Metrics to Monitor

The flow collector exposes Prometheus metrics on `metrics_addr` (default
`0.0.0.0:50046`, path `/metrics`).

| Metric | Healthy | Trouble signal |
|---|---|---|
| `flow_collector_packets_received_total` | Steadily increasing | Flat while exporters are sending -> LB or listener binding problem |
| `flow_collector_flows_converted_total` | Tracks packets minus parse errors | Diverges from `packets_received` -> degenerate records or template misses |
| `flow_collector_flows_dropped_total` | 0 | Non-zero rate -> publisher backpressure (raise `channel_size` or scale NATS) |
| `flow_collector_parse_errors_total` | 0 | Non-zero rate -> malformed exporter output (per-protocol log says which) |
| `flow_collector_undecodable_datagrams_total` | Low and flat | A UDP listener on a well-known port receives internet noise; a rising rate means something is aimed at the wrong port |
| `flow_collector_sources` | Stable | Approaching the netflow_parser `max_sources` cap (10,000 default in the library) -> eviction churn imminent |
| `flow_collector_template_store_restored_total` | Brief spike on pod restart, near-zero steady-state | Continuous non-zero rate -> templates are not staying cached |
| `flow_collector_template_store_codec_errors_total` | 0 always | Non-zero **ever** -> corrupted KV entries (drain bucket; possible netflow_parser version mismatch) |
| `flow_collector_template_store_backend_errors_total` | 0 | Sustained non-zero rate -> NATS unhealthy (parsing degrades gracefully to local-only) |

The `template_store_*` and `sources` rows are emitted only for NetFlow
listeners. sFlow is template-less, so those values are structurally zero and
are filtered out rather than reported as a misleading 0.

Alerting suggestions:

- **`template_store_codec_errors_total > 0`**, ever: page on first occurrence.
  This is corruption, not degradation.
- **`template_store_backend_errors_total` rate > 1/min for >5 min**: NATS is sick.
- **`flows_dropped_total` rate > 0.1% of received**: backpressure -- investigate
  the publish path.
- **`sources` near `max_sources`**: raise the limit or shard the deployment.

### How the counters are collected

The listener-level `template_store_*` gauges are aggregated from the parser's
per-source `CacheMetrics` by a background ticker running at 1Hz, not on the
packet path -- aggregation is O(sources), and doing it per datagram would scale
work with `packet_rate x source_count` while holding the parser lock.

The ticker also keeps the counters monotonic. When the parser evicts a source
via LRU, that source's last-known counters are folded into a `retired` total
rather than simply disappearing, so the exported counter never decreases.
Prometheus `rate()` requires that.

## When to Outgrow

Symptoms that mean this shape has hit its limit:

- **Pod CPU sustained >80%** -- single-threaded parser mutex contention. More
  nodes will not help until multi-pod ingest is unblocked.
- **Single NATS publish stream >1M msgs/sec** for extended periods -- needs
  subject sharding.
- **`sources` consistently >10K** -- too many distinct exporters for one parser.
- **MetalLB L2 leader-node NIC saturated** -- switch to BGP mode or a dedicated
  cloud LB. BGP mode requires upstream-router cooperation (your TOR / spine has
  to peer with MetalLB), which is the practical gating factor.

The next move is **sharding by exporter pool** rather than scaling a single
deployment:

- Group exporters by geography, AS number, customer tier, or whatever
  operationally-meaningful axis you have.
- Each shard gets its own flow-collector deployment, its own LB endpoint, its
  own NATS subject prefix, and its own `template_store.kv_bucket`.
- The downstream EventWriter and storage layer are unchanged -- they consume
  from a wildcard NATS subject either way.

True carrier-scale (50K+ exporters, tens of M flows/sec aggregate) is out of
scope for this design. At that point you are in dedicated-collector /
kernel-bypass territory and the architecture decision is upstream of this guide.

## Deploy Verification

```bash
NS=serviceradar

# 1) Pod is up and the listeners are bound
kubectl -n $NS get pods -l app=serviceradar-flow-collector
kubectl -n $NS logs -l app=serviceradar-flow-collector | grep -i listening

# 2) Metrics endpoint answers
kubectl -n $NS port-forward deploy/serviceradar-flow-collector 50046:50046 &
curl -s localhost:50046/metrics | grep flow_collector_

# 3) Template store bucket exists and is filling
nats kv ls flow_templates

# 4) Restart grace: delete the pod, then confirm restores climb
kubectl -n $NS delete pod -l app=serviceradar-flow-collector
curl -s localhost:50046/metrics | grep template_store_restored
```

A non-zero `template_store_restored_total` after step 4, without a
corresponding gap in `flows_converted_total`, is the signal that the shared
store is doing its job.
