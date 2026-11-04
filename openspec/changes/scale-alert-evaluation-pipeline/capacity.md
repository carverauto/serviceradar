# Capacity model and audit of the current path

This file holds the numbers behind `design.md`. Part 1 states the assumptions
and derives target rates and per-node budgets. Part 2 audits today's path
stage by stage and shows where it breaks at those rates.

Every figure here is either (a) a rounded measurement quoted in the task brief
or in this repository, or (b) an assumption marked `[CONFIRM]`. The user
adopted the assumption table as the target on 2026-11-04 (design.md resolved
Q1). The `[CONFIRM]` marks stay because gate G4 replaces each assumption with
a measurement. No figure was taken from a live payload. Every example below is
synthetic.

Source of the code facts in Part 2: `staging` at `ee36df190e`.

## Part 1: Capacity model

### 1.1 Assumptions

| Id | Assumption | Value | Status |
|---|---|---|---|
| A1 | Design-point fleet | 100,000 monitored devices. 50,000 is the lower bound that must pass with margin | [CONFIRM] |
| A2 | Agent share of the fleet | 20% of devices run `serviceradar-agent` (sysmon, Falco, Trivy). The rest are polled or push syslog/traps/flows | [CONFIRM] |
| A3 | Log records, fleet mean | 1.0 record/s/device (syslog, OTel logs, traps). Stored size about 1 KB normalized, about 600 B on the wire | [CONFIRM] - the largest lever in the model |
| A4 | Direct OCSF events, fleet mean | 0.05 event/s/device (Falco, lifecycle, sweep state, integrations, k8s). Mean 4 KB; a Falco event is about 13 KB | [CONFIRM] |
| A5 | Log promotion match rate | 2% of log records promote to an OCSF event | [CONFIRM] |
| A6 | Metric points, fleet mean | 5 points/s/device (SNMP counters and sysmon after the process cap). About 155 B/point on the wire, 2,000 points/message | measured shape (sizing.md), rate [CONFIRM] |
| A7 | Flow records | 2 records/s/device fleet mean, about 100 B/record; not alert-evaluated | [CONFIRM] |
| A8 | Collector batching | log collectors pack at least 100 records per JetStream message; metrics about 2,000 points; flows about 100 records | target, not today (see B5) |
| A9 | Daily peak factor | 2x the mean for all signals | [CONFIRM] |
| A10 | Storm burst | logs and events 5x the mean for 5 minutes (a site outage, a reboot wave, a Falco storm); flows 3x; metrics 1.2x (polled) | [CONFIRM] |
| A11 | Active rules | 500 stateful rules (300 event, 200 metric) and 200 promotion rules | [CONFIRM] |
| A12 | Event match rate | 20% of events match at least one stateful rule; 1.5 rules per matching event | [CONFIRM] |
| A13 | Metric match rate | 5% of points carry a metric name some rule matches; 1.2 rules per matching point | [CONFIRM] |
| A14 | Active rule groups | groups with a non-empty window, an open incident or a running cooldown: 200,000 typical, 1,000,000 worst case | [CONFIRM] |
| A15 | Alert transitions | 1 fire/resolve per device per hour on average; 10x during a storm | [CONFIRM] |
| A16 | StarRocks enabled | the 100k design point assumes StarRocks is the telemetry store (`extend-starrocks-to-all-telemetry`). CNPG-only installations get a lower, stated ceiling (1.6) | decided by AGENTS.md |
| A17 | Log rule match rate | 1% of log records match a `signal: :log` stateful rule; 1 rule per match | [CONFIRM] |

### 1.2 Derived ingest rates

