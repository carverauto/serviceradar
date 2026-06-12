## Context

Marvin Hansen's DeepCausality example `corrective_ddos_detector` demonstrates real-time anomaly detection + corrective intervention over a continuous stream using a sliding window and a scale-invariant z-score. The ask: bring this to ServiceRadar for (a) interface-bandwidth DoS detection and (b) cross-resource capacity planning — and answer "how do we run this over a continuous stream rather than querying Postgres?"

This design is grounded in three verified inputs:

1. **The DeepCausality example** — digested from the upstream source.
2. **The live ServiceRadar stream topology** — verified against the demo cluster (`serviceradar-tools` pod, `demo` namespace, 2026-06-12) with the authenticated `nats` client.
3. **The existing `add-causal-engine` change + adjacent changes** — read in full to place this layer correctly and avoid duplication.

### Verified live NATS topology (demo, 2026-06-12)

Streams: `events` (1 GiB, `limits` retention; subjects `otel.traces.>`, `otel.metrics.>`, `logs.*`, `flows.raw.netflow`, `flows.raw.sflow`, `falco.logs`, `flow.host-slice.<agent>`, `pdns.ocsf`), `attributed_flow` (`flow.attributed.>`), `trivy_reports` (`trivy.report.>`), `ARANCINI_CAUSAL` (`arancini.updates.>`, 1.27M msgs — the causal-engine input feed).

- `otel.metrics.derived` (span RED JSON) was flowing heavily during sampling; `flows.raw.*` / `flow.attributed.>` were quiet in the demo window (flow collection not active on every agent), but the subjects/streams exist and are subscribable.
- **`telemetry.>` is on no JetStream stream** — generic SNMP/interface telemetry is not persisted to JetStream in demo (core-NATS only or inactive). Detection should not assume `telemetry.>` durability.
- The `events` stream already has ~11 durable consumers using `filter_subjects` (`db-event-writer`, `log-promotion`, per-type `serviceradar-event-writer-*`, `zen-consumer`). **A new filtered durable attaches without disturbing them** — this is the proven attach pattern.

### The load-bearing asymmetry

| Signal | On NATS? | Path |
|---|---|---|
| OTel metrics (span RED + raw) | **yes** | `otel.metrics.>` on `events` stream |
| NetFlow / sFlow | **yes** | `flows.raw.netflow|sflow` on `events` stream |
| Attributed flows | **yes** | `flow.attributed.>` on `attributed_flow` stream |
| Interface SNMP counters | sometimes | `telemetry.>` (not durable in demo) |
| **Sysmon cpu/mem/disk/process** | **NO** | agent → gateway → core **gRPC `StreamStatus`** → CNPG (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`) |

So **use case (a) interface bandwidth has a live stream today**; **use case (b) capacity (cpu/mem/disk) does not** — its source is gRPC-only and lands directly in CNPG. There is **no pgoutput/logical-replication CDC** (a deliberate decision in `add-causal-engine`); the rule is *never stream TimescaleDB hypertables — query them on-demand via SRQL*.

## Goals / Non-Goals

**Goals**
- Real-time, per-series statistical anomaly detection on live metric streams, with learned baselines (no per-interface manual thresholds).
- Sustained-surge confirmation that does not self-mask under a prolonged flood.
- **Seasonal-aware detection** — answer "is this abnormal for a Tuesday 9am?" via per-series day-of-week × hour-of-day profiles, consulted in real time.
- Capacity forecasting with *time-to-exhaustion* over a multi-month horizon.
- **Horizontally scalable, stateful consumers** — stateless reasoning + Horde-owned context across the core-elx replica set (no new standalone consumers; autoscaler optional).
- Reuse the existing causal-engine emission spine and alert pipeline end-to-end.

**Non-Goals**
- Auto-remediation / traffic throttling in V1 (specified as a future feature-flagged phase with bounded-intervention discipline).
- Streaming hypertables / building a CDC pipeline (explicitly forbidden by the existing architecture).
- Replacing `add-interface-metric-thresholds`' static thresholds — this is the dynamic complement.
- ML/deep-learning forecasting in V1 (start with transparent statistical models).
- Edge/leaf *deployment* (leaf JetStream domain, stream source/mirror to hub, edge agent-gateway packaging) — future work; Phase 0 is only built leaf-*compatible* (Decision 16).

## Decisions

### Decision 1 — Detector = core-elx Broadway consumer + DeepCausality Rustler NIF (pure reasoner)

**Chosen: the detector runs in core-elx as a Broadway consumer that routes each sample into a DeepCausality Rustler NIF.** The NIF is a **pure reasoning function** `reason(context, sample) -> verdict` with no resident per-series state (see Decision 14). Rationale:
- core-elx is already a **libcluster/Horde cluster** of replicas — the right substrate to scale the consumer horizontally and to host the distributed context engine (Decision 14). A standalone Rust service would have to reinvent that clustering.
- Broadway already consumes the metric streams and gives demand-driven backpressure + batching for free.
- Keeping the reasoner a **stateless pure function** means it can run identically on every core-elx pod and scale by round-robin — the per-series state problem is solved by separating context from reasoning, not by pinning the engine to one place.
- Reuses the DeepCausality dependency the platform already carries (it backs `god_view_nif` / `rust/causal-engine`); this change adds the Flow-API crates (`deep_causality_core`, `deep_causality_data_structures`).

**The standalone `rust/causal-engine` is NOT where the detector lives** — instead it **consumes** the anomaly/capacity verdicts as causal evidence (a future causaloid). This supersedes the earlier framing that put the detector inside `rust/causal-engine`; the libcluster/Horde scaling story (Decision 14) makes the in-core-elx NIF the correct home.

### Decision 2 — Detection algorithm: clean-baseline z-score + sustained-slot confirmation

Ported from `corrective_ddos_detector`:
- Maintain a per-series `SlidingWindow<ArrayStorage<f64, SIZE, CAP>>` (`ArrayStorage`, ~2 ns push, no_std + alloc, ~2× over-alloc; compute mean/stddev from `.slice()` — there is no built-in mean/stddev/max).
- z-score = `(sample - mean) / std`, where `std` uses **sample variance (n−1)** over the window; only computed once the window is `filled()`.
- **Withhold-anomalous-from-baseline (load-bearing):** push a sample into the baseline window **only when it is not flagged anomalous** (`if !anomalous { window.push(v) }`). This is what lets a sustained flood keep reading anomalous for its full duration; a naive "value > this window's own mean + 3σ" self-masks as the flood enters the mean.
- Confirm on **N-sigma exceedance over M consecutive slots** (defaults N = 3.0, M = 5); reset the consecutive counter on a clean tick. This is the sustained-surge gate that separates a DoS from a transient spike.
- Per-series config: `n_sigma`, `confirm_slots`, `window_size`, `min_samples`, with platform defaults; overridable per metric class (interface vs service RED).

The control loop uses the `CausalFlow` Flow DSL conceptually (`bind(analyze) -> branch_with(trigger, hot, cold)`), but real-time replaces `iterate_n(N, …)` with a **per-sample driver** invoked from the JetStream subscriber callback. The detector is **synchronous and Markovian** — each sample threads state forward; no async inside the detector.

### Decision 0 — All metrics on JetStream first (ingestion uniformity)

The asymmetry above is treated as a **defect to fix, not a constraint to design around**. The platform rule (codified in `AGENTS.md` Hard Rules and `openspec/project.md`): **every metric source publishes to NATS JetStream first and is persisted into CNPG by the `event_writer` consumer pipeline; nothing writes metrics directly to the database.** A metric that lands straight in a hypertable is invisible to real-time consumers (anomaly detection, the causal engine) until queried back out — that is the whole problem.

**Track 0 covers every metric source not already durably on JetStream**, onto a **dedicated `metrics` stream** (subjects `metrics.>`; `limits` retention — see Decision 9):
- **Sysmon** cpu/mem/disk/process — migrate off the gRPC `StreamStatus` direct-to-DB path (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`) onto `metrics.sysmon.*` + a new `event_writer` processor; retire the direct CNPG write; core ingests from the JetStream consumer instead.
- **SNMP interface telemetry** — verified **not durable on JetStream today** (`telemetry.>` is on no stream; a live `nats sub` returned nothing). Route SNMP interface counters (ifHCInOctets/ifHCOutOctets with `if_index`) onto `metrics.snmp.*` so interface anomaly detection has a reliable live feed and the data is durably persisted by the DB-sync consumer.

