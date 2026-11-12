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

## D3 — No server-side deletion in this change

Orphan durables (`serviceradar-event-writer-{sflow,netflow}-raw` on
`events`, `serviceradar-event-writer-attributed-flow` on `attributed_flow`)
and the `attributed_flow` stream are left for the existing ops step
(`scale-netflow-ingest-isolation` 6.3). Rationale: deleting a durable
discards its pending state, and "verified-empty" is an ops observation on
the live server, not something this change can prove from the repo. Stopping
the declarations is sufficient for the goal: no warning is logged because
no such consumer is attempted.

## D4 — Docs follow the code

`docs/docs/netflow.md` documents the dual-consume drain and the
`EVENT_WRITER_FLOW_DRAIN_EVENTS=false` step. Both go away with the
generator; the doc keeps the cutover history note so a future reader knows
why the machinery is gone.
