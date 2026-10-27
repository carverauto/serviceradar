# Bounded result ingestion

Core uses independent result lanes with one active job per ordering key. Mapper
interfaces and topology share an agent key; sweeps use agent plus sweep group.
Malformed or older sweep metadata falls back to the conservative agent key.
Generic status snapshots keep per-agent order. The retained plugin lane is the
exception: each job is its own key, fixed in the lane and not selectable by
callers, so its two workers can run two chunks from the same agent at once.
Per-agent item and byte caps still apply, and the plugin lane has two database
permits. Type ingestion and irreversible transitions are never coalesced. Only
completed service-state projections with all five identity fields may replace
an older pending projection.

## Acknowledgements and version pairing

The agent RPC budget remains 30 seconds. The gateway introduced by #5308 spends
at most 20 seconds forwarding acknowledged work. This implementation reserves
15 seconds in core: two for admission/queueing, ten for execution, and three for
cancellation/reply. Core returns an acknowledged success only after the owning
lane confirms its existing durable completion condition. A committed plugin
handler failure marker is terminal; a persistence failure is not accepted.
Timeout or overload retains the agent's pending payload for idempotent replay.

### Retained plugin results that keep exceeding the budget

A retained plugin result whose worker is killed at the execution budget would
otherwise be redelivered forever and hold back the agent's later results. The
retained plugin lane coordinator counts each execution timeout in
`platform.plugin_result_ingestion_attempts`, keyed by agent, logical service
identity and a digest of the raw retained message. The coordinator writes the
row itself, in one statement before it replies, because the killed worker's
transaction rolls back. After three consecutive timeouts (configurable with the
`:plugin_result_quarantine_max_timeouts` application setting) the row becomes
`quarantined`; the next redelivery is acknowledged without running handlers,
so the agent drops it. That acknowledgement leaves the quarantined row, so it
can be listed and retried. A success, or a committed handler-domain failure,
deletes the row.

Admission timeouts do not count. They mean the lane could not start the result,
which says the lane is congested, not that this result is too expensive.

An empty table means no attempt history or quarantine is currently stored; it
does not prove that agents have no pending results, because expired rows are
pruned. To monitor pruning and distinguish it from store failures, read the
`retained_plugin_result` lane counters `result_ingestion_events_attempt_recorded`,
`_quarantined`, `_quarantine_acknowledged`, `_attempt_pruned` and
`_attempt_store_failed`. Lookup, clear, timeout-recording, and prune store
failures increment `_attempt_store_failed`, emit
`[:serviceradar, :plugin_result_quarantine, :store_failed]` with caller,
operation, and reason metadata, and log one warning naming the caller. The lane
fails open: it ingests or retries the result as if nothing had been counted.
Pruning returns an error for the maintenance job to retry. Query telemetry
includes `caller` and `timeout_ms`: lookup, clear, and timeout-recording use
2,000 ms, while pruning retains its 30,000 ms budget.
`ServiceRadar.Observability.PluginResultQuarantine` lists quarantined results and
retries one from its stored status.

`ServiceRadar.Observability.PluginResultAttemptPruneWorker` runs daily on the
`:maintenance` queue (`SERVICERADAR_PLUGIN_RESULT_ATTEMPT_PRUNE_CRON`, default
`33 3 * * *`) and deletes expired rows from
`platform.plugin_result_ingestion_attempts` in primary-key batches through
`PluginResultQuarantine.prune/1`:

- Active, non-quarantined rows (`state = 'active'`) whose `last_attempt_at` is
  older than `:plugin_result_attempt_active_retention_days` (default 7 days;
  `SERVICERADAR_PLUGIN_RESULT_ATTEMPT_ACTIVE_RETENTION_DAYS`) are deleted,
  cleaning up attempt rows left behind by retired agents or dropped results.
- Quarantined rows (`state = 'quarantined'`) whose `quarantined_at` (falling
  back to `last_attempt_at`) is older than
  `:plugin_result_quarantine_retention_days` (default 30 days;
  `SERVICERADAR_PLUGIN_RESULT_QUARANTINE_RETENTION_DAYS`) are deleted.
- Pruned row counts are reported on the `retained_plugin_result` lane under
  `result_ingestion_events_attempt_pruned`.

Pruning removes the stored status used for operator retries along with the
attempt history. If an agent redelivers that result afterward, ingestion runs
again without the expired timeout count or quarantine decision.

A gateway first reserves a small metadata descriptor, then transfers the full
payload directly to that lane. Failed capability discovery or reservation never
falls back automatically to a full-payload singleton call. Older gateways can
use core's bounded compatibility dispatcher, but their messages reach its
mailbox before byte admission. They do not provide the new ingress memory bound.

For a coordinated rollout, deploy the gateway with
`SERVICERADAR_RESERVED_CORE_ADMISSION=false` while the old core is still active.
Deploy the new core, verify its admission protocol and synthetic retained
completion, then redeploy the gateway with the flag true (the default). Do not
switch new gateways to reservation mode against an old core: they reject safely.
The supported production pair is the new gateway and new core with reservation
mode true. Canary acceptance must occur after both rollouts finish.

