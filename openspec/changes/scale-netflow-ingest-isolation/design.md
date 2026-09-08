# Design: Scale NetFlow ingest isolation and GenStage demand

## Context

Canonical path today:

```
Exporters → flow-collector (UDP) → JetStream stream `events` subject `flows.raw.netflow`
         → EventWriter (single Broadway producer, many filter durables)
         → platform.ocsf_network_activity
         → web-ng NetFlow map (last ~15 min of flow time)
```

Flow attribution is a separate agent-up path and does not add a JetStream
subject to the raw-flow stream:

```
netprobe → agent (`FlowAttributionEventBatch`) → gateway (`StreamStatus`) → core
         → platform.flow_process_attribution_current
         → core correlator updates the matching existing OCSF row in place
```

The earlier demo canary sent per-host flow slices down to agents and published
results on `flow.attributed.*`. That experiment remains relevant historical
evidence, but both canary subjects are retired and are not current or future
attribution routing.

Evidence from demo incident (2026-08-09):

| Stage | Observation |
|-------|-------------|
| Collector | Healthy; packets/flows rising; `flows_dropped=0`, `channel_full_drops=0` |
| JetStream `events` | Shared; R=3 with nats-1 offline; ~30 min first→last window |
| Consumer `serviceradar-event-writer-netflow-raw` | ~8k `num_pending`, not draining |
| DB | `max(time)` ~30 min behind wall clock; last 15m count = 0 |
| Helm demo | `flowCollector.config.stream_max_bytes: 1Gi`, logCollector same, “fit account budget” |
| NATS | `max_file_store` default **10G per server**; PVC 30Gi per server |
| OTEL ensure | Updates shared `events` `max_bytes` and **`max_age_secs=1800`** |
| EventWriter | Demand-coupled pull (good) but **one producer**, fair-share across all durables, `no_wait` + 100ms fetch |

`fix-eventwriter-backpressure-hotpath` correctly moved EventWriter to pull + demand for metrics. NetFlow still loses under multi-subject contention and short shared retention.

## Goals / Non-Goals

### Goals

- Isolate raw flow telemetry on its own JetStream stream with flow-owned retention.
- Make GenStage/Broadway demand for flows independent of other EventWriter subjects.
- Size pull batches and long-polls so demand translates into real throughput, not RT churn.
- Size defaults (and demo overrides) for multi-hour lag headroom, not thrift against a 10G per-server file store.
- Keep discard-old as the last-resort overload valve; prefer lag metrics and alerting before silent drop.
- Migrate without dual-writing to CNPG and without a long dual-publish window if avoidable.

### Non-Goals

- Fixing Kubernetes DiskPressure / unschedulable `nats-1` (ops).
- Changing NetFlow map UI window semantics.
- Splitting OCSF row schema or BGP derivation logic.
- Multi-tenant / per-customer streams.
- Replacing Broadway with a custom GenStage tree (Broadway remains the framework).
- 50k-agent metric architecture (owned by edge anomaly / lakehouse changes).

## Decisions

### Decision 1: Dedicated JetStream stream `flows`

**Chosen:** Default stream name `flows` for subjects:

- `flows.raw.netflow`
- `flows.raw.sflow`
- configured concrete extension leaves such as `flows.raw.ipfix`

Only configured concrete `flows.raw.<name>` leaves are flow-collector-owned by
this change. EventWriter consumers require the corresponding **concrete**
leaves only.
Whole-token ownership wildcards such as `flows.raw.>`, `flows.>`, or `*.>` are
**rejected** by collector validation and are **not** auto-consumed by EventWriter:
they leave future leaves stored without a consumer and can block subject rehome
onto the dedicated stream (overlap with `events.>`).

Historical configs and canary records may mention
`flow.host-slice.<agent_id>` or `flow.attributed.<partition>`. The dedicated
stream does not own, publish, rehome, or consume either namespace, and this
change does not reserve them for a follow-up join. Current attribution instead
uses the agent-up status/current-state/core-correlation path described above.

