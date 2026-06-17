# Change: Move per-series anomaly detection to the edge

## Why
The metrics hot path does not scale by making the central writer faster. Pull
consumers, COPY, parallel writers, and even a faster store only speed central
*persistence*; none of them reduce the volume of raw points the platform ships
and re-analyzes centrally. The dominant central cost is persisting and
re-analyzing every raw point in core-elx, then fanning the same stream out to
the anomaly consumers.

Anomaly detection is already shaped for the edge. It is a per-series, O(1)
Welford sliding-window z-score keyed by an opaque `series_key`, with **zero
cross-host correlation** anywhere in the code
(`anomaly_detection/sample_extractor.ex`, `native_context_engine`,
`sharded_context_engine`). It already excludes per-process samples
(`sample_extractor.ex` returns `{:drop, :process_metric}`). Because the math is
per-series and node-local, the engine can run where the data is produced —
co-located with `serviceradar-agent` — so the agent emits **verdicts and
rollups instead of every raw point**. That removes the central anomaly fan-out
for edge-covered series and is the single highest-leverage move for both the
50k-agent target and the per-tenant SaaS model (each tenant's dedicated CNPG +
NATS instance then absorbs far less raw volume).

Two primitives are missing today:
- The agent cannot feed its local metric stream into an add-on. The
  `AddonService` gRPC contract is upstream-only: `Info/Configure/Health/
  RunCommand` (agent→add-on control) and `StreamTelemetry/StreamArtifacts/
  RelayOtlp` (add-on→agent). There is no RPC for the agent to hand its locally
  collected sysmon/SNMP/ICMP samples to an add-on for analysis.
- Native add-on manifests have **no CPU/memory budget**
  (`addons/native-addon-manifest.schema.json` has no resource fields, and the
  systemd unit generator sets no limits). Running compute at the edge without a
  hard resource bound is unacceptable given edge nodes must not be impacted.

## What Changes
- Add an **agent→add-on metric-feed RPC** to `AddonService` so the agent can
  stream its locally collected `MetricBatch` samples (sysmon CPU/mem/disk, SNMP,
  ICMP, timeseries) into a co-located add-on before they leave the host.
- Add a **native Rust anomaly add-on** that consumes the local metric feed and
  runs the existing per-series Welford z-score detector. Reuse the existing
  anomaly math (the Rustler NIF / `causal-engine` detector code) rather than
  reimplementing it, so edge and central verdicts stay identical.
- Add **CPU/memory/cgroup resource limits** to the native add-on manifest schema
  and to the add-on supervisor/systemd generator, with conservative defaults and
  a bounded per-host series count.
- The edge add-on **emits anomaly verdicts** (and optional pre-rollups) upstream
  via `StreamTelemetry` → gateway → the existing signal path; central no longer
  needs to run the four `ANALYSIS_METRICS_*` durables for series covered by an
  edge add-on.
- Keep a **central fallback**: series from sources without an edge anomaly
  add-on (or during rollout) are still analyzed centrally exactly as today.
  Edge vs central coverage is explicit and observable.
- **Own per-series state locally** at the edge — no Horde ownership and no
  NATS-KV lease (which has a dual-writer handoff window centrally). On agent
  restart, baselines re-warm from the live stream or reseed from a small local
  checkpoint.

## Impact
- Affected specs: edge-architecture, observability-signals
- Affected code: `proto/agent/addon/v1/addon.proto` (new metric-feed RPC),
  `go/pkg/agent` (local metric tap + add-on feed), `go/pkg/addon`,
  `rust/addon-sdk` + new `rust/anomaly-addon` (reusing the anomaly detector
  math), `addons/native-addon-manifest.schema.json` and the add-on
  supervisor/systemd generator (resource limits),
  `elixir/serviceradar_core/lib/serviceradar/observability/anomaly_detection/*`
  (central becomes a verdict consumer for edge-covered series; coverage
  telemetry)
- Related changes: `add-native-addon-edge-ops` (targeting/reconciliation UI for
  add-ons), `add-cgroup-v2-tenant-metrics` (cgroup signal precedent),
  `add-delta-metrics-lakehouse` (edge rollups feed the tiered store)
