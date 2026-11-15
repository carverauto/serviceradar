## Context

The device detail page shows the merged availability badge
(`ServiceRadarWebNG.Devices.MergedAvailability`, decided in core by
`ServiceRadar.Inventory.Availability.Resolver`) and, below it, an Availability
Timeline built by `DeviceLive.AvailabilityData.load_availability/4` from
`ICMPData.load_availability/4`. That loader reads `in:timeseries_metrics` for
`icmp_available`, then `sweep.host.available`, takes the first source per bucket,
and aggregates observers with `max` (no agent selected) or `min` (agent selected).

Observed on the demo deployment (described by class): a camera managed by a video
controller, probed by two agents. Agent P sweeps it from a leased static sweep group
and reaches it. Agent D sweeps it from an unleased target-query group and cannot
reach that network. The badge: available, decided by the managing controller, "up
from 1 of 2 agents". The timeline: 0% in every bucket. Over the same hours agent P
emitted only `sweep.total_hosts`, `sweep.available_hosts` and `sweep.sequence`;
agent D emitted the full `sweep.host.*` set. Both agents run the same release.
`platform.sweep_execution_slots` holds leased slots for P's group and D's other
group, none for D's target-query group; `platform.sweep_host_results` holds P's
available rows for the camera from the leased group and D's unavailable rows from
the unleased group.

## Goals / Non-Goals

Goals:

- Every agent's per-host sweep result produces per-host availability telemetry
  exactly once, through JetStream, whether its sweep is leased or not.
- The timeline shows the history of the same merged value the badge shows.
- Unknown stays unknown: no bucket is painted up or down without a recorded state.

Non-Goals:

- Changing the merged resolver's rules, authority classes or vantage expectations.
- Changing the agent's leased or unleased producers, or the sweep lease contract.
- Backfilling history from before the history record exists.

## Decision 1 (Defect A): core derives leased per-host gauges after commit

**Owner.** `move-agent-telemetry-to-edge-records` decided that a leased execution
emits no metric batch (the lease delivery keeps one production capability, for
`serviceradar.sweep.observation`), and that "if per-host gauges for a leased sweep
are needed later, core derives them from those projected results". Core is the
owner. Adding a metric batch to the agent's leased producer would contradict that
requirement and add a second capability to the lease; deriving in the gateway would
put a payload decoder in the gateway, which never decodes durable payloads.

**Where.** `ServiceRadar.Edge.Projectors.SweepObservation` gains `committed/3`. The
EdgeRecord processor calls it only after the ledger transaction commits, only for a
fresh primary delivery, so gauges are derived only from a batch whose projection
committed: never from a replay, a late-fenced delivery, or a batch the projection
refused (stale assignment, closed slot, plan mismatch). `publish/3` was rejected
because it runs before the transaction, before those authority checks.

**What.** `ServiceRadar.Edge.SweepHostMetrics` builds the gauges from the batch with
the same per-host interpretation `ServiceRadar.Edge.SweepProjection` stores:

| Series | Value | When |
| --- | --- | --- |
| `sweep.host.available` | ICMP target reached, or any tested TCP port open | every host |
| `sweep.host.icmp_available` | ICMP target reached | host carries an ICMP summary |
| `sweep.host.icmp_response_time_ns` | round trip, microseconds x 1000 | round trip present |
| `sweep.host.icmp_packet_loss` | packet loss percent | packet loss present |
| `sweep.host.port.available` | port open | each tested TCP port, host carries a TCP summary |
| `sweep.host.port.response_time_ns` | open port response time | open port with a response time |

Each point is observed at `observed_at_unix_nano + observed_at_delta_nano` and
tagged `target` (the address), `hostname` when present, `execution_id`,
`sweep_group_id`, and `port` / `service` for port series. The batch resource and
ingest identity match the agent's unleased batch after core attests it
(`ServiceRadar.Edge.MetricsBatchProjection`): `metric_type` `sweep`, tag
`metric_family=sweep`, service `network_sweep` / `sweep`, source `sweep-metrics`,
producer kind `sweep`, producer id the record's authenticated agent, agent id the
same. So a leased and an unleased gauge for one agent and target are the same
series family and differ only by their execution and group tags, exactly as two
unleased executions do.