| Signal | Sustained records/s | Peak (A9) | Burst (A10) | Sustained wire MB/s | Burst MB/s | JetStream msgs/s sustained (A8) |
|---|---|---|---|---|---|---|
| Logs | 100,000 | 200,000 | 500,000 | 60 | 300 | 1,000 (100,000 if unbatched) |
| Direct events | 5,000 | 10,000 | 25,000 | 20 | 100 | 5,000 |
| Promoted events (A5) | 2,000 | 4,000 | 10,000 | n/a (derived in core) | n/a | 0 |
| Metric points | 500,000 | 1,000,000 | 600,000 | 75 | 90 | 250 |
| Flow records | 200,000 | 400,000 | 600,000 | 20 | 60 | 2,000 |
| **Total** | **about 807,000** | | | **about 175** | **about 550** | **about 8,250** |

Without collector batching (A8), log messages alone are 100,000 msgs/s
sustained and 500,000 msgs/s in a burst. That is a different NATS cluster, and
it is why A8 is a requirement, not a tuning option (see S1).

### 1.3 Derived alert-evaluation rates

- Event candidates: (5,000 + 2,000) x 20% x 1.5 = **2,100/s** sustained.
- Metric candidates: 500,000 x 5% x 1.2 = **30,000/s** sustained.
- Log candidates (A17, `signal: :log` rules, resolved Q6): 100,000 x 1% =
  **1,000/s** sustained.
- Total candidates: about 33,000/s. **Design target: 40,000 candidates/s
  sustained and 100,000/s for a 5-minute burst.**
- Candidate size (design D8). A candidate carries its projected fields
  whole, so it is sized from the payload it carries, at p99 per signal: an
  event candidate at 12.7 KB (a Falco trace), a log candidate at 1.4 KB (A3
  plus the envelope), a metric candidate at 400 B. At the 40,000/s target in
  the derived mix (about 2,540 event, 1,210 log and 36,250 metric candidates/s)
  that is about **50 MB/s sustained**. The A10 burst mix (10,500 event, 5,000
  log and 36,000 metric candidates/s) is about **155 MB/s**. Today's inbox
  copies about 12.7 KB jsonb per (event, rule) pair, for every candidate.
- Records that match no rule (about 93% of events, 95% of points and 99% of
  logs) cost one index lookup and produce nothing.

### 1.4 Block, node and storage budgets at the target

Layout: 1,024 fixed virtual partitions in 128 blocks (design D2). Design-point
settings: 4 candidate streams, 30 s checkpoint interval with a 50,000-candidate
cap, 10 min duplicate horizon (resolved Q5), 6 core replicas. A small install
uses the code defaults instead: 1 candidate stream, 10 s and 10,000
candidates, and whatever core nodes it has (design D11, gate G7).

| Budget | Sustained | Burst | Basis |
|---|---|---|---|
| Candidates per block | 312/s | 780/s | 40k/s and 100k/s over 128 blocks |
| Candidates per candidate stream | 10,000/s | 25,000/s | 4 streams; G4 measures the per-stream bound that drives split recommendations |
| Candidates per owner node | 6,700/s | 16,700/s | 6 nodes, about 21 blocks each |
| Hot-key ceiling (one rule+group) | 10,000/s | 10,000/s | one ordered owner process; gate G2 |
| Evaluator CPU | 2 cores cluster-wide | 5 cores | 50 us per candidate budget (decode, match recheck, state update) |
| Group state memory | 300 MB cluster (200k groups) | 1.5 GB (1M groups) | about 1.5 KB per active group in ETS |
| Duplicate-suppression memory | 384 MB cluster | +290 MB during a burst | 128-bit fingerprints x rate x 600 s |
| Checkpoint writes to CNPG | about 1,700 rows/s | about 4,000 rows/s | 50k dirty groups per 30 s typical |
| Dedupe slice writes to CNPG | 640 KB/s | 1.6 MB/s | closed 10 s slices, written once |
| Alert lifecycle writes | about 30/s | about 300/s | A15 |
| Coalesced incident metadata updates | about 170/s | about 500/s | 5,000 open incidents, one write per commit window |
| Failover replay | 9.4k candidates/block | 23k | checkpoint interval x block rate; under 2 s at replay speed |
| Candidate stream steady footprint | about 1.5 GB per NATS server | about 4.6 GB | 30 s since checkpoint at 50 MB/s and 155 MB/s; purged behind each checkpoint |
| Candidate stream outage budget | about 90 GB stored per server for 1 h | | 1 h of stored (S2-compressed) bytes at the sustained rate (resolved Q4): 50 MB/s x 3,600 s at p99 candidate sizes is about 180 GB before compression, divided by a conservative 2:1 S2 ratio that gate G4 measures and confirms; about 22.5 GB per stream at 4 streams |

