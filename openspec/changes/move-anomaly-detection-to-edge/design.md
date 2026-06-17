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
- Keep edge and central verdicts identical by reusing one detector
  implementation.
- Make edge add-on resource usage hard-bounded so edge nodes are not impacted.
- Make edge-vs-central coverage explicit, observable, and reversible.

## Non-Goals
- Move *capacity forecasting* to the edge. Capacity is per-resource but reads
  fleet CAGGs centrally; it stays central and reads the rollups the edge emits.
  (Tracked separately.)
- Move *cross-entity causal analysis* to the edge. The DeepCausality graph over
  the CONNECTS_TO fabric is inherently cross-host and stays central in
  `rust/causal-engine`.
- Remove central anomaly analysis. Central remains the fallback for uncovered
  sources and during rollout.
- Change the verdict/signal schema or the alerting path.

## Decisions
- **Reuse one detector.** The edge add-on calls the same per-series Welford
  detector code used centrally (the Rustler NIF / `causal-engine` detector),
  compiled into the add-on. A parity test gates byte-identical verdicts.
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
- **Explicit coverage + fallback.** Central skips edge-covered series and keeps
  analyzing everything else. A verdict-source label (edge|central) and per-source
  coverage counters make the boundary observable. Disabling the add-on returns
  series to central analysis with no gap.

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
- **Heterogeneous fleet** — older agents without the add-on. Mitigation: central
  fallback is permanent for uncovered series; rollout is per cohort.
- **Edge nodes are resource-constrained.** Mitigation: hard manifest limits +
  self-shed + a pre-rollout resource benchmark gate.
- **Loss of central raw stream for re-analysis** of edge-covered series. Raw
  points still flow to storage for graphing/backfill (see
  `add-delta-metrics-lakehouse`); model backtesting reads the stored raw tier,
  not a re-run of the live edge stream.