**Transport.** Each message is published to `metrics.sweep.sweep.<name>` with
`ServiceRadar.NATS.DurablePublish`: a PubAck publish, falling back to a durable
retry job only when the publish fails. A leased batch carries up to 10,000 hosts, so
the gauges are split, in host order, into messages of at most 1,000 points (well
under one NATS message). Message `n` of a record has the `Nats-Msg-Id`
`<event_id>:sweep-host-metrics:<n>`, so a retry stores once. EventWriter's metrics
consumer persists them; nothing is written to a database directly.

**No loss window (decided 2026-11-14).** A node that died between the commit and the
publish would have lost that batch's gauges. The product owner ruled that window out,
and ruled out an outbox job per gauge (it writes every gauge of every leased batch to
CNPG). Instead the projection records one pending marker per batch,
`platform.sweep_host_gauge_pending`, in the same ledger transaction, so it commits or
rolls back with the projection (`ServiceRadar.Edge.SweepHostGauges`):

- `committed/3` publishes the gauges, then deletes the marker. A message JetStream
  cannot take is queued by `DurablePublish`, whose retry job then owns it, so the
  marker is deleted once every message is stored or queued. When a message can be
  neither, the marker stays.
- `ServiceRadar.Edge.SweepHostGaugeSweeper`, an Oban cron job every minute (one pass at
  a time), republishes markers older than a 120-second grace period, oldest first, at
  most 50 per pass, and deletes each one it publishes.
- The marker carries the batch itself, protobuf and zlib-compressed, because a
  republish must rebuild the same messages under the same message ids and the same
  points under the same storage keys. Republishing therefore stores each point once:
  JetStream deduplicates a repeat within its 2-minute window, and `timeseries_metrics`,
  keyed by `(timestamp, gateway_id, series_key)` in CNPG (`ON CONFLICT DO NOTHING`) and
  StarRocks (primary key), keeps one row after it. The marker is a fraction of the
  host rows the same transaction writes, and it is deleted after its publish.

`DurablePublish` stored the body as a JSON string in its retry job, which only
works for UTF-8 bodies. A body that is not valid UTF-8 (a protobuf) is now stored
base64-encoded under `body_base64`; the worker accepts either key, so queued jobs
keep working.

## Decision 2 (Defect B): record merged transitions as append-only history

**Status: approved 2026-11-14 with storage option 1.** Implemented in a follow-up
change after the Defect A fix.

No decided-state history exists. `availability_changed_at` holds only the last
change; `availability_decided_by` carries no previous decision across writes;
`device.available` / `device.unavailable` events are opt-in alert events (gated by
`availability_settings.transition_events` and each group's
`emit_availability_events`) and are not emitted for transitions to `unknown`;
`signals.state.ocsf_devices` is disabled by default, fire-and-forget, and only the
correlation engine consumes it.

**The record.** One `device_availability_transition` per merged state change:

| Field | Meaning |
| --- | --- |
| `device_uid` | the device |
| `from_state`, `to_state` | `available`, `unavailable` or `unknown` |
| `from_since` | when `from_state` began: the row's `availability_changed_at` before this write, null if the device had no decision |
| `changed_at` | the decision's `changed_at` |
| `authority_class`, `source_kind`, `reporter_agent_id`, `rule` | the deciding evidence (`decided_by` without `previous`) |
| `conflict` | the conflict flag at this decision |

Because each record names the interval it closes, history is reconstructed from the
records alone, with no lookback past the window and no need for a complete log: a
lost record leaves a gap that renders unknown.

**Emitter.** `Resolution.write/2` already builds a transition per state change and
enqueues the `Transitions` outbox job in the resolving transaction. The job also
publishes one history record per transition with `DurablePublish`, ungated (history
is not alerting), with a deterministic message id over `(device_uid, changed_at,
to_state)`. Transitions written during the upgrade reconciliation (`reconciling?`),
which today publish nothing per device to avoid an alert storm, are recorded as
history too; their events stay suppressed.

