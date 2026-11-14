# Change: The device Availability Timeline shows merged availability history, and leased sweeps produce per-host availability telemetry

## Why

The device page shows two availability answers that disagree. The badge reads the
merged availability core decides (`add-merged-device-availability`): one value per
device, chosen across every source by authority class, with vantages that cannot
reach the device excluded or outranked. The Availability Timeline below it ignores
that value. It rebuilds availability from raw probe samples with its own precedence
(a dedicated ICMP check over a sweep, `max` across observers, `min` for a selected
observer). Seen on a demo deployment: a camera that its managing controller and one
agent report up showed the badge "Online" and a timeline that was offline in every
bucket of the last 24 hours.

Two defects produce that picture.

**Defect A (data gap).** Per-host sweep telemetry (`sweep.host.available`,
`sweep.host.icmp_*`, `sweep.host.port.*`) exists only for unleased sweeps. The agent
builds it from the `MetricBatch` it appends to each unleased results chunk. A leased
static sweep emits `SweepObservationBatchV1` on `serviceradar.sweep.observation` and,
by design (`move-agent-telemetry-to-edge-records`, Decision 3 and requirement "Core-
scheduled sweeps keep their sweep leases"), no metric batch. That design deferred
the per-host gauges of a leased sweep to core, "derived from the projected results",
and left the derivation as a follow-up that was never written. An agent whose only
sweep group is leased therefore produces per-host results (the per-agent
availability table shows them) and no per-host availability telemetry at all, while
an agent sweeping the same host from an unleased group does. The timeline sees only
the second agent. When that agent cannot reach the device, every bucket is offline.

**Defect B (design).** Even with complete telemetry, the timeline computes its own
availability from probes, so it disagrees with the badge whenever a higher authority
class (a managing controller, a plugin) decides, or a vantage that cannot reach the
device is excluded by a vantage expectation or outranked. The product decision of
2026-10-19 is one merged availability value in core. The timeline must show the
history of that value. No such history exists today: core keeps only the current
decision (`availability_state`, `availability_changed_at`, `availability_decided_by`),
and its transitions leave core only as opt-in `device.available` /
`device.unavailable` alert events and the `signals.state` feed, which is off by
default, fire-and-forget, and not stored.

## What Changes

- **Defect A.** Core derives the per-host sweep gauges of a leased sweep execution
  from each projected `SweepObservationBatchV1` and publishes them on
  `metrics.sweep.>` through JetStream, after the ledger transaction that projected
  the batch commits. EventWriter stores them like the unleased gauges (StarRocks
  when enabled, CNPG otherwise). The series names, units, tags and attestation match
  the agent's unleased batch, so both kinds of sweep feed one per-agent history. The
  agent is unchanged: a leased execution still emits no metric batch, and the
  unleased path stays the only producer for unleased sweeps.
- **Defect B (needs approval before implementation).** Core records every merged
  availability transition as an append-only history record, published through
  JetStream from the resolver's existing transition outbox and stored by EventWriter
  in StarRocks when enabled and CNPG otherwise. Each record is self-describing: the
  state the device left, when that state began, the state it entered, and when.
  The device Availability Timeline renders that history plus the current decision
  instead of probe samples. Time no record covers is unknown, never synthesized.
  With an agent selected, the timeline keeps showing that agent's raw probe
  history, labelled as such.
- The timeline's synthesized fallback (painting the whole window with the device's
  current state when no probe sample exists) is removed: only the time since
  `availability_changed_at` is known from the current decision.

## Impact

- Affected specs: `edge-producer-data-plane` (ADDED: core derives leased per-host
  sweep gauges), `device-inventory` (ADDED: merged availability history),
  `build-web-ui` (ADDED: the timeline shows merged availability history).
- Affected code (A): `elixir/serviceradar_core/lib/serviceradar/edge/projectors/sweep_observation.ex`,
  a new `ServiceRadar.Edge.SweepHostMetrics`, `ServiceRadar.NATS.DurablePublish`
  (binary bodies in its retry job).
- Affected code (B, after approval): `inventory/availability/resolution.ex` and
  `transitions.ex`, an EventWriter processor, CNPG and StarRocks migrations, an SRQL
  entity, `web-ng` `device_live/availability_data.ex` and the timeline component.
- Relationship to pending changes: completes the follow-up named in
  `move-agent-telemetry-to-edge-records` Decision 3; narrows the
  `add-merged-device-availability` non-goal "Time-series availability history.
  Transitions are events." (transitions stay events; this adds their stored record).