**Rationale:** Isolation of retention and storage from logs/OTEL. Metrics already moved toward a dedicated `metrics` stream pattern; flows get the same treatment.

**Alternatives:**

| Option | Why not |
|--------|---------|
| Keep `events`, only raise max_bytes | OTEL still reconciles MaxAge; one log storm still starves flows |
| Per-exporter streams | Operational explosion; not needed for demand isolation |
| Kafka-style external bus | Out of platform architecture |

### Decision 2: Single owner for stream config per stream

**Chosen:** Only the **flow ingest path** (flow-collector ensure + EventWriter flow stream config) may create/update the `flows` stream. Log-collector and OTEL **MUST NOT** call ensure/update on `flows`. The shared `events` stream remains owned by log/OTEL/EventWriter non-flow subjects.

**Rationale:** Live incident showed thrashing reconcilers: flow-collector sets max_bytes only on create; OTEL rewrites max_age on every connect.

**flow-collector change:** On existing stream, reconcile:

- configured concrete `flows.raw.<name>` subjects without adopting retired
  canary namespaces as flow-collector-owned routes
- `num_replicas`
- `max_bytes` (from config)
- `max_age` (from config; new field if missing)
- storage/discard if we standardize them

Do not shrink limits below the configured values when another process had temporarily raised them (monotonic raise is acceptable; shrink only when config intentionally lowers — prefer exact config convergence with warning logs).

### Decision 3: Dedicated EventWriter demand domain for flows

**Chosen:** A **second Broadway pipeline** (or second producer module instance under a dedicated supervisor child) that only registers flow stream consumers:

- `NETFLOW_RAW` → `flows.raw.netflow`
- `SFLOW_RAW` → `flows.raw.sflow`
- any configured raw extension consumer → its exact `flows.raw.<name>` leaf

The existing EventWriter pipeline keeps logs, metrics, Falco, OTEL, etc.
Agent-up process-attribution batches bypass this raw-flow Broadway demand
domain; core persists them as bounded current state and correlates them against
OCSF rows written by the raw-flow pipeline.

**Rationale:** GenStage demand is per producer process. Fair-sharing one demand counter across ~15 durables is the root demand bug for high-volume NetFlow. Separate pipeline ⇒ independent `handle_demand`, independent pull budget, independent `max_ack_pending` / buffer caps.

**Alternatives:**

| Option | Why not (for now) |
|--------|-------------------|
| Weighted fair-share in one producer | Still one mailbox; still coupled failure/backpressure domains |
| One producer per subject | Too many processes / NATS conns without clear win |
| Horde-sharded multi-consumer on same durable | Later scale-out; not required for isolation |

### Decision 4: Long-poll pulls sized by demand

**Chosen:** For the flow producer:

1. On `handle_demand` and when demand remains after delivery, issue JetStream `request_next` with:
   - `batch = min(demand_budget, consumer_pull_batch_size, remaining_max_ack_window)`
   - `expires` (e.g. 1–5s) **instead of** `no_wait: true` as the primary path
2. Remove dependence on a global 100ms `:fetch` tick for the flow producer (optional low-frequency idle tick only if needed for reconnect hygiene).
3. Defaults for flow consumers (starting points; tune with benchmarks):

| Control | Starting default |
|---------|------------------|
| `consumer_pull_batch_size` | 64 (match metrics fix; allow 128–256 via env) |
| `max_ack_pending` | 1024 (flow-only; not global) |
| Broadway `batch_size` / timeout | 100 / 500ms (raise from 50 if insert_all can take it) |
| Producer concurrency | 1 per flow pipeline |
| Processor concurrency | existing default (10) or flow-specific override |

**Rationale:** Andrea Leopardi’s GenStage demand model: consumers ask; producers only fetch that much. Long-poll makes JetStream wait for work instead of empty-status spam. Pull batch 16 was already called out as RT thrash for metrics.

### Decision 5: Retention sizing model

Retention must cover **peak export rate × desired recovery lag**, not demo thrift.