Core CPU at the design point (estimates, to be replaced by gate G4 numbers):

| Stage | Sustained cores | Burst cores |
|---|---|---|
| Log decode and normalization (Zen rules in process), about 75 us/record | 7.5 | 37 |
| Event decode, Falco decomposition, promotion, about 200 us/event | 1.4 | 7 |
| Metric decode and row build, about 3 us/point | 1.5 | 1.8 |
| Routing through the compiled index, about 5 us per log or event and 1 us per metric point | 1.0 | 3.3 |
| Partition evaluation | 2 | 5 |
| **Total** | **about 13** | **about 54** (absorbed as lag, see below) |

The burst column is not provisioned for: a 5-minute burst above sustained
capacity becomes consumer lag, which the streams hold (1.5), and drains
afterwards. Provision for the daily peak (about 27 cores) with 30% headroom:
**6 core replicas x 6 vCPU, or 4 x 8 vCPU**. Each replica runs EventWriter
workers and owns its share of blocks.

NATS at the design point: about 175 MB/s sustained ingress; with R3 each
server writes every replica, so about 175 MB/s of disk writes per server plus
the candidate streams. Budget **3 servers minimum, 5 recommended; NVMe; 1-2 TB
JetStream file store per server** for a 30-minute source outage budget with S2
compression. That is above today's `large` profile (500 G), so the change adds
an `xlarge` profile (task 3.2). A small install keeps its current profile:
one candidate stream and one stream per signal.

StarRocks at the design point: about 800,000 rows/s and about 175 MB/s raw.
With 5-10x columnar compression that is about 1.5-3 TB/day of object storage.
**StarRocks keeps its one-year default retention (resolved Q1), so a
100,000-device installation holds about 0.5-1 PB of object storage at
steady state.** At 50,000 devices it is half that. The figure scales
linearly with A3, A6 and A7, and per-dataset retention settings are the
operator's lever to reduce it. The operator documentation states this figure
(task 7.3,
the capacity planning page).

CNPG at the design point holds only the control plane: alert lifecycle,
checkpoints, leases, rule configuration. The alert path's budget is under
5,000 row writes/s at burst, against today's about 10 statements and 12.7 KB
per candidate.

### 1.5 Backpressure budget (never loss)

The time the system absorbs a stalled stage without losing accepted data is
the sum of the buffers in front of it:

1. Candidate streams: 1 h at the sustained candidate rate (resolved Q4).
2. When the candidate streams are full, the router stops acknowledging its
   source messages, so the source streams hold the backlog: 30 min at the
   sustained ingest rate.
3. When a source stream is full, publishers are refused (DiscardNew).
   Edge-record agents and collectors with a spool buffer locally. Protocols
   without retransmission (UDP syslog, traps) are counted as refused at the
   collector, which is the only place the pipeline may refuse a record
   (resolved Q8).

Health turns degraded at 60 s of evaluation lag and critical at 10 min, long
before stage 2 engages.

### 1.6 CNPG-only installations

Without StarRocks, logs and events are stored in CNPG hypertables. The repo's
own measurements of the CNPG bulk path are about 10,000-20,000 rows/s on one
write path (`fix-eventwriter-backpressure-hotpath/sizing.md`). The supported
ceiling without StarRocks is therefore about **10,000 log records/s sustained,
roughly 10,000 devices at A3**. Alert evaluation itself does not depend on the
store and scales the same with or without StarRocks.

