# Design: remove flow events-drain consumers

## D1 — Delete the generator, not the mechanism

`maybe_append_events_drain_streams/1` is removed from the `load_flow/0`
pipeline along with the `EVENT_WRITER_FLOW_DRAIN_EVENTS` environment read.
`extra_flow_subjects/0` keeps feeding only the live extension entries built
by `extra_live_flow_streams/1`; its "live + drain" comment is corrected to
live-only.

Kept deliberately:

- `flow_subject_stream_name/1`, `exact_raw_flow_subject?/1`, and
  `nats_filter_overlaps_flow_namespace?/1`: still guard the live extension
  subjects.
- The `best_effort` flag and its skip-vs-error branches in `Producer` and
  `ConsumerReconciler`: the generic backlog-reader contract. No stream sets
  it after this change, but the next cutover-style reader reuses it instead
  of inventing a second one.

Guarantee preserved: live raw-flow delivery is byte-identical before and
after. The generator only ever appended entries; `load_flow_streams/0`
defaults, tuning application, size application, and the canonical-collision
assert are untouched.

## D2 — ATTRIBUTED_FLOW goes away entirely; it is not repointed

Two options existed: repoint `stream_name` to `"attributed_flow"`, or
delete the registration. Repointing keeps a consumer with no publisher and
contradicts `restore-anomaly-alerting-and-surfacing` design line 70
("MUST remain unprovisioned"). Deletion matches the evidence (no publisher
in-repo, no traffic on demo, attribution now stamps `event_type` on the
CNPG flow row and correlates in the warehouse) and completes that change's
open task 8.3a, including its guard: default and release configuration MUST
NOT provision an attributed-flow subject, stream, or durable.

The release `streams:` list in `serviceradar_core_elx/config/runtime.exs`
loses the entry. `default_streams/0` and the non-elx runtime never had it;
a guard test pins all three sources.

## D3 — Retire orphan durables via `ConsumerReconciler`

Flows and process attribution are stored exclusively in StarRocks via the
dedicated `flows` stream (`SFLOW_RAW`, `NETFLOW_RAW`, and any concrete
`extra_flow_subjects/0` entries) and `events.flow.attribution`. The former
`events`-stream residual-drain durables (`<consumer>-sflow-raw`,
`<consumer>-netflow-raw`, and any `<consumer>-flow-*` extension drain on
`events`) and the former `<consumer>-attributed-flow` durable (on `events` and
`attributed_flow`) have no remaining publisher or consumer. `Config.load/0`
includes them in `retired_consumers` (scoped strictly to `events` and
`attributed_flow`, never `flows`), so `ConsumerReconciler` deletes any
pre-existing orphan durables once every live durable is up. The
`attributed_flow` stream itself remains an operator release step if present.

## D4 — Docs follow the code

`docs/docs/netflow.md` documents the dual-consume drain and the
`EVENT_WRITER_FLOW_DRAIN_EVENTS=false` step. Both go away with the
generator; the doc keeps the cutover history note so a future reader knows
why the machinery is gone.