```
required_bytes ≈ peak_publish_bytes_per_sec × max_recover_lag_sec × safety_factor
required_age   ≥ max_recover_lag_sec  (and ≥ UI investigation window if ops want reprocess)

# nats.jetstream.maxFileStore is a PER-SERVER limit (not cluster-wide).
# For R=3 JetStream streams the per-server file store must cover each stream's
# full max_bytes once (replicas place one copy per server in the typical case),
# not sum(max_bytes × replicas) against one server's max_file_store.
#
# Per-server check (R3 HA chart defaults):
#   maxFileStore ≥ KV 4 GiB + objects 10 GiB + events 2 GiB + flows 10 GiB
#                = 26 GiB  (chart uses 30G headroom on a 30Gi PVC)
```

**Starting product defaults (chart `values.yaml`):**

| Setting | Default |
|---------|---------|
| `flows` stream `max_bytes` | **10 GiB** binary/Helm default for dedicated `flows`; Docker/tenant JSON override lower to fit local file stores; never reshape `events` |
| `flows` stream `max_age` | **6 hours** |
| `flows` stream replicas | 3 (HA) or 1 for single-node |
| NATS PVC via Helm | **Do not change** live StatefulSet volumeClaimTemplates (immutable) |
| NATS `max_file_store` | **30G** **per NATS server** on default **30Gi** PVC; budget is KV 4 + objects 10 + events 2 + flows 10 GiB (not cluster-sum × R) |

**Demo (`values-demo.yaml`):**

| Setting | Default |
|---------|---------|
| `flows` stream `max_bytes` | **8 GiB** (dedicated; not shared with logs) |
| `flows` stream `max_age` | **2 hours** |
| NATS `max_file_store` | **30G** within existing 30Gi PVC (no Helm PVC size mutation) |

Discard policy remains `old` (limits retention). Prefer alerting when lag > 25% of MaxAge over silent success.

### Decision 6: Migration sequence

1. Deploy EventWriter + flow-collector that can **create/consume `flows`** while
   still reading `events` for the configured concrete `flows.raw.<name>`
   subjects (dual consumer, single publish target switches in step 2).
2. Cut flow-collector `stream_name` to `flows` (publish only to new stream).
3. Confirm EventWriter flow pipeline lag healthy; drain `events` netflow durables to zero pending.
4. Remove the configured concrete `flows.raw.<name>` filter consumers from the
   shared EventWriter pipeline and remove those subjects from `events` if they
   were listed.
5. Raise NATS file store / PVC as needed before raising stream max_bytes (JetStream rejects over-reservation).

Any `flow.host-slice.*` or `flow.attributed.*` entries found in historical
canary configuration are cleanup evidence, not subjects to transfer to the new
stream. Migration and rollback MUST NOT recreate a publisher, consumer, or
subject route for them.

**CNPG:** no dual-write. Only one EventWriter path inserts `ocsf_network_activity` for a given message (ack after insert). Dual-consumer window must use mutually exclusive stream sources (old stream drain + new stream only after cutover publish), not two consumers on the same messages.

**Downgrade boundary:** a plain Helm rollback to a pre-migration revision is not
safe. Helm restores the old image and `stream_name: events` ConfigMap together;
that image has no reverse-transfer logic and cannot attach a subject that the
`flows` stream still owns. Before restoring the old chart, operators MUST run the
current migration-capable image with `stream_name: events`, wait for its
ready-file gate and reverse-transfer confirmation, and only then start the old
image. `scripts/prepare-flow-collector-rollback.sh` performs and verifies this
sequence; `--prepare-only --target-config` validates the target revision's
rendered collector config without requiring Helm release history and supports a
paused GitOps downgrade.

### Decision 7: Telemetry and operator visibility

Emit / surface for the flow pipeline:

- pull request size vs demand
- `num_pending`, `num_ack_pending`, redelivery
- lag seconds (approx: now − oldest pending message timestamp if available, else stream first_ts age)
- retention risk when pending > 0 and stream utilization (bytes/age) high
- DB freshness gauge: `now() - max(ocsf_network_activity.time)` (existing reporters if present; extend)