## Part 2: Audit of today's path

### 2.1 Measured on the demo deployment (v1.4.101), rounded

- About 43,700 "EventWriter message reached terminal JetStream delivery"
  errors in 6 h (about 2/s). All were Falco batches that alert admission
  refused with `{:overloaded, :rule_bytes}`. After `max_deliver=5` the
  message is terminated and its evaluation is lost; the log and event rows
  were already stored.
- About 300-400 inbox completions per minute per rule (about 6/s).
- The per-rule byte budget is 8 MB. Falco bursts reached about 5,000
  events/min.
- Each eligible (event, rule) pair copies about 12.7 KB jsonb into
  `platform.alert_evaluation_work`.
- `Inbox.eligible?` admitted every event to every anomaly-open rule. That fix
  is landing separately and is not repeated here.

### 2.2 Stage-by-stage costs and breaking points

| Stage | Today (code fact) | Cost per unit | Ceiling today | Needed at target | Factor short |
|---|---|---|---|---|---|
| S1 Log collector publish | flowgger publishes one record per JetStream message and awaits each PubAck before the next (`rust/flowgger/src/flowgger/output/nats_output.rs`, `run/1`) | one RTT per record | about 0.5-2k records/s per instance | 100k/s | 50-200 instances, or batching |
| S2 Source stream | `logs.>`, `events.>`, OTel and Falco share stream `events`: R1, 2 GiB, discard-old, 24 h (`EventWriter.Config` fallbacks) | n/a | at 80 MB/s (logs + events) about 25 s of backlog before accepted, unprocessed messages are evicted | 30 min outage budget | about 70x, and R1 loses data on a server failure |
| S3 EventWriter batching | batcher concurrency 1 per signal per replica; 100 rows / 1 s batches; pull 16; `max_ack_pending` 256 per worker | one synchronous CNPG insert + StarRocks load + evaluation per 100 rows | about 0.5-2k rows/s per signal per replica | 100k logs/s | 15-60x on 3 replicas |
| S4 StarRocks loads | one Stream Load per Broadway batch (at most 100 rows) | one load transaction per 100 rows | demo ran about 50 loads/min across 9 tables | 100k rows/s would be about 1,000 loads/s on `logs` | StarRocks sustains on the order of 1-10 loads/s per table before version/compaction pressure |
| S5 CNPG telemetry dual-write | logs and events are written to CNPG and shadowed to StarRocks (`Destination.persist_after_cnpg/3`) | one hypertable insert per row | about 10-20k rows/s per write path | 0 when StarRocks is enabled | resolved by `extend-starrocks-to-all-telemetry` |
| S6 Evaluation ledger | `StatefulEvaluationLedger` reads then inserts one CNPG row per event, 3-day retention | 2 statements per event | n/a | 7k events/s | about 1.8 billion rows per 3 days |
| S7 Admission | one global exclusive advisory lock (`alert-evaluation:admission:v1`) plus `LOCK TABLE stateful_alert_rules` for every slice from every replica; `count(*)` and `sum(payload_bytes)` over all of `alert_evaluation_work`; replay lookup across work and receipts; lane upsert; 12.7 KB jsonb per (record, rule) | serialized deployment-wide | one admission transaction at a time, cluster-wide | 40k candidates/s | admission is a single global critical section |
| S8 Per-rule budget | 8 MB and 5,000 rows per rule; 64 MB and 50,000 rows pending | n/a | 8 MB / 12.7 KB = about 630 Falco occurrences | 5,000/min burst fills it in about 8 s | refuses, then dead-letters at `max_deliver=5` |
| S9 Evaluation | Oban queue `alerts` concurrency 5 per node; each occurrence is one transaction: advisory lock, head read, rule read, lane read, **restore every group snapshot of the rule `FOR UPDATE`**, state machine, snapshot upserts, receipt insert, work delete; quantum 16 then `snooze 1` | about 10 statements plus O(groups of the rule) rows per occurrence | about 6/s per rule, at most 15 rules at once on 3 nodes: about 90/s cluster | 40k/s | about 450x; and O(groups) per occurrence grows with the fleet (a rule grouped by device reads 100k rows per occurrence at 100k devices) |
| S10 Open incident sync | `sync_active_incident/4` loads and updates the alert row on every matching record while an incident is open | 2 statements per record on one hot row | n/a | a 5,000/min burst on one incident is about 80 updates/s to one row | write amplification on a hot row |
| S11 Receipts | one `alert_evaluation_receipts` row per (rule, source key), 7-day retention | 1 insert per occurrence | n/a | 40k/s x 7 d | about 24 billion rows |
| S12 Lifecycle pending admissions | one CNPG row and one row-locked transaction per occurrence; the drain worker admits at most 1,000 per 30 s run | per occurrence | about 33/s drained | lifecycle bursts | FIFO is correct, throughput is not |
| S13 Single-writer processors | `ANALYTICS_PREDICTIONS`, causal streams, `K8S_INVENTORY` and `TRIVY` run only on the coordinator (`scale-event-writer-across-core-replicas` Decision 3) | one batcher on one node | one node | lifecycle and Trivy at fleet scale | does not scale out |
| S14 Rule cache refresh | `LogPromotion` and `MetricAlertAdmission` refresh rule caches by TTL (5 s); `LogPromotion` writes `:persistent_term` on every refresh | a global GC pass over all processes per `persistent_term` write | n/a | a busy node has tens of thousands of processes | latency spikes every 5 s per node |

