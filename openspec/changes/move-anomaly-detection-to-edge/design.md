## Context
The `fix-eventwriter-backpressure-hotpath` work bounded the central pull/ack
path and capped the per-process sysmon bloat (top-25), but it explicitly left
the scaling question to a follow-up. Grounded review of the anomaly engine shows
detection is fully per-series and node-local: state is keyed by an opaque
`series_key`, the math is an O(1) Welford sliding-window z-score
(`|(value-mean)/stddev| >= n_sigma`), and there is no code path that joins two
series, hosts, or agents. Per-process samples are already dropped from the
anomaly path. The only "central" properties are plumbing — durable JetStream
consumers, JetStream-KV checkpoints, and Horde ownership — none of which are
algorithmic. At the edge, ownership and failover collapse to "a local process,"
which also removes the central NATS-KV lease's dual-writer handoff window.

The blocker is not the math; it is two missing primitives: the agent cannot feed
its local metric stream into an add-on, and add-on manifests carry no resource
budget.

## Goals
- Run per-series anomaly detection on the agent so verdicts (and optional
  rollups) are emitted instead of every raw point being shipped and re-analyzed
  centrally.
- Keep verdict math stable by reusing the detector implementation extracted from
  the former central path.
- Make edge add-on resource usage hard-bounded so edge nodes are not impacted.
- Make edge coverage explicit, observable, and reversible through add-on
  assignment state.

## Non-Goals
- Move *capacity forecasting* to the edge. Capacity is per-resource but reads
  fleet CAGGs centrally; it stays central and reads the rollups the edge emits.
  (Tracked separately.)
- Move *cross-entity causal analysis* to the edge. The DeepCausality graph over
  the CONNECTS_TO fabric is inherently cross-host and stays central in
  `rust/causal-engine`.
- Run per-series anomaly on OTel / non-agent metric sources. OTel application
  metrics are explicitly out of scope for statistical anomaly detection (they
  keep storage, dashboards, threshold alerts, and the causal engine). Because
  sysmon, SNMP, and ICMP are all agent-collected, dropping OTel makes *every*
  anomaly input agent-sourced and therefore fully edge-resident — which is what
  allows the central pipeline to be retired entirely (see Decisions).
- Change the verdict/signal schema or the alerting path.

## Decisions
- **Split anomaly by timescale; retire the central raw-stream pipeline.** The
  edge does fast per-series **spike** detection (rolling z-score); central does
  **seasonal/contextual** detection over CAGGs (the "busy Tuesday" question —
  specified in `add-seasonal-anomaly-detection`, an aggregate-based Oban worker,
  not a raw-stream consumer). What is **removed** is the central raw-stream
  per-sample pipeline — the `causal_reasoner_nif` and the `ANALYSIS_METRICS_*`
  durables, the sharded/native context engine, Horde ownership, and the KV
  checkpoints. The user-approved retirement was pulled into this change, so the
  old central raw-stream path is not retained as a rollout fallback.
  `serviceradar-anomaly-core` survives as the edge detector and as the basis for
  a small batch backfill/backtesting CLI.
- **One detector crate.** The edge add-on calls the shared
  `serviceradar-anomaly-core` crate extracted from the former central NIF path. A
  parity test guards the extracted math.
- **New agent→add-on metric-feed RPC**, not a side channel. The
  `AddonService` contract gains a streaming agent→add-on metric feed with the
  same flow-control discipline as the gateway path; an add-on subscribes only to
  the metric sources it declares.
- **Hard resource limits on native add-ons.** Manifest gains CPU/memory/cgroup
  fields; the supervisor (go-plugin sidecar) and systemd generator enforce them
  (`MemoryMax`, `CPUQuota`, slice). The add-on self-sheds under pressure and
  reports the shed rather than impacting the host.
- **Edge owns its state.** Per-series sliding windows live in the add-on, bounded
  by a capped series count and a fixed window size. A small local checkpoint
  enables fast re-warm; no Horde/KV at the edge.
- **Explicit edge coverage.** Add-on assignment/status is the coverage boundary.
  Edge verdicts carry `verdict_source=edge-spike`, and shed pressure is emitted
  as a non-anomaly operational event. Disabling the add-on stops edge spike
  verdicts for that cohort; raw metrics still flow for storage, graphs, capacity
  forecasting, and any aggregate-based future detectors.

## Edge resource budget
- Per-series Welford is O(1) per sample; the cost driver is `series_count x
  window_size x bytes_per_sample` in memory, not CPU.
- Process/PID series (the 94% bloat) are already excluded, so the per-host series
  count is the bounded sysmon/SNMP/ICMP set, not the process explosion.
- The add-on caps series count and window size, and self-sheds under the manifest
  CPU/memory limit. Benchmark task 6.2 must prove a conservative steady-state RSS
  and CPU at a realistic post-cap per-host series count before fleet rollout.

## Risks / Trade-offs
- **Detector divergence** if edge and central drift. Mitigation: one shared
  detector implementation + parity test in CI.
- **Cold-start false positives** after restart before baselines re-warm.
  Mitigation: local checkpoint + a warm-up suppression window.
- **Heterogeneous fleet** — older agents without the add-on. Mitigation: rollout
  is per cohort and observable through add-on status; old central raw-stream
  scoring is available only by rolling back to a release that still carries it.
- **Edge nodes are resource-constrained.** Mitigation: hard manifest limits +
  self-shed + a pre-rollout resource benchmark gate.
- **Loss of central raw stream for re-analysis** of edge-covered series. Raw
  points still flow to storage for graphing/backfill (see
  `add-delta-metrics-lakehouse`); model backtesting reads the stored raw tier,
  not a re-run of the live edge stream.