Each is sequenced behind a cutover flag (publish-and-shadow → switch the writer → remove any legacy path). Flow/OTel metrics already on the `events`/`attributed_flow` streams may migrate onto the dedicated `metrics` stream over time for consistency, but that migration is not required by this change.

### Decision 3 — Stream feeds (after Track 0)

- **Interface bandwidth (a):** consume `flows.raw.netflow|sflow` + `flow.attributed.>` for network throughput, and `otel.metrics.>` for service RED. SNMP interface octet rates (`telemetry.>`) are consumed when durable; otherwise interface baselining falls back to the CAGG cold-start path.
- **cpu/mem/disk/process (a + b):** with Track 0 these are **live subjects**, so the same per-sample detector covers host-resource anomalies in real time — not just capacity. Track 2 capacity forecasting still reads the hourly CAGGs via SRQL on a cron (forecasting is inherently a long-horizon batch over aggregated history, regardless of live availability); the live stream and the CAGG history are complementary, not redundant.

### Decision 4 — Baseline cold-start from CAGGs via EmbeddedSrql

A fresh `SlidingWindow` is empty, so detection is blind until it fills. On startup and on first sight of a series, seed the baseline by querying the hourly CAGG (`timeseries_metrics_hourly` / `*_metrics_hourly`) via `EmbeddedSrql` (request/response — **not** a stream) for that series' recent normal, then switch to live-stream updates. This bounds the warm-up window and survives engine restarts.

### Decision 5 — Output via the existing causal-engine spine

Emit an anomaly/forecast verdict through the existing `emitter` to `signals.causal.predictions.*` (new verdict kinds `anomaly`, `capacity_forecast`) with deterministic IDs. The existing `CausalSignals` processor + `pipeline.ex` route the `signals.causal.*` prefix into `ocsf_events`; from there `StatefulAlertEngine.evaluate_events/1` raises `device.uid`-grouped alerts and the God-View renders. **Zero new inbound plumbing.** Anomaly findings use OCSF `detection_finding` (class_uid 2004); the finding/event separation is governed by `add-ocsf-finding-model`. (The direct `events.anomaly.*` → events-batcher route also exists and reaches `ocsf_events`; we prefer the causal spine so anomalies are available to causal reasoning, but the spec permits either as the routing detail.)

