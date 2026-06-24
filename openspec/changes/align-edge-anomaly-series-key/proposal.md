# Align the edge anomaly `series_key` to the central metric `series_key`

## Why

Every disposition feature we have built — the UASB peak-disposition engine
(`add-anomaly-finding-disposition`), the seasonal disposition, and the stale-alert
auto-resolve — joins an **edge anomaly** to its **central metric** on `series_key`.
That join is the load-bearing precondition, and today it is **asserted, not proven**
(the `anomaly-addon` comment literally calls the edge key "provisional"). On demo it
is **broken**, so none of the disposition machinery can actually correlate a verdict
to the series it judges.

Demo evidence (`platform.ocsf_events` anomalies vs `platform.timeseries_metrics`):

- The **metric** for an SNMP series keys on the canonical **target** device:
  `agent_id = agent-dusk01`, `device_id = sr:887a855a-…` (the polled SNMP device),
  `series_key = 6a35…` (a `TimeseriesSeriesKey.build/1` hex hash).
- The **anomaly** for the same series attributes to the **polling agent**:
  `device_uid = agent-dusk01`, `series_key = v2|partition=…|identity=…|…` (the edge's
  structured producer key). The central re-key **fails** to resolve `agent-dusk01`
  to any canonical device (`finding_device_uid` is empty) — there is no canonical
  device named `agent-dusk01`; it is the agent.

So the same physical series carries **two different identities** (agent vs target)
encoded **two different ways** (`v2|…` vs the `TimeseriesSeriesKey` hash). There is no
key function that joins them, and central cannot reconcile an agent id to a device.

Root cause is at the edge: `anomaly_device_uid` (`anomaly-addon/src/addon.rs`)
resolves identity `device_id → snmp_target → host_id → agent_id → host_ip`, and for
SNMP series the edge has no canonical `device_id` and no populated `target_device_ip`,
so it lands on `agent_id` — directly contradicting the function's own intent
("remote SNMP polls use the polled target, not the polling agent host"). The metric
pipeline resolves the same series to the canonical `sr:` target **centrally**.

## What changes

Make the anomaly's `series_key` provably equal to the metric's `series_key` for the
same physical series, by (1) carrying the **target identity** the edge already knows
through to central, and (2) keying **both** metrics and anomalies through the **one**
`TimeseriesSeriesKey` composite over the canonical-resolved fields. The composite is
exactly the right model — `agent_id` (attested upstream) anchors agent-reported
`device` / `target` / `interface` / `metric` — so the agent legitimately produces the
SNMP target/interface identity (it is the only source) while a misbehaving agent can
only ever collide inside its **own** `agent_id` namespace. The authoritative key stays
central; the edge contributes typed fields, never an opaque trusted key.

The acceptance gate is a test that asserts `anomaly.series_key == metric.series_key`
for a known SNMP series — turning the precondition from a comment into a proof.

This is the foundational identity-alignment work the disposition stack rests on. It
also closes the stale-alert auto-resolve gap (`#4288`) for free: once the keys align,
a series's liveness is queryable, so an orphaned alert can be safely resolved.

## Impact

- Affected specs: `observability-signals` (canonical series-key alignment requirement).
- Affected code: `rust/anomaly-addon` (carry target identity / attribution priority),
  `elixir/serviceradar_core` (`causal_signals.ex` anomaly ingest → `TimeseriesSeriesKey`
  canonicalization), and the metric/anomaly key parity test.
- No data migration; new anomalies carry the aligned key. Historical anomalies keep
  their provisional key (the join is forward-looking, like the metric retention window).
- Security posture unchanged and made explicit: `agent_id` is the attested anchor; the
  agent-reported target/interface are scoped under it (the behavioral-identity rule).
