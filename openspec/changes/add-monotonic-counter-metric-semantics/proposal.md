# Change: Add monotonic counter metric semantics

## Why
Issue `fj #3789` shows that ServiceRadar currently conflates gauges with cumulative monotonic counters. Sysmon ships network counters as raw since-boot totals without kind, temporality, rate, wrap, or reset anchors. SNMP partially computes deltas, but treats every decrease as a wrap, drops raw counters, and performs counter math in float64. The anomaly engine then evaluates raw cumulative ramps as if they were stationary gauges.

## What Changes
- Extend sysmon and SNMP metric production so counters are emitted as raw cumulative integer values with `kind=sum`, `temporality=cumulative`, `is_monotonic=true`, unit, width, and reset anchors.
- Add boot/reset anchors for host counters, SNMP counters, and OTLP cumulative sums.
- Move reset-vs-wrap handling and rate computation to a consumer-side counter normalizer used by anomaly detection and query/rate views.
- Preserve raw counter values end-to-end so bad intervals can be dropped or recomputed.
- Default counter decreases to reset, not wrap; only known 32-bit counters with unchanged anchors and plausible single-wrap evidence are wrap-adjusted.

## Impact
- Affected specs: `sysmon-library`, `snmp-checker`, `ingestion-routing`, `anomaly-detection`
- Affected code: `go/pkg/sysmon`, `go/pkg/agent/snmp`, gateway metric publishers, metric processors/storage, anomaly `SampleExtractor`, rate/query views
- Depends on: OpenSpec change `update-anomaly-evaluation-cadence`, which defines the canonical `serviceradar.metric.v1` contract fields (`kind`, `temporality`, `is_monotonic`, `points[].start_time_unix_nano`, raw point value)
