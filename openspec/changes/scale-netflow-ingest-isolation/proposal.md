# Change: Scale NetFlow ingest isolation and GenStage demand

## Why

Demo NetFlow maps go empty under real export load even while the flow-collector keeps converting packets. Investigation showed the break is not UDP ingest: devices still deliver NetFlow, the collector still converts flows, and JetStream still accepts messages. The pipeline fails later:

1. **Shared `events` stream contention** — `flows.raw.netflow` shares JetStream retention with logs, Falco, OTEL metrics/traces, and other subjects. One byte/age cap covers everything.
2. **Conflicting stream reconcilers** — flow-collector, log/OTEL collectors, and EventWriter all touch `events`. OTEL pins `max_age` to ~30 minutes and demo Helm sets `stream_max_bytes` to 1 GiB “to fit the account budget,” so unprocessed flow messages expire or are discard-old’d before EventWriter catches up.
3. **Multiplexed GenStage demand** — EventWriter uses Broadway (GenStage) pull consumers, but **one** producer process fair-shares demand across ~15 JetStream durables. NetFlow demand is diluted by every other subject; pull batches stay small (`no_wait` + 100 ms poll, default pull batch 16).
4. **Lag vs UI window** — the NetFlow map queries the last ~15 minutes of `ocsf_network_activity.time`. When EventWriter lags near stream MaxAge, written flow timestamps fall outside that window and the map correctly shows zero paths while “Network Health / observed flows” still looks healthy from cumulative collector metrics.

This is an architecture and sizing problem, not a collector bug. High-volume targets (hundreds to thousands of exporters) cannot share a thrifty multi-tenant `events` bus with short MaxAge.

Related completed work: `fix-eventwriter-backpressure-hotpath` introduced demand-coupled JetStream **pull** for EventWriter (primarily for metrics). This change extends that model so **NetFlow has its own stream, its own demand domain, and production-sized retention**, without letting OTEL/logs reconcilers thrash flow stream limits.

## What Changes

- Move raw flow subjects (`flows.raw.netflow`, `flows.raw.sflow`, and
  configured concrete `flows.raw.<name>` extensions) onto a **dedicated
  JetStream stream** (default name `flows`), separate from the shared `events`
  stream. These concrete raw-flow leaves are the subjects this change owns.
- Keep flow attribution outside that raw-flow stream: the agent sends retained
  `FlowAttributionEventBatch` payloads through `StreamStatus` to the
  authenticated gateway, which forwards them to core; core persists bounded state in
  `platform.flow_process_attribution_current`, and the correlator stamps the
  matching existing `platform.ocsf_network_activity` row in place. The
  historical `flow.host-slice.*` and `flow.attributed.*` demo-canary subjects
  are retired, not current or future routing.
- Give the flow stream **explicit, flow-owned retention** (`max_bytes`, `max_age`, replicas, discard policy) that no log/OTEL reconciler may overwrite.
- Make flow-collector **reconcile** stream `max_bytes` / `max_age` / subjects / replicas on an existing stream (today it only merges subjects and replicas on update).
- Split EventWriter so flow subjects run on a **dedicated Broadway pipeline (or dedicated producer)** whose GenStage demand is not fair-shared with logs/metrics/Falco.
- Replace the netflow path’s `no_wait` + 100 ms timer pull loop with **demand-gated long-poll** JetStream fetches (expires-based), sized by remaining demand and a netflow-tuned pull batch / `max_ack_pending`.
- Raise production and demo defaults for flow stream size and NATS `max_file_store` / PVC guidance so R=3 retention can hold peak lag; keep discard-old as the overload safety valve.
- Add lag / retention-risk telemetry and runbook checks so operators can see when flow consumer lag approaches MaxAge before the UI goes empty.
- Document migration: dual-read/create the `flows` stream, cut over publishers,
  drain old `events` filter consumers, and remove the configured concrete
  `flows.raw.<name>` subjects from the shared `events` subject list.
- Guard downgrades across the ownership cutover: run the current image's reverse-transfer path to move concrete flow subjects back to `events` before Helm or GitOps restores an older image.

## Impact

- Affected specs: `flow-collector`, `observability-signals`
- Affected code:
  - `rust/flow-collector` (stream ensure/reconcile, default stream name/size)
  - `elixir/serviceradar_core` EventWriter producer, pipeline, config, runtime.exs
  - `elixir/serviceradar_core_elx/config/runtime.exs`
  - Helm `flowCollector`, `nats.jetstream`, demo overlays (`values.yaml`, `values-demo.yaml`)
  - log-collector / OTEL NATS stream ensure paths (must not manage the `flows` stream)
  - docs: `docs/docs/netflow.md`, ops notes in `openspec/notes/sr-data-flow.md`
- Affected runtime: demo/prod flow ingest, EventWriter coordinator, JetStream storage budget
- Non-goals: multi-tenant isolation, rewriting the OCSF flow processor, changing dashboard query windows, NATS node disk-pressure remediations (ops, not product)

## Success Criteria

- Under sustained collector rate comparable to demo peak (and documented synthetic multi-exporter load), EventWriter netflow `num_pending` drains toward zero and `max(ocsf_network_activity.time)` stays within a small lag SLO of wall clock (target: p95 lag ≪ UI 15-minute window).
- Flow stream MaxAge/MaxBytes are owned only by flow configuration; restarting log-collector/OTEL does not shrink them.
- GenStage demand for flows is independent of log/metric demand (no fair-share dilution across ~15 durables).
- Demo chart defaults no longer pin the **flow** path to a 1 GiB shared bus; demo may still use a smaller *flows* stream than production, but it must be sized for multi-hour lag headroom relative to EventWriter throughput.
- Flow-collector publishes and manages only configured concrete
  `flows.raw.<name>` subjects on the dedicated stream, including
  `flows.raw.netflow` and `flows.raw.sflow`; no host-slice or attributed-flow
  canary subject is restored during migration or rollback.