### Decision 6 — Capacity forecasting is a separate batch model (NOT DeepCausality)

DeepCausality has **no forecasting primitive** (only `Uncertain<T>`/`MaybeUncertain<T>` value-uncertainty, not horizon projection). Capacity planning is therefore a distinct layer:
- An **Oban cron** job in core-elx reads the long-horizon hourly/daily CAGGs (cpu/mem/disk/process `_hourly` @395d; `flow_traffic_1h/1d` @365d; `timeseries_metrics_hourly`) via SRQL.
- Fit a transparent model first: **least-squares linear trend** for runway, plus **Holt-Winters / seasonal decomposition** where daily/weekly seasonality matters (interface traffic, cpu). Compute projected value at horizon + `projected_exhaustion_at` + a confidence/interval.
- Persist to a new `capacity_forecast` resource (Ash + raw-SQL migration per the hypertable convention) and emit a `capacity_forecast` verdict for at-risk resources so they flow into alerts and the God-View `projected_exhaustion_at` placeholder.
- **Per-interface gap:** `timeseries_metrics_hourly` has no `if_index` group key — add a per-interface hourly rollup (new CAGG or interface grouping) so link-saturation runway is computable. The capacity denominator joins live `discovered_interfaces.speed_bps` (only 3 d retention, no CAGG — utilization% is computed against current inventory, not historical capacity).

### Decision 7 — DeepCausality dependency upgrade (the "new Flow API")

Add to `rust/causal-engine/Cargo.toml`: `deep_causality_core` (monad + `CausalFlow` Flow DSL + `PropagatingProcess`/`PropagatingEffect`) and `deep_causality_data_structures` (`SlidingWindow`). Pin to versions shipping the Flow API (≈ `deep_causality_data_structures` 0.10.14, Rust edition 2024). This composes with the existing `ultragraph 0.9` pin used by the engine's graph causaloids; the BUILD/bazel deps must be updated alongside Cargo (new Rust imports break `bazel test` even when `cargo` passes).

### Decision 8 — Bounded-intervention safety (future, feature-flagged)

V1 is **detect-and-alert only**. The example's `intervene` (THROTTLE_ON) arm maps to a future guarded-remediation phase governed by the TCAS-style discipline (the "arity-5" = 5 `PropagatingProcess` channels: Value·State·Context·Error·Log): (1) trigger/score, (2) persistence/duration gate, (3) already-acting interlock, (4) clamp the action to a safe envelope, (5) audit-log every override. Any auto-action ships behind a feature flag with these five gates specified before enablement.

### Decision 9 — Dedicated metrics stream + consumer fan-out (the ack model)

**A dedicated `metrics` JetStream stream** (subjects `metrics.>`, e.g. `metrics.sysmon.*`, `metrics.snmp.*`, with flow/otel metrics migrating onto it over time) is the target for Track 0. It **MUST use `limits` (or `interest`) retention — never `workqueue`.** This is load-bearing: JetStream consumers are independent fan-out views, each with its own cursor, and under `limits` retention **an ack only advances that consumer's position; it does not delete the message.** So multiple durable consumers each receive every message.

This fan-out model is verified live on the existing `events` stream (`retention: limits`, `discard: old`, `max_age: 1800s`): `db-event-writer` (durable, `deliver_policy: all`, `max_deliver: -1`) **and** `serviceradar-event-writer-otel-metrics` (durable, explicit ack) **already both consume `otel.metrics.>` independently** — which is exactly the double-write defect Phase 0 fixes (Decision 15). After Phase 0 the **DB-sync consumer is a core-elx EventWriter (Broadway) consumer, not the retired Go `db-event-writer`**; the real-time analysis consumer is a third independent consumer whose ack has zero effect on it (own cursor; `limits` retention never deletes on ack). A `workqueue` stream (delete-on-first-ack) would break this and is forbidden for metrics.

Two consumer profiles, by job (post-Phase-0):

| | DB-sync consumer (core-elx EventWriter → CNPG) | Real-time analysis consumer (anomaly path) |
|---|---|---|
| Durable | yes | optional (ephemeral, or durable + short `inactive_threshold`) |
| `deliver_policy` | `all` (catch up; no data loss) | **`new`** (live only; never replay a backlog) |
| `ack_policy` | explicit, `max_deliver: -1` (at-least-once) | explicit or none — own cursor only |
| Durability needed | yes — must not lose DB data | no — dropping samples during downtime is acceptable; reseeds from CAGGs |

Both consume the **raw** stream **in parallel** — analysis never waits on the DB write (Decision 15).

The stream's short `max_age` means the detector cannot replay a long backlog even in principle, which is why `deliver_policy: new` + CAGG cold-start is the only sane restart model (Decision 10).

### Decision 10 — Restart survival

Only the **context engine** is stateful (the reasoner is pure, Decision 14), so restart handling is confined to it:
1. **`deliver_policy: new`** on the analysis consumer — on reconnect it resumes live and does not replay a backlog (the 30-min stream age forbids it anyway).
2. **Per-series context checkpoint** to JetStream KV (small: last N window samples + counters + last-fired). When a Horde context-owner process is (re)placed — on restart, scale, or node-loss handoff — it **rehydrates from the KV checkpoint**, then resumes folding live time-ordered updates. Because updates are time-ordered and idempotent, replaying the tail after the checkpoint is safe.
3. **Cold-start fallback** for series with no checkpoint (first boot, new interface): seed baseline statistics from the hourly CAGG via SRQL and **suppress findings until the window re-warms** (the min-samples guard). A brief post-restart/handoff detection gap is acceptable and documented.
4. **Track 2 capacity forecasting is stateless across restarts** — it recomputes from CAGGs each run, so it has no restart concern at all.

