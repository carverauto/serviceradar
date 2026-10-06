# Bounded result ingestion

Core uses independent result lanes with one active job per ordering key. Mapper
interfaces and topology share an agent key; sweeps use agent plus sweep group.
Malformed or older sweep metadata falls back to the conservative agent key.
Generic status snapshots keep per-agent order. Type ingestion and irreversible
transitions are never coalesced. Only completed service-state projections with
all five identity fields may replace an older pending projection.

## Acknowledgements and version pairing

The agent RPC budget remains 30 seconds. The gateway introduced by #5308 spends
at most 20 seconds forwarding acknowledged work. This implementation reserves
15 seconds in core: two for admission/queueing, ten for execution, and three for
cancellation/reply. Core returns an acknowledged success only after the owning
lane confirms its existing durable completion condition. A committed plugin
handler failure marker is terminal; a persistence failure is not accepted.
Timeout or overload retains the agent's pending payload for idempotent replay.

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
| Each ordinary result/status lane | 32 | 32 MiB | sweep 4; mapper 2; bumblebee 2; legacy plugin 2; endpoint 4; other 2; status 2 |
| Flow attribution | 16 | 64 MiB | 1 |
| Retained plugin | 32 | 64 MiB | 2 |
| Sync chunks | 32, at most 16 per run | 64 MiB | 1 |
| Completed service-state batch | 200 | 32 MiB | 1 |

Per-agent byte credit defaults to one quarter of the lane byte credit, raised
to cover one source-ceiling payload plus 4096 bytes of headers and envelope
where the lane credit permits it, and never above the lane credit. Ordinary
lanes therefore default to 16 MiB + 4096 bytes, flow to exactly 16 MiB, and
retained plugin to 16 MiB + 4096 bytes. Explicit per-agent overrides are
capped at the effective lane credit, including runtime byte overrides.

The node also limits DB-active ingestion workers. A Repo pool of ten reserves
three slots for other core services, one each for flow, plugin, and endpoint,
and four for other ingestion. A pool below seven cannot start this topology.
Sync device batches execute sequentially inside their permit. The gate bounds
this topology's writers, not all unrelated application DB callers.

Default raw budgets total 448 MiB. Boot requires eight times that budget plus a
512 MiB reserve to fit a 4 GiB ingestion budget. This is a declared decode/model
reserve, not a measured hard BEAM heap limit. Smaller deployments must lower
queues together rather than increasing the declared budget beyond available
memory. Positive integer runtime overrides are:

- `SERVICERADAR_INGESTION_MEMORY_BUDGET_BYTES`
- `SERVICERADAR_INGESTION_LANE_MAX_BYTES` (each ordinary lane)
- `SERVICERADAR_FLOW_INGESTION_MAX_BYTES`
- `SERVICERADAR_PLUGIN_INGESTION_MAX_BYTES`
- `SERVICERADAR_SYNC_INGESTION_MAX_BYTES` (at most 64 MiB)
- `SERVICERADAR_SERVICE_STATE_MAX_BYTES`

Other lane item/deadline settings remain application configuration. Invalid
memory or timeout combinations fail boot. Full/unavailable queues reject
newest work explicitly; there is no inline or unsupervised fallback. Credits
survive failed starts and are released after worker exit is observed.

Sync run receipts are control-plane records, not telemetry. Missing indices,
conflicting totals, and known rejected chunks block snapshot activation and
retirement. A rejection remains absorbing across replay and restart; a separate
complete run may recover normally. Receipts are retained until the integration
source is deleted (the foreign key cascades). Time-based expiry would allow a
late replay to forget an incomplete run and is deliberately absent.

## Telemetry and evidence

The bounded publisher uses fixed ETS slots, one pending protobuf frame, and
`metrics.ingestion_lanes` with a confirmed JetStream PubAck. Retried frames
keep the same `Nats-Msg-Id`. Queue/byte/latency gauges report latest values;
event, rejection-reason, and terminal sums are deltas for the interval since
the previous acknowledged frame, anchored at that frame's snapshot time.
Internal ETS accounting stays cumulative with fixed cardinality; reporting
watermarks advance only on PubAck. No agent, device, or run becomes a label.
`publish_failure` counts failed PubAcks; `coalesced_interval` counts cadence
snapshots omitted behind the pending frame. Later event totals remain in ETS,
while intervening gauge history is intentionally coalesced. Publisher restart
loses volatile samples and resets the reporting watermarks. Publication cannot
wait in an ingestion caller or recursively publish a failure immediately
through the failed transport.

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