**Storage (option 1, chosen).** A dedicated dataset: subject
`availability.transitions.device`, an EventWriter processor, a CNPG hypertable
`platform.device_availability_transitions` and a StarRocks table of the same shape,
written to StarRocks when it is enabled and to CNPG otherwise, never both (AGENTS.md
JetStream-first rule; CNPG remains a complete backend without StarRocks). SRQL gains
`in:device_availability_history` with `uid:` and `time:` filters. Write volume is
O(state changes), which the resolver already bounds (write-on-change).

Implementation notes: the subject shares the existing `events` stream (EventWriter merges
its subject into that stream) under its own consumer, `AVAILABILITY_TRANSITIONS`, so no
new stream, sizing profile or budget entry is needed; core's NATS user gains publish on
`availability.transitions.device`. CNPG retention is the telemetry retention path
(`DataRetentionWorker`, key `:availability_history_retention_days`, 14-day code default,
capped by the CNPG telemetry ceiling); the StarRocks table keeps 365 daily partitions, the
warehouse's one-year default. The transitions outbox job publishes the history first and
retries before announcing anything if it cannot.

**Storage (option 2, rejected).** An OCSF event `device.availability_changed` through
`InternalLogPublisher`, stored with the other internal events and read with
`in:events`. It needs no new table or SRQL entity, but puts every transition in the
Events page and the log-promotion path, ties history retention to event retention,
and leaves a timeline that depends on an event type staying unpromoted and unmatched
by alert rules.

## Decision 3 (Defect B): the timeline renders the merged history

With no agent selected the timeline reads, over the 24-hour window:

1. the device row's `availability_state` and `availability_changed_at`: the current
   state holds over `[availability_changed_at, now]`; and
2. the history records with `changed_at` in the window: each contributes
   `[from_since, changed_at)` in `from_state`.

Time covered by neither is unknown. A device with no decision (`unknown`, or no
`availability_changed_at`) is unknown throughout. A bucket is `offline` when the
device was unavailable for any part of it, `online` when every known part of it was
available, and `unknown` when no part of it is known. An offline bucket's tooltip shows
how many minutes of it the device was down. Uptime is time-weighted: available seconds
over known seconds. A bucket's tooltip shows its state and, when offline, the minutes down.

The merged-history timeline renders only where the resolver is authoritative.
`simplify-merged-availability-rollout` removed the `legacy`/`shadow`/`authoritative`
modes: core always runs merged availability, after a one-time convergence on upgrade
recorded in `availability_settings.converged_at`. "Authoritative" is therefore
"converged": until `converged_at` is set the merged value is not yet the one in force,
so the timeline keeps the probe timeline and labels it as probe history.

With an agent selected, the timeline shows that agent's raw probe history from
`sweep.host.available` / `icmp_available` as today, titled as that agent's probe
history, so per-vantage results ("reachable from A, blocked from B") stay visible
and are never presented as the device's availability.

Loads run in the connected LiveView only (no database or SRQL reads in the
disconnected mount).

## Risks / Trade-offs

- **History starts empty.** After rollout every device shows only the time since
  its last change until history accumulates. That is honest and short-lived for a
  24-hour window.
- **Reconciliation burst.** The cutover reconciliation can record one transition per
  device in one pass. It is bounded by the device count and happens once.
- **Marker backlog.** If JetStream is down for long enough that `DurablePublish` cannot
  queue either, markers accumulate, one per projected leased batch, until the sweeper
  drains them at up to 50 per minute.

## Decisions Taken (product owner, 2026-11-14)

1. Storage: option 1, the dedicated dataset (StarRocks only when it is enabled, CNPG
   otherwise).
2. Bucket rule: any unavailable time marks the 30-minute bucket offline; its tooltip
   shows the minutes down; uptime stays time-weighted.
3. Modes: the merged-history timeline renders only where the resolver is authoritative;
   `legacy` and `shadow` keep the probe timeline, labelled as probe history. With the
   modes since removed, this is "after the upgrade convergence" (Decision 3).
4. Leased gauges: no loss window; a per-batch pending marker and a bounded sweeper
   (Decision 1).