### Decision 11 — Baseline time constants: three tiers, not one

The rolling window is deliberately **short and recent** — it is the wrong tool for slow trends or seasonality, and that is by design, not a gap:

- **Tier A — streaming spike detection (Track 1):** bounded rolling window, **minutes to tens of minutes**, in-memory. `baseline_duration = window_size × sample_interval`; at sysmon's 10–60 s cadence, ~30 samples = 5–30 min. Enforce a **min-samples floor (~20–30)** so the mean/variance are statistically stable (too short → noisy baseline → inflated threshold → missed spikes). This catches *sudden* surges (DoS, runaway process) well. The "baseline exceeded for X period" is a **separate knob** — the M-consecutive-slot confirmation (`M × interval`) — not the baseline length.
- **Tier B — capacity forecasting (Track 2):** weeks–months from the CAGGs, batch. Catches *slow ramps* toward exhaustion that any short-window detector misses (boiling-frog).
- **Tier C — seasonal-baseline anomaly (IN SCOPE — see Decision 13):** "abnormal vs the same hour last week." A short rolling z-score cannot do this (a normal Monday-9am ramp false-positives against a 5-min window). The seasonal profile is the right structure and is consulted by the streaming detector per-sample, not just a delayed batch pass.

**Is the rolling window long enough for cpu/mem/disk/interface spikes?** For sudden spikes, yes — when window length is configurable per metric class and respects the min-samples floor. It is intentionally not long enough for slow trends (→ Tier B) or seasonal context (→ Tier C). The detector combines all three signals.

### Decision 13 — Seasonal-baseline detection (first-class)

"Is this abnormal for a Tuesday 9am?" requires modeling periodic seasonality, which the rolling window cannot. Approach:

- **Seasonal profile per series, keyed by (day-of-week × hour-of-day)** — 168 buckets. Each bucket holds a **robust** center and spread (**median + MAD**, not mean/σ, so a past incident in the history does not poison the profile). Profiles are computed from the **hourly CAGGs** over the last K weeks (395-day CAGG retention ≈ 56 weeks — ample for stable weekly seasonality).
- **Computed in batch** (refreshed ~daily), persisted to CNPG, and **consulted by the streaming detector per-sample as a second baseline.** A live sample is scored against both the short rolling window (sudden) and the seasonal bucket (off-pattern), so seasonal awareness is real-time, not a delayed batch verdict. The same profile also supports a standalone batch seasonal evaluation.
- **Three combined signals:** rolling-window z-score (sudden) · seasonal-profile deviation (off-pattern) · trend/forecast (slow exhaustion, Track 2). The detector fires on a configurable combination per metric class.
- **Reliability guardrails:** require a minimum weeks-of-history before a bucket is trusted (fall back to the rolling window until then); use robust statistics; expose the seasonal sensitivity as a config knob (Decision 12). **Upgrade path:** STL decomposition / Holt-Winters (seasonal+trend+residual, ESD on residuals) — which also unifies with the Track 2 forecaster. **Known limitation (documented, not solved in V1):** holidays / irregular non-weekly events.

### Decision 14 — Horizontal scalability: separate context from reasoning (UUIDv8 total order + Horde)

The naive view is "the detector is stateful per series, so pin each series to one consumer (partition by series key)." That works but is rigid. The better model — and the one that fits core-elx's libcluster/Horde substrate — is to **separate context from reasoning** so the hot path is stateless:

- **Reasoning is stateless and round-robinnable.** The DeepCausality NIF is a pure function `reason(context, sample) -> verdict`. It holds no resident state, so any core-elx pod can evaluate any sample. Reasoners scale by plain round-robin across all pods — **no affinity required.**
- **The stateful surface is confined to the context engine.** Context = the small per-series state (rolling-window stats, seasonal profile, counters). The "multiple producers updating the same series' context" problem is confined here and is solved with **total temporal order via a time-ordered ID**: every context-update event carries a **UUIDv8** with an embedded high-resolution timestamp (Marvin's recommendation — UUIDv8 gives the same k-sortable property as KSUID but is a standard UUID); the context engine folds updates **in total temporal order**, so the result is deterministic regardless of which pod produced an update or in what order they arrived. This is event-sourcing — `context = fold(time-ordered updates)` — and the ID also gives **idempotency** (dedupe replays), making restart/replay safe.
  - **Why a time-ordered ID, not "just a DB transaction":** ACID transactions give *partial* (serializable) order, not a single global timeline; concurrent updates from N pods can serialize in ways that don't reflect real event time. The context fold needs **total order keyed on event time**, which a UUIDv8 sort provides directly. This is a meaningful engineering task, not plumbing.
- **The context engine maps onto Horde.** core-elx is already a libcluster/Horde cluster, so run **one context-owner process per series (or per shard)** under `Horde.Registry` + `Horde.DynamicSupervisor`: location-transparent (any pod routes a series' updates to its owner), **single-writer-per-series** (so the time-ordered fold is enforced per series), with automatic failover/handoff on node up/down. Built on distributed Erlang/ERTS (EPMD) — you do not hand-roll term-passing. Context is small, so it can be **checkpointed to JetStream KV** (re-spawned owner rehydrates) and/or **shipped immutably in the message** to stateless reasoners.
- **This supersedes "partition the JetStream consumer by series key."** JetStream subject partitioning can still provide ingest parallelism, but per-series ownership/ordering belongs to Horde + the time-ordered fold, which gives failover and location-transparency that static partitioning does not.
- **Scaling is BEAM-native.** Since we are *deleting* standalone consumers (Decision 15), the anomaly/ingestion work lives **inside core-elx**. Horizontal capacity comes from **core-elx replica count** (libcluster/Horde redistributes context ownership across nodes automatically) plus **Broadway processor concurrency within each node** (demand-driven backpressure absorbs bursts). There is **no external autoscaler dependency** — capacity is added by adjusting the core-elx replica count, and the cluster rebalances itself. (If ingestion isolation is ever needed, the "consumer-role" core-elx deployment from Decision 15 is the path — a future topology choice, not this change.)
- **Broadway nuance (you flagged this correctly):** Broadway is not a standalone pod — it is a GenStage topology inside the BEAM with its own internal concurrency + demand backpressure. So the layers are distinct: **core-elx replica count scales pod-level capacity; Broadway's processor/batcher concurrency scales within a pod** via config. Multiple pods share the same pull consumer (queue-group semantics) and Horde distributes series ownership across them — no standalone consumer to fire up.

### Decision 12 — Configuration lives in CNPG + settings UI, seeded from Helm

All detector and forecast tuning knobs are operator-facing and MUST be editable without a redeploy: N-sigma threshold, window size/duration, confirm-slots (the "for X period"), min-samples, per-metric-class overrides (interface / RED / cpu / mem / disk), forecast horizon, warning threshold, and model choice (linear / seasonal). These are stored in **CNPG (an Ash resource)**, **seeded from Helm chart defaults on first boot**, and edited in the **settings UI**. The engine reads config from CNPG with periodic refresh / hot-reload, so changes take effect without restarting the detector. This follows the existing observability-rule-management / settings pattern; stream and consumer config (retention, subjects) remain Helm/infra-managed.

### Decision 15 — Phase 0: rectify the ingestion pipeline (the prerequisite)

**Who publishes to NATS today (verified in code):**
- **External collectors publish raw subjects directly:** `rust/otel` → `otel.metrics.raw|derived`, `otel.traces.raw`, `otel.logs` (`rust/otel/src/nats/publish.rs`); `rust/flow-collector` → `flows.raw.*`; `rust/trapd` → `logs.snmp`; falco → `falco.logs`.
- **Agent telemetry (OTLP) round-trips through core:** agent → agent-gateway (gRPC `StreamStatus`, OTLP chunked at the edge) → gateway forwards to **core, which publishes the chunks to NATS** (`status_handler.ex:281 publish_otlp_relay_records`; agent-gateway has no NATS publisher today) → consumed back by core-elx + db-event-writer. It is a **pure relay** (no transformation at core).
- **core-elx itself publishes** (genuine publish-then-read-back loops): internal logs it generates (sweep/health/onboarding/jobs/audit via `InternalLogPublisher`), `signals.state.*` (`state_change_publisher.ex`), and **attributed flows** — it consumes `flows.raw.*`, correlates, **publishes `flow.attributed.<partition>`** (`attributed_flow_joiner.ex:62`), then **its own Flows processor consumes `flow.attributed.>`** and writes the DB (a partition-routing self-loop).
- Then **both** core-elx EventWriter **and** the Go `db-event-writer` consume and write CNPG — the double-write.

So the user's "what is going on" is justified: there are real publish-then-read-back paths, a redundant second writer, and normalization in a third component. Target state:

| # | Current defect (verified) | Target state |
|---|---|---|
| 1 | **Double-write** to `otel_*`/`ocsf_events`/`logs` by both `db-event-writer` and core-elx, surviving only on identical PKs + `ON CONFLICT DO NOTHING` (`otelmetricpoints.go:1-31`). | **One writer.** core-elx EventWriter is the **sole** CNPG persister. |
| 2 | **`db-event-writer` (Go)** is a near-dumb persister; archived `rewrite-db-event-writer-elixir` already intended to replace it. | **Delete `db-event-writer`** (consumer + helm + config). |
| 3 | **Sysmon/host metrics bypass JetStream** (gRPC → ingestors → CNPG). | **Sysmon + SNMP interface metrics on the dedicated `metrics` stream** (Decision 9); core-elx persists. No direct-to-DB. |
| 4 | **Normalization lives in a third component** — the standalone Rust **`serviceradar-zen`** consumer (`logs.* → zen → logs.*.processed → db-event-writer`). | **Fold the ZEN rules engine into core-elx as a Rustler NIF** and **delete the standalone `serviceradar-zen` consumer.** core-elx consumes raw → runs ZEN normalization in-process (NIF) → writes CNPG. One consumer, one component. (Coordinate `add-event-writer-processor-contributions` passthrough engines — don't duplicate.) |
| 5 | **Inconsistent ingress** — OTLP enters two ways (collector vs core-relay), sysmon via gRPC-to-CNPG, core self-publishes some subjects. | **Every telemetry type is published to JetStream by a defined producer, on the producer's *local* NATS (leaf or hub); core-elx never publishes-then-reads-back.** Relayed OTLP → **agent-gateway publishes `otel.*.raw`** (agent pre-chunks); direct OTLP → `rust/otel` collector gRPC receiver publishes `otel.*.raw`; RED derivation (`otel.metrics.derived`) is a JetStream consumer step; flows → `flow-collector`; SNMP traps → `trapd`; agent gRPC status (sysmon) → **agent-gateway publishes `metrics.*`** (agents are NATS-denied, so the gateway is the boundary). core-elx is a pure consumer. |

**The result is a single ingestion consumer (core-elx) that normalizes in-process (ZEN NIF) and is the sole CNPG writer** — `db-event-writer` and `serviceradar-zen` are both deleted. On top of it, the **two-consumer fan-out** (Marvin's "two consumer types," not a ring buffer): both read the **raw** stream **in parallel** (`limits` retention, independent cursors) — **(a) DB-sync** (core-elx persister) and **(b) real-time analysis** (anomaly path); analysis never waits on the DB. Ring buffer **rejected** (µs-only; a DoS isn't that fast; ~5 s first-response is fine).

**Eliminate the three publish-then-read-back loops** (not just the double-write):
- **OTLP relay loop** — today agent → agent-gateway (gRPC) → **core re-publishes the OTLP chunks to NATS** (`status_handler.ex:281`) → consumed back. **Fix: the agent-gateway publishes relayed OTLP to JetStream first** (`otel.traces.raw` / `otel.metrics.raw` / `otel.logs`) on its *local* NATS endpoint (leaf or hub), and core's `status_handler` republish is deleted. This is cheap because **the agent already chunks OTLP at the edge** (≤900 KiB, 1 record = 1 NATS msg) — the gateway publishes the pre-chunked records, no bespoke chunker needed.
  - *Why not "forward into the `rust/otel` collector" (the earlier idea, now rejected):* an **edge** agent-gateway may have no path to a cloud collector, and a gateway→collector gRPC hop is exactly the kind of non-JetStream middle-hop the edge/leaf model (Decision 16) must avoid. Publishing to the local leaf is the only dependency that always exists. (Gateway-to-gateway routing is *not* needed — the leaf federates.)
  - *The collector is no longer a pipeline stage the relay flows through — it becomes a **peer producer**.* Two independent producers onto `otel.*.raw`: the **collector** and the **agent-gateway** (agent-relayed, pre-chunked). Agent-relayed OTLP **never touches the collector**.
  - *Is the collector even necessary?* It reduces to a **thin OTLP-protocol ingress bridge** (OTLP gRPC/HTTP in → publish `otel.*.raw`). This is **necessary for any SDK-based emitter that speaks OTLP on the wire** — ServiceRadar's own services (`serviceradar-core-elx`, web-ng, the Go services) and external/customer apps via the OTLP gateway endpoint — because none of them can publish to NATS directly. Its "write straight back to NATS" is protocol termination, not a redundant round-trip. The collector would only be removable if ServiceRadar dropped *all* non-agent OTLP ingestion (a product-capability decision, out of scope here). The **only genuinely redundant republish** — `otel.metrics.derived` — is removed by deriving RED inline in core-elx (above). So Phase 0 keeps the collector but **strips it to the bridge role** (no derived republish; not in the agent path).
  - *RED derivation (the collector's only transform) reads off the stream, not the ingress path.* **Recommended: core-elx derives RED inline** — it already consumes `otel.traces.raw` and decodes OTLP protobuf in its `otel_*` processors, so it computes RED and writes `otel_metrics` in the same pass, eliminating the `otel.metrics.derived` round-trip entirely (covers both producers' traces). *Alternative:* keep derivation in the collector as a JetStream consumer (`otel.traces.raw` → `otel.metrics.derived`) — less Rust rework but re-adds a transform hop and a standalone consumer. core-elx remains the single CNPG writer either way.
- **Attributed-flow self-loop** — today core-elx publishes `flow.attributed.<partition>` and its own Flows processor consumes it back (partition routing). Fix: perform attribution correlation **in-process / in-cluster** (libcluster/Horde routing to the partition owner if cross-node is needed) and **write once** — no NATS self-loop.
- **Internal-logs loop** — today core-generated logs (sweep/health/onboarding/jobs/audit) are published → ZEN → `.processed` → db-event-writer → `logs`. Fix: core-elx **persists its own generated logs directly** (ZEN NIF inline if normalization is needed). It may still publish to NATS for other live consumers, but the DB write never depends on a round-trip.

This is a large, necessary refactor — **Phase 0**, bundled per the scoping decision, gating Phases 1–2, reversible per defect (shadow → switch → delete).

**Tradeoff to accept (honest):** consolidating ingestion + normalization + persistence + detection into core-elx couples high-volume telemetry load to the control-plane monolith. The BEAM handles this well (lightweight processes, libcluster/Horde, Broadway backpressure), and we scale by core-elx replica count (Decision 14). If ingestion-isolation/blast-radius later demands it, the **same core-elx codebase can run as a separate "consumer-role" deployment** — a topology choice, not new code or a new language. We are not building new standalone consumers in this change.

### Decision 16 — Forward-compatibility: NATS leaf nodes at the edge

Customers will deploy **NATS leaf nodes** in their own networks. A leaf node is a NATS server inside the customer network that makes one outbound authenticated connection to the cloud hub; locally-published subjects federate up (and survive intermittent links). The `rust/otel` collector **already contemplates this** (`output.rs:14` "site runs a NATS leaf node"; `config.rs:41` "central deployment / NATS leaf at the edge"). agent-gateway is already `partition_id`-scoped and issues edge-agent mTLS certs (`cert_issuer.ex`), so it is half-built to run at the edge.

**Target topology (future deployment, not built in this change):** the ingress publishers run **at the edge, co-located with a leaf** — agents push gRPC to the *local* agent-gateway (LAN, no WAN dependency on the hot path), which publishes `metrics.*`; the edge otel collector / flow-collector / trapd publish their subjects; all to the **local leaf's JetStream**, which sources/mirrors to the cloud hub for store-and-forward durability. Cloud core-elx consumes the hub stream exactly as today. This is the resilient form of ServiceRadar's "intermittently connected sites" thesis.

**Constraints Phase 0 MUST honor so it stays leaf-ready (these are in scope now even though edge deployment is not):**
1. **Endpoint-agnostic publishers** — every ingress publisher (new agent-gateway `metrics.*` publisher, etc.) targets a *configurable* NATS endpoint (local leaf or cloud hub); never hardcode cloud. (The otel collector already does this.)
2. **Federable subjects** — `metrics.>` / `otel.>` / `flows.>` published at a leaf route cleanly to the hub stream; no leaf-local-only subjects, no assumption the publisher and the JetStream stream are co-located.
3. **UUIDv8 stamped at edge ingress** — "first contact" is the edge gateway/collector, giving one clock domain per site; per-series context is single-site so its total order is correct. Cross-site total order is not required (a series lives at one site).
4. **Detection stays cloud-side** in this change (core-elx consumes the federated hub); pushing detection to the edge is a later option, not precluded.

**Key principle — OTLP is terminated locally; NATS crosses the WAN.** Edge-emitted OTEL never travels to a cloud collector as OTLP. It is terminated *at the edge* (turned into NATS messages locally) and the **leaf→hub federation** carries it to the cloud. So the collector is deployable per-site, not a central chokepoint:
- **The local OTLP terminator at every site is the `otel-collector` agent add-on** (`addons/otel-collector`, binary `serviceradar-otel-addon`, agent-sidecar). It accepts OTLP locally (gRPC :4317 / HTTP :4318), **spools to disk durably**, and stamps identity/partition from the agent cert. **All edge OTLP — plugins, add-ons, local apps, and the agent's own telemetry — exports to this local add-on.**
- **The add-on supports TWO output transports (configurable), because the edge does not always have NATS access:**
  - **Gateway-relay (default; requires NO edge NATS):** relays frames over the acked **`otlp-relay:v1`** stream → agent → **agent-gateway, which publishes `otel.*.raw`** to (cloud) NATS. The add-on never needs direct NATS (reconciles "agents are NATS-denied"). This is the only delta vs today (core re-publishes via `status_handler.ex:281`).
  - **Direct-to-NATS (when a NATS leaf is deployed at the edge):** the add-on publishes `otel.*.raw` straight to the **local leaf**, which federates to the cloud hub via JetStream leaf transport with store-and-forward.
  Both transports end with `otel.*.raw` on NATS → core-elx consumes; the choice is per-site config (endpoint-agnostic, Decision 16 constraint #1).
- **Durability:** the on-disk spool covers short disconnects on the gateway-relay path; the leaf + JetStream leaf transport covers multi-hour/day outages (the add-on README's own guidance).
- **Add-on-protocol telemetry** (non-OTLP producers) → returned via `CommandResult` → agent → gateway → NATS.
- The **cloud** `rust/otel` collector only terminates OTLP from cloud-resident emitters + external apps reaching the cloud OTLP gateway over the internet — the same bridge, cloud instance.

What crosses the WAN is always **NATS** (leaf → hub, store-and-forward), never raw OTLP to a distant collector — which is what makes it work on intermittent links.

**The `otel-collector` add-on MUST be a required/default add-on — auto-installed with every agent, not an optional profile assignment.** Without it an agent has no local OTLP terminator, so edge plugin/app/agent OTLP has nowhere to go; making it required guarantees local OTLP termination + durable spooling on every ServiceRadar agent. This **depends on reliable required-add-on distribution** — coordinate the native add-on **blob-eviction fix (fj #3593)**, since a required add-on whose artifact is silently evicted (DB says `verified`, gateway returns 404) would break edge OTLP everywhere. The "required add-on" mechanism (a default/always-installed set folded into every agent's compiled config, vs the current per-profile assignment) is part of this.

Building edge/leaf deployment (leaf JetStream domain, stream source/mirror to hub, edge agent-gateway + edge collector packaging) is **future work** — this decision only ensures Phase 0 does not preclude it.

## Risks / Trade-offs

- **Per-series memory at scale** → bounded `ArrayStorage` windows + a per-series cap + LRU eviction of idle series; document the working-set sizing.
- **Demo metric sparsity** (flows quiet, `telemetry.>` not durable) → don't hard-depend on any one subject; CAGG cold-start makes detection useful even with thin live data; gate per-subject detection on availability.
- **Forecast false confidence** → emit confidence intervals, require a minimum history length, and label projections as estimates; never auto-remediate off a forecast.
- **Overlap with `add-interface-metric-thresholds`** → strictly complementary (dynamic vs static); do not author its `EventRule` requirements here.
- **db-event-writer retirement = data-path cutover** → quick coverage audit then rip-and-replace; low risk because core-elx already double-writes identical PKs, so coverage is largely proven already. No elaborate per-table shadow/rollback dance needed.
- **Total-order context engine is real engineering, not plumbing** → time-ordered (UUIDv8) fold + idempotency must be correct under concurrent producers and restarts; ACID transactions alone do not give total order. Spec it explicitly, test reorder/replay/handoff, and keep the context small so it is cheap to ship/checkpoint.
- **Horde operational complexity** → distributed registry/supervisor adds failure modes (split-brain, handoff races). Mitigate with KV checkpoints (owners rehydrate), per-shard (not unbounded per-series) ownership, and idempotent time-ordered folds so a brief double-ownership window cannot corrupt context.
- **Seasonal profile poisoning / cold start** → use robust statistics (median + MAD) so a past incident in the history window does not inflate the baseline; require a minimum weeks-of-history before trusting a bucket and fall back to the rolling window until warm.
- **Monolith coupling** → folding ingestion/normalization/persistence/detection into core-elx couples telemetry load to the control plane; mitigate with BEAM backpressure + replica scaling, and keep the "consumer-role" separate-deployment escape hatch (Decision 15). Autoscaling is optional (an autoscaler may adjust core-elx replicas on lag); it is not an install dependency.
- **Phase-0 scope size** → it is a large refactor bundled ahead of the feature; sequence behind flags, ship/verify Phase 0 before Phases 1–2, and keep each cutover reversible.
- **bazel drift** → update BUILD files for new Rust deps/files (CI `bazel test` breaks even when `cargo`/`go test` pass).

## Migration Plan

**Phase 0 — rectify ingestion (Decision 15), each step shadow → switch → delete:**
1. Stand up the dedicated `metrics` stream (`limits` retention). Publish sysmon + SNMP interface metrics to it while the legacy paths (gRPC `StreamStatus`, non-durable `telemetry.>`) still run in shadow.
2. Make core-elx EventWriter the **sole** CNPG writer: quick coverage audit of the six tables `db-event-writer` owns (it already double-writes identical PKs, so coverage is largely there), then **rip-and-replace** — delete the Go consumer + config/helm. Fold ZEN into core-elx as a Rustler NIF and **delete the standalone `serviceradar-zen` consumer** (normalization in-process).
3. Switch sysmon/SNMP ingestion to the JetStream consumer; remove the gRPC-direct CNPG writes (`results_router.ex:241` / `sysmon_metrics_ingestor.ex:216`).
4. Route all telemetry through **agent-gateway → JetStream** as the single ingress.

**Phase 1 — anomaly detection (on the clean pipeline):**
5. Stand up the context engine (Horde owners per series, time-ordered fold, KV checkpoint) + the stateless reasoner NIF; validate on `otel.metrics.>` (always-live in demo) before enabling flow + sysmon/SNMP subjects, per-subject enable flag.
6. Add seasonal profiles (batch from CAGGs) and wire the per-sample seasonal consult.

**Phase 2 — capacity forecasting:**
7. Add the per-interface hourly rollup migration; ship the forecasting cron read-only (persist + display) before wiring verdicts into alerting.
8. Retire the bespoke netflow capacity/anomaly placeholders once the new surfaces are live.
9. Guarded auto-remediation is a separate later change; not in this one.

## Open Questions

- **RESOLVED — dedicated metrics stream:** Track 0 publishes to a dedicated `metrics` JetStream stream (`metrics.>`, `limits` retention), not the `events` stream and not the non-durable `telemetry.>`. Both sysmon (`metrics.sysmon.*`) and SNMP interface telemetry (`metrics.snmp.*`) land here. Coordinate agent-side aggregation with `update-sysmon-downsampling` so it lands on the publish path, not the gRPC path.
- Should interface anomaly baselining standardize on flow-derived bps (`flows.raw.*`) or SNMP counters (`metrics.snmp.*`) as the primary series? (Lean: flow-derived primary, SNMP secondary; both now durable.)
- Forecast model selection per resource class — linear default with seasonal (Holt-Winters) opt-in per metric class; exposed as a config knob (Decision 12). Seasonal-baseline anomaly (Tier C, Decisions 11/13) is **in scope** — open sub-question: ship V1 with the median+MAD seasonal-profile method and treat STL/Holt-Winters as the upgrade, or start with STL? (Lean: seasonal profiles first — transparent and CAGG-friendly.)
- Anomaly detector durability: ephemeral vs durable-with-`new`? (Lean: durable with `deliver_policy: new` + `inactive_threshold` for a stable name and clean reconnect, since it never needs backlog replay.)
- **RESOLVED — UUIDv8 stamped at agent-gateway ingress** (Marvin: "always at first contact, the ingress gateway") so there is one clock domain for the fold; carry the original sample time as a field.
- **RESOLVED (low-stakes) — sharding granularity:** per-series vs per-shard owners both work; pick either (Marvin: "doesn't really matter at this stage" below super-scale). Default per-shard (`hash(series) % N`) to bound process count, with series as the routing key so ordering is preserved per series within a shard.
- **db-event-writer retirement** — do a quick coverage audit (core-elx covers the six tables + `serviceradar-zen`'s `.processed` outputs), then **rip-and-replace** — no elaborate per-table shadow/parity cutover required (core-elx already double-writes, so coverage is largely there). Sequencing is not precious.
