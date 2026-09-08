## Context
Counters need a different processing model than gauges. A gauge value is meaningful by itself. A cumulative monotonic counter is only meaningful after comparing two readings from the same series and reset lineage.

Today sysmon and SNMP do not preserve enough information to make that comparison correctly. Sysmon network counters are raw cumulative values with no semantics. SNMP computes edge rates, but a device reboot or counter discontinuity can be mistaken for a wrap and manufacture a huge false spike. OTLP preserves `temporality` and `is_monotonic`, but drops the reset anchor at rest and the anomaly extractor discards those fields.

## Goals / Non-Goals
- Goals:
  - Emit raw cumulative counters with integer precision and reset anchors.
  - Correctly distinguish normal growth, reset/reboot, and the rare valid 32-bit wrap.
  - Feed anomaly detection rates/deltas for counters and raw values for gauges.
  - Preserve enough raw state for query-time rates and back-correction.
- Non-Goals:
  - Replacing the canonical metric contract from `fj #3788`.
  - Treating cumulative counter rates as OCSF events.
  - Billing enforcement or quota enforcement.

## Decisions

### Decision 1: Producer declares semantics, consumer derives meaning
Producers SHALL stamp what a metric is: kind, temporality, monotonicity, unit, raw value, width where known, and reset anchor. Consumers SHALL decide what that means for rates, deltas, resets, and wraps.

### Decision 2: Counter decreases are reset by default
For a cumulative monotonic series, a value decrease is a reset unless wrap is positively corroborated. Wrap is allowed only when counter width is known to be 32-bit, reset anchors are unchanged, elapsed time is valid, and a single wrap is plausible given link speed or configured max rate. Counter64 and host/cgroup 64-bit counters SHALL NOT be wrap-added under normal operation.

### Decision 3: Rate computation uses raw integer values
Counter math SHALL be performed in integer or numeric space. Conversion to float happens only for the final rate value consumed by charts, alerts, or anomaly detection.

### Decision 4: Reset anchors are first-class
The best available reset anchor is carried per point: OTLP `start_time_unix_nano`, sysmon host boot time or boot id, SNMP `sysUpTime`/`ifCounterDiscontinuityTime`, and cgroup lineage anchors for cgroup counters. A changed anchor invalidates the prior interval.

## Risks / Trade-offs
- Risk: some existing dashboards may expect SNMP edge rates.
  - Mitigation: preserve compatibility with a rate view while storing raw counters.
- Risk: raw Counter64 values can exceed signed `BIGINT`.
  - Mitigation: choose `NUMERIC` or a documented chunking strategy for unsigned 64-bit counters before migration.
- Risk: wrap handling can still be ambiguous on high-speed 32-bit counters.
  - Mitigation: prefer 64-bit `ifHC*` counters and drop unresolvable intervals instead of inventing data.

## Migration Plan
1. Add contract/storage fields and preserve raw values while keeping current rate outputs available.
2. Stamp sysmon network counters and OTLP cumulative metrics with reset anchors.
3. Update SNMP to emit raw counters and wire PDU width/anchors through.
4. Add counter normalizer tests for normal growth, reset, reboot, 32-bit wrap, 64-bit decrease, max-gap, and clock anomalies.
5. Switch anomaly extraction to consume rates for counters.