Two correctness findings fell out of the audit:

- **`signal: :log` stateful rules never run.** `StatefulAlertEngine.evaluate_logs/1`
  has no caller anywhere in the tree (`git grep evaluate_logs`), yet
  `TemplateSeeder` seeds `burst_errors` with `signal: :log` and the resource
  defaults `signal` to `:log`. The spec says rules evaluate OCSF events rather
  than raw logs, so the seeded rule is inert by construction. This change
  evaluates them through the index (resolved Q6).
- **Accepted telemetry can be evicted before it is processed.** The `events`
  stream is discard-old. Once the backlog exceeds 2 GiB, JetStream deletes the
  oldest messages whether or not any consumer has seen them.

### 2.3 Top breaking points at the target

1. **Alert evaluation throughput (S7, S9).** About 90 completions/s
   cluster-wide against 40,000 candidates/s needed, about 450x short.
   Admission is one global critical section. Each occurrence costs about 10
   CNPG statements plus a `FOR UPDATE` read of every group snapshot of its
   rule, which grows with the fleet.
2. **Admission budget and terminal drop (S8, measured).** 8 MB per rule holds
   about 630 Falco occurrences, which a 5,000/min burst fills in about 8 s.
   Refusal fails the batch; after 5 deliveries JetStream terminates it. About
   2 evaluations/s were lost on demo, before any scale.
3. **Source stream buffer and policy (S2).** One R1, 2 GiB, discard-old
   stream carries logs, events, OTel and Falco. At the target it holds about
   25 s of backlog, after which accepted messages are evicted unprocessed, and
   one NATS server failure loses its contents.
4. **EventWriter batch shape and warehouse loads (S3, S4).** One batch of at
   most 100 rows at a time per signal per replica, each with a synchronous
   store, a Stream Load and an evaluation call. 100k logs/s needs about 1,000
   batches/s and would issue about 1,000 Stream Loads/s against one table.
5. **Collector publish model (S1).** One record per message with a
   synchronous PubAck caps each syslog collector at about 0.5-2k records/s
   and would put 100k-500k msgs/s on JetStream.

Close behind: the per-event CNPG ledger and receipts (S6, S11: hundreds of
millions to billions of rows), the hot-row incident sync (S10), and the
coordinator-only lifecycle and Trivy processors (S13).