Core's `RETAINED_PLUGIN_ADMISSION_ENABLED` defaults to true. False
selects a bounded commit-confirming compatibility lane; it never restores inline
DB work. Before rolling back core, disable gateway reservation mode. Drain or
cancel the current worker tree before transferring ownership; do not run both
coordinator writers for one key. Retained agents replay unaccepted work. Accepted
best-effort work remains volatile and can be lost on a coordinator restart.

## Capacity

Defaults cover reserved descriptors, queued payloads, and in-flight work:

| Owner | Items | Raw/serialized byte credit | Worker slots |
| --- | ---: | ---: | ---: |
| Each ordinary result/status lane | 32 | 32 MiB | mapper 2; bumblebee 2; legacy plugin 2; endpoint 4; other 2; status 2 |
| Sweep chunks (background queue) | 128, at most 32 per agent | 32 MiB | 4 |
| Flow attribution | 16 | 64 MiB | 1 |
| Retained plugin | 32 | 64 MiB | 2 |
| Sync chunks | 32, at most 16 per run | 64 MiB | 1 |
| Completed service-state batch | 200 | 32 MiB | 1 |

Per-agent byte credit defaults to one quarter of the lane byte credit, raised
to cover one source-ceiling payload plus 4096 bytes of headers and envelope
where the lane credit permits it, and never above the lane credit. Ordinary
lanes and the sweep queue therefore default to 16 MiB + 4096 bytes, flow to
exactly 16 MiB, and retained plugin to 16 MiB + 4096 bytes. Explicit per-agent
overrides are capped at the effective lane credit, including runtime byte
overrides.