The EventWriter lag reporter polls consumer INFO as before and, for flow
consumers, polls stream INFO once per unique stream each interval. It exposes
current bytes / MaxBytes and oldest retained-message age / MaxAge. Retention risk
is backlog-gated: warning at 75% byte utilization or 25% age utilization, and
critical at 90% byte utilization or 75% age utilization. Stream-INFO
availability is emitted separately so a polling failure cannot masquerade as a
healthy zero-utilization stream.

Dashboard “observed flows” tiles that use cumulative collector metrics SHOULD NOT be labeled as if they imply last-15-min map health (optional UI follow-up; not required for this change).

## Architecture (target)

```
Exporters
   │ UDP 2055/6343
   ▼
flow-collector ──publish──► JetStream stream `flows`
                            subjects: configured concrete flows.raw.<name> leaves
                            (including flows.raw.netflow and flows.raw.sflow)
                            max_bytes/max_age owned by flow config
   │
   │  pull (long-poll, demand-sized)
   ▼
EventWriter.FlowPipeline (Broadway)
   producer: flow-only demand domain
   batcher: configured concrete raw-flow leaves
   │
   ▼
platform.ocsf_network_activity
   │
   ▼
web-ng NetFlow map (last 15 min)

events stream (unchanged ownership)
   logs / falco / otel / … → EventWriter (existing pipeline)

netprobe → agent FlowAttributionEventBatch → gateway StreamStatus → core
         → platform.flow_process_attribution_current → core correlator
         → update matching platform.ocsf_network_activity row in place
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| JetStream cannot place R=3 large stream (storage budget) | Raise `max_file_store` + PVC first; temporarily R=1 for demo if needed |
| Migration gap loses flows | Dual-consume during cutover; cut publish only after consumers ready |
| Old-image rollback cannot reclaim subjects from `flows` | Run the guarded pre-downgrade reverse transfer with the current image before Helm/GitOps restores the old image; never claim plain rollback is safe across this boundary |
| Two Broadway pipelines double coordinator load | Flow pipeline only on coordinator; size CPU/memory; share NATS conn if safe |
| Long-poll holds server resources | Bound expires; cap concurrent pull inflight per durable |
| Large max_ack_pending increases memory | Keep producer buffer cap; demand still limits in-process queue |
| OTEL still points at `events` | No change; document that flows are out of band |

## Open Questions (resolved during implementation)

1. **Host-slice subjects** — the checked demo canary remains historical
   evidence, but `flow.host-slice.*` is retired and is neither merged into the
   dedicated stream nor reserved for future attribution routing.
2. **Attributed flows** — there is no `flow.attributed.>` production subject.
   The core correlator stamps the existing `platform.ocsf_network_activity` row
   in place from agent-up state in `platform.flow_process_attribution_current`.
3. **Demo R=3 vs R=1** — **keep R=3**. Size demo to `flows` 8 GiB / 2h MaxAge and `maxFileStore` 30G within the existing 30Gi PVC with reduced demo datasvc object/KV reservations (never mutate volumeClaimTemplates via Helm).
4. **Review fixes** — rehome only configured concrete `flows.raw.<name>`
   subjects; no stream-fallback for flow durables; collector owns retention
   reconcile; long-poll per-subject inflight accounting; lag reporter covers
   flow streams; docs never say `nats stream rm flows`; pre-migration Helm
   downgrade runs the current-image reverse transfer before restoring the old
   image.

## References

- Andrea Leopardi, [GenStage demand visualized](https://andrealeopardi.com/posts/genstage-demand-visualized/)
- `openspec/changes/fix-eventwriter-backpressure-hotpath` (pull + demand foundation)
- `openspec/notes/sr-data-flow.md` (ingest topology)
- Live demo RCA: nats-1 DiskPressure; shared events MaxAge ~30m; netflow consumer lag ~8k pending