The node also limits DB-active ingestion workers. A Repo pool of ten reserves
three slots for other core services, one for flow, two for retained plugin
(one per lane worker, so both chunks of the gateway's pair reach the database),
one for endpoint, and three for other ingestion. Other ingestion takes up to
four once the pool reaches eleven. A pool below eight cannot start this
topology.
Sync device batches execute sequentially inside their permit. The gate bounds
this topology's writers, not all unrelated application DB callers.

Default raw budgets total 448 MiB. Boot requires eight times that budget plus a
512 MiB reserve to fit a 4 GiB ingestion budget. This is a declared decode/model
reserve, not a measured hard BEAM heap limit. Smaller deployments must lower
queues together rather than increasing the declared budget beyond available
memory. Positive integer runtime overrides are:

- `SERVICERADAR_INGESTION_MEMORY_BUDGET_BYTES`
- `SERVICERADAR_INGESTION_LANE_MAX_BYTES` (each ordinary lane and the sweep queue)
- `SERVICERADAR_FLOW_INGESTION_MAX_BYTES`
- `SERVICERADAR_PLUGIN_INGESTION_MAX_BYTES`
- `SERVICERADAR_SYNC_INGESTION_MAX_BYTES` (at most 64 MiB)
- `SERVICERADAR_SERVICE_STATE_MAX_BYTES`

The sweep queue also reads `SERVICERADAR_SWEEP_INGESTION_MAX_ITEMS`,
`SERVICERADAR_SWEEP_INGESTION_MAX_ITEMS_PER_AGENT`, and
`SERVICERADAR_SWEEP_INGESTION_WORKER_TIMEOUT_MS`. Other lane item/deadline
settings remain application configuration. Invalid memory or timeout
combinations fail boot. Full/unavailable queues reject
newest work explicitly; there is no inline or unsupervised fallback. Credits
survive failed starts and are released after worker exit is observed.

Sync run receipts are control-plane records, not telemetry. Missing indices,
conflicting totals, and known rejected chunks block snapshot activation and
retirement. A rejection remains absorbing across replay and restart; a separate
complete run may recover normally. Receipts are retained until the integration
source is deleted (the foreign key cascades). Time-based expiry would allow a
late replay to forget an incomplete run and is deliberately absent.

## Sweep results

Sweep chunks are best-effort: the gateway acknowledges them to the agent before
core ingests them, so core must not drop a chunk it has accepted. An agent
reports one scan as a burst of chunks that each take seconds to ingest. An
ordinary lane bounds the wait for a worker at two seconds, so it admitted a
burst and then dropped its tail, final chunk included, and the execution never
completed. Sweeps therefore use `ServiceRadar.Ingestion.SweepQueue`, which
answers the same reserve/submit protocol under the sweep lane's name.

The queue checks capacity at reservation. A full queue rejects the reservation,
and the gateway's status buffer keeps the chunk and offers it again. A submitted
chunk is acknowledged at once and never expires while it waits. Chunks of one
agent and sweep group run one at a time in arrival order, so an execution is
created by its first chunk and completed by its final one; other agents and
groups use the remaining workers. A queued chunk waits behind at most the
per-agent allowance of chunks from its own group, plus a free worker: at two to
three seconds a chunk, a full allowance of 32 clears in under two minutes. The
queue stays on the coordinator with the four workers the sweep lane had, so its
throughput is unchanged; a sustained backlog shows up as rejections and in
`oldest_pending_ms`, not as unbounded lag.

Each attempt has a 60-second deadline, which includes the wait for a database
permit. A worker that crashes or overruns it is killed, and the chunk is retried
once after one second (two attempts in all). A chunk that fails every attempt is
dropped with an error log naming the agent, sweep group, and chunk. An error
or unexpected processor result is final and logged; neither is retried,
because ingestion may already have counted the chunk's hosts. Accepted chunks are volatile: a coordinator restart loses them,
and the queue logs how many it held.

The queue reports under lane `sweep` with the lane metric names: admissions,
rejections by reason, completions with their accepted or not-accepted outcome,
depth and bytes, `oldest_pending_ms` for the oldest queued chunk, and `retry`,
`timeout`, `crash`, and `failed` events.

## Telemetry and evidence

The bounded publisher uses fixed ETS slots, one pending protobuf frame, and
`metrics.ingestion_lanes` with a confirmed JetStream PubAck. Each frame becomes
one `timeseries_metrics` row per lane metric per core node; the default publish
interval is 30 seconds (`SERVICERADAR_INGESTION_METRICS_INTERVAL_MS`, floor 1 s).
Retried frames keep the same `Nats-Msg-Id`. Queue/byte/latency gauges report
latest values; event, rejection-reason, and terminal sums are deltas for the
interval since the previous acknowledged frame, anchored at that frame's snapshot
time. Internal ETS accounting stays cumulative with fixed cardinality; reporting
watermarks advance only on PubAck. No agent, device, or run becomes a label.
`publish_failure` counts failed PubAcks; `coalesced_interval` counts cadence
snapshots omitted behind the pending frame. Later event totals remain in ETS,
while intervening gauge history is intentionally coalesced. Publisher restart
loses volatile samples and resets the reporting watermarks. Publication cannot
wait in an ingestion caller or recursively publish a failure immediately
through the failed transport. A failed publish is still logged directly: the
first failure of an outage warns, a reminder follows approximately every
minute of consecutive failure (scaled with the publish interval), and
recovery is logged once. Log fields carry only the
subject, a reason class, and a count.

Interval negatively-acknowledged counts are the
`result_ingestion_terminals_not_accepted` completion outcomes: worker errors,
timeouts, and persistence failures surfaced as not-accepted replies. Admission
refusals (`result_ingestion_rejections_*`) are caller-side rejections, never
agent NACKs. `result_ingestion_events_incomplete_run` (lane `sync`) counts
final validation attempts that found the ledger incomplete: one per activation
attempt, not distinct runs, so a replayed run that is still incomplete counts
again.

Core has an exact publish permission for this subject, and the METRICS stream
covers `metrics.>`. EventWriter owns persistence, selecting StarRocks exclusively
when enabled and CNPG when disabled. Local telemetry remains supplementary.

Two synthetic harnesses are selected by ordinary PR BazelCI:

- `StatusHandlerTest` prints `RESULT_INGESTION_DISPATCH_LOAD`. Identical invented
  plugin/flow/plain statuses exercise 48 and 192 offers against the real old or
  new dispatcher, with a one-second held plugin boundary. It reports fast-type
  ack percentiles, terminal reconciliation, throughput, and observed singleton
  mailbox depth. Controlled leaf ingestors isolate scheduling; this harness does
  not prove durable storage.
- `ResultsRouterTest` prints `RESULT_INGESTION_SYNTHETIC_LOAD`. A 192-offer burst
  holds sweep workers, checks endpoint/plugin isolation, traces Repo query
  ownership, verifies persisted service-state rows and retained byte bounds,
  and reports terminal reply percentiles. The retained plugin persistence tests
  separately exercise the real terminal-record owner and replay behavior.

Record invocation IDs, commit identity, configuration, and both JSON results
before calling the comparison verified. Acks must have p99 below 15 seconds and
all replies inside the stricter 20-second gateway budget. No live load numbers,
heap measurements, or canary rollout proof are implied by an authored harness.

### Baseline dispatch measurements

The corrected baseline ran on staging commit
`8c9c17fa3d1a6063653eff25f2d050b20187f686`, with only the same portable test
harness appended. RBE invocation
[95dcebf7-42b3-4f35-b25b-28074e46bea5](https://carverauto.buildbuddy.io/invocation/95dcebf7-42b3-4f35-b25b-28074e46bea5)
passed the selected unit target. All three classes completed work; the larger
burst explicitly rejected twelve flow offers under its existing bounded lane.

| Offers | Completed | Rejected | Fast replies before plugin release | Fast ack p50 / p95 / p99 / max (ms) | Observed singleton mailbox high water |
| ---: | ---: | ---: | ---: | --- | ---: |
| 48 | 48 | 0 | 0 | 1002 / 1003 / 1003 / 1003 | 47 |
| 192 | 180 | 12 | 0 | 1007 / 1009 / 1009 / 1009 | 191 |

These are synthetic scheduling measurements with controlled leaf ingestors,
not live ingestion or durable-store measurements. The earlier invocation
`e3acabbe-71e9-41fa-989f-469a48b0b212` omitted the baseline flow reply-lease
supervisor and is excluded from the comparison. Fixed-head measurements must
come from PR BazelCI before the comparison is considered complete.
